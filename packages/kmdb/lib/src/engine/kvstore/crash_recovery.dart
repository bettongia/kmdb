// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';
import 'dart:typed_data';

import '../manifest/current_file.dart';
import '../manifest/manifest_reader.dart';
import '../manifest/manifest_writer.dart';
import '../manifest/version_edit.dart';
import '../memtable/memtable.dart';
import '../platform/storage_adapter_interface.dart';
import '../util/hlc.dart';
import '../util/key_codec.dart';
import '../wal/wal_record.dart';
import '../wal/wal_writer.dart';
import '../../sync/hlc_clock.dart';
import 'kv_store.dart';
import 'lsm_engine.dart';

/// Performs the 9-step crash recovery sequence when opening a database.
///
/// The recovery sequence is documented in §17:
///
/// 1. Acquire `LOCK` file (exclusive).
/// 2. Read `CURRENT` → identify active Manifest.
/// 3. Replay Manifest → reconstruct levels, logNumber, nextSeq.
/// 4. Delete orphan SSTable files (in `sst/` but not referenced by Manifest).
/// 5. Collect `wal-*.log` files, sorted by sequence.
/// 6. Delete obsolete WAL files (sequence < `maxLogNumber`).
/// 7. Replay every retained WAL file (sequence ≥ `maxLogNumber`) in full,
///    stopping on the first bad checksum. Full replay is idempotent under HLC
///    last-write-wins, so no flush-marker skipping is required.
/// 8. Prepare dirty-open flag (written on first WriteBatch, not during open).
/// 9. Return `(LsmEngine, OpenResult)`.
final class CrashRecovery {
  const CrashRecovery({required this.adapter, required this.config});

  /// Storage adapter used for all I/O.
  final StorageAdapter adapter;

  /// Configuration controlling thresholds and fsync behaviour.
  final KvStoreConfig config;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Opens the database at [dbDir] and returns an initialised [LsmEngine] and
  /// [OpenResult].
  ///
  /// [deviceId] is used to name new SSTable files. It must be an 8-character
  /// hex string. If omitted, a deterministic fallback is used.
  ///
  /// [clock] is an optional pre-built [HlcClock]. When provided it is used
  /// directly, bypassing the clock construction from [KvStoreConfig.maxClockSkew].
  /// This seam is intended for tests that need a deterministic, injectable clock.
  /// Production code always omits [clock] so that [CrashRecovery] owns
  /// construction and seeds the clock from the replayed WAL maximum.
  Future<(LsmEngine engine, OpenResult result)> open(
    String dbDir, {
    String deviceId = '00000000',
    HlcClock? clock,
  }) async {
    final sstDir = '$dbDir/sst';
    final lockPath = '$dbDir/LOCK';
    final currentFile = CurrentFile(dbDir: dbDir, adapter: adapter);

    // ── Step 1: Acquire exclusive lock ────────────────────────────────────────
    await adapter.createDirectory(dbDir);
    await adapter.createDirectory(sstDir);
    await adapter.acquireLock(lockPath);

    // ── Step 2: Read CURRENT ──────────────────────────────────────────────────
    String manifestName;
    try {
      manifestName = await currentFile.read();
    } on StorageException {
      // Fresh database — create CURRENT and write an initial empty VersionEdit
      // so the manifest file exists and is valid on the next open.
      manifestName = CurrentFile.initialManifestName();
      await currentFile.write(manifestName);
      final initPath = '$dbDir/$manifestName';
      final initWriter = ManifestWriter(path: initPath, adapter: adapter);
      await initWriter.append(const VersionEdit(logNumber: 0, nextSeq: 0));
      await adapter.writeFile(
        '$dbDir/README.txt',
        Uint8List.fromList(
          utf8.encode(
            'This directory is managed by KMDB. '
            'Please DO NOT interact with these files directly '
            'or your database will be corrupted.\n',
          ),
        ),
      );
    }
    final manifestPath = '$dbDir/$manifestName';

    // ── Step 3: Replay Manifest ───────────────────────────────────────────────
    final reader = ManifestReader(adapter: adapter);
    final state = await reader.replay(manifestPath);

    // Reconstruct the level map as mutable lists.
    final levels = <int, List<String>>{};
    for (final entry in state.levels.entries) {
      levels[entry.key] = List<String>.from(entry.value);
    }

    // ── Step 4: Delete orphan SSTables ───────────────────────────────────────
    final knownFiles = state.allFiles.toSet();
    final sstFiles = await adapter.listFiles(sstDir, extension: '.sst');
    for (final filename in sstFiles) {
      if (!knownFiles.contains(filename)) {
        // Orphan file — not referenced by the Manifest.
        await adapter.deleteFile('$sstDir/$filename');
      }
    }

    // ── Steps 5–7: WAL replay ─────────────────────────────────────────────────
    var hadInterruptedWrites = false;
    final affectedNamespaces = <String>{};

    final walFiles = await adapter.listFiles(dbDir, extension: '.log');
    // Sort WAL files by their sequence number (wal-NNNNN.log).
    final sortedWals = _sortWalFiles(walFiles);

    // Determine the highest WAL sequence number for the active writer.
    // After recovery, the engine starts a new WAL with sequence = maxWalSeq + 1
    // (or 1 for a fresh database).
    var maxWalSeq = state.maxLogNumber;

    // Replay WAL files with sequence ≥ maxLogNumber in full.
    final restoredMemtable = Memtable();
    // Track the maximum HLC seen across all replayed WAL records so we can
    // seed the engine clock after recovery. Named distinctly from the [clock]
    // parameter to avoid shadowing.
    Hlc replayedMaxHlc = Hlc.fromEncoded(state.maxNextSeq);

    for (final (seq, name) in sortedWals) {
      // Build the full path from the bare filename.
      final path = '$dbDir/$name';

      // WAL files strictly below maxLogNumber are obsolete: their records are
      // already durable in an SSTable referenced by the manifest. Files at or
      // above maxLogNumber may still hold writes that were never flushed —
      // crucially, the active WAL's own sequence equals maxLogNumber — so they
      // MUST be replayed, not deleted. Using `<` here rather than `<=` is what
      // prevents the active WAL from being discarded on an unclean reopen
      // (review finding C1, Defect 1).
      if (seq < state.maxLogNumber) {
        await adapter.deleteFile(path);
        continue;
      }
      maxWalSeq = seq > maxWalSeq ? seq : maxWalSeq;

      // Replay the retained file in full with a single decode walk. Tracking
      // the bytes consumed lets us detect a truncated tail (a partial final
      // append interrupted by the crash) without decoding the file twice.
      // Replaying in full — rather than skipping to a trailing flush marker —
      // is safe because every re-applied record is idempotent under HLC
      // last-write-wins, and it closes the window where a flush marker whose
      // SSTable never became durable would hide live records (C1, Defect 2).
      final fileBytes = await adapter.readFile(path);
      var pos = 0;
      while (pos < fileBytes.length) {
        final result = WalRecord.tryDecode(fileBytes, pos);
        if (result == null) break; // truncation or corruption — stop here
        final (record, size) = result;
        pos += size;

        // Skip any flush marker left by an older build. Markers are no longer
        // written but remain decodable for backward compatibility.
        if (record.type == WalRecordType.flushMarker) continue;

        final keyBytes = Uint8List.fromList(record.key);
        if (keyBytes.length != 16) continue; // malformed — skip

        final hlc = record.sequence;
        if (hlc > replayedMaxHlc) replayedMaxHlc = hlc;

        final internalKey = KeyCodec.encodeInternalKey(
          record.namespace,
          keyBytes,
          hlc,
          record.type == WalRecordType.put ? RecordType.put : RecordType.delete,
        );
        restoredMemtable.put(internalKey, Uint8List.fromList(record.value));
        affectedNamespaces.add(record.namespace);
      }
      if (pos < fileBytes.length) hadInterruptedWrites = true;
    }

    // ── Step 8: Open Manifest writer for new writes ───────────────────────────
    final manifestWriter = ManifestWriter(path: manifestPath, adapter: adapter);

    // ── Step 9: Start WAL writer at the next sequence number ─────────────────
    final walWriter = WalWriterFactory.create(
      dirPath: dbDir,
      adapter: adapter,
      initialSequence: maxWalSeq + 1,
      fsyncOnWrite: config.fsyncOnWrite,
    );

    // Construct or adopt the HLC clock.
    //
    // Production path (clock == null): build a fresh HlcClock seeded from the
    // replayed WAL maximum, then call now() to advance past wall time so the
    // first local write is causally after all replayed data. HlcClock.update()
    // handles the wall-clock comparison internally, so the old manual
    // "nowMs > clock.physicalMs" branch is no longer needed. ClockSkewException
    // propagates naturally if the stored HLC is more than maxClockSkew ahead of
    // the local wall clock, which indicates clock regression or a corrupted DB.
    //
    // Test path (clock != null): use the caller-supplied clock as-is. The test
    // is responsible for pre-seeding it; we do not call update() or now() so
    // the injected wall-clock function retains full control.
    final HlcClock hlcClock;
    if (clock != null) {
      hlcClock = clock;
    } else {
      hlcClock = HlcClock(maxClockSkew: config.maxClockSkew);
      if (replayedMaxHlc > const Hlc(0, 0)) {
        hlcClock.update(replayedMaxHlc);
      }
      hlcClock.now();
    }

    final engine = LsmEngine.create(
      dbDir: dbDir,
      sstDir: sstDir,
      adapter: adapter,
      config: config,
      deviceId: deviceId,
      levels: levels,
      manifestWriter: manifestWriter,
      walWriter: walWriter,
      clock: hlcClock,
      restoredMemtable: restoredMemtable,
    );

    final openResult = OpenResult(
      hadInterruptedWrites: hadInterruptedWrites,
      affectedNamespaces: affectedNamespaces.toList(),
    );

    return (engine, openResult);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Parses and sorts WAL file paths by their sequence number (ascending).
  ///
  /// Only files matching the `wal-NNNNN.log` pattern are included.
  static List<(int seq, String path)> _sortWalFiles(List<String> filenames) {
    final result = <(int, String)>[];
    for (final name in filenames) {
      // name is a bare filename like 'wal-00001.log'.
      if (!name.startsWith('wal-') || !name.endsWith('.log')) continue;
      final seqStr = name.substring(4, name.length - 4);
      final seq = int.tryParse(seqStr);
      if (seq == null) continue;
      result.add((seq, name));
    }
    result.sort((a, b) => a.$1.compareTo(b.$1));
    return result;
  }
}

/// Factory helper so [CrashRecovery] can build a [WalWriter] without directly
/// constructing it (keeps the recovery class testable).
///
/// In production, [WalWriterFactory.create] simply calls the [WalWriter]
/// constructor. Tests can intercept via a subclass or dependency injection if
/// needed.
final class WalWriterFactory {
  WalWriterFactory._();

  /// Creates a [WalWriter] targeting [dirPath] with the given configuration.
  static WalWriter create({
    required String dirPath,
    required StorageAdapter adapter,
    required int initialSequence,
    required bool fsyncOnWrite,
  }) => WalWriter(
    dirPath: dirPath,
    adapter: adapter,
    initialSequence: initialSequence,
    fsyncOnWrite: fsyncOnWrite,
  );
}
