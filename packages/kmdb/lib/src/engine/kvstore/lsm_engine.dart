// Copyright 2026 The KMDB Authors
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

import 'dart:async';
import 'dart:typed_data';

import '../compaction/compaction_job.dart';
import '../compaction/merge_iterator.dart';
import '../manifest/manifest_writer.dart';
import '../manifest/version_edit.dart';
import '../memtable/memtable.dart';
import '../memtable/skip_list.dart';
import '../platform/storage_adapter_interface.dart';
import '../sstable/sstable_reader.dart';
import '../sstable/sstable_writer.dart';
import '../sstable/sstable_info.dart';
import '../util/hlc.dart';
import '../util/key_codec.dart';
import '../wal/wal_writer.dart';
import 'kv_store.dart';

/// The core LSM engine.
///
/// [LsmEngine] orchestrates the write path (WAL → memtable → SSTable flush),
/// the read path (memtable → L0 → L1 → L2), compaction, and the HLC clock.
/// It is not publicly exported; external code uses [KvStoreImpl].
///
/// ## Concurrency
///
/// All operations execute on a single isolate. There is no background
/// compaction thread. Compaction runs synchronously on the write path, before
/// the triggering write returns.
///
/// ## Level layout
///
/// `_levels[n]` is a [List] of bare SSTable filenames at level `n`.
/// The list for L0 is ordered from oldest (index 0) to newest (last index);
/// point lookups search L0 in reverse (newest-first = highest priority).
/// L1 and L2 files are assumed non-overlapping after compaction.
final class LsmEngine {
  LsmEngine._({
    required String dbDir,
    required String sstDir,
    required StorageAdapter adapter,
    required KvStoreConfig config,
    required String deviceId,
    required Map<int, List<String>> levels,
    required ManifestWriter manifestWriter,
    required WalWriter walWriter,
    required Hlc initialHlc,
  }) : _dbDir = dbDir,
       _sstDir = sstDir,
       _adapter = adapter,
       _config = config,
       _deviceId = deviceId,
       _levels = levels,
       _manifestWriter = manifestWriter,
       _walWriter = walWriter,
       _hlc = initialHlc,
       _active = Memtable(),
       // sync: true delivers events synchronously to subscribers — correct for
       // KMDB's single-isolate model where listeners are set up before writes.
       _writeEventsController = StreamController<String>.broadcast(sync: true);

  final String _dbDir;
  final String _sstDir;
  final StorageAdapter _adapter;
  final KvStoreConfig _config;
  final String _deviceId;

  /// Live SSTable filenames grouped by level (0, 1, 2).
  final Map<int, List<String>> _levels;

  ManifestWriter _manifestWriter;
  final WalWriter _walWriter;

  /// Current HLC timestamp. Monotonically advanced on every write.
  Hlc _hlc;

  /// The active (mutable) memtable. Incoming writes go here.
  Memtable _active;

  /// Frozen snapshot of the memtable, held in memory while its SSTable is
  /// being written. `null` when no flush is in progress.
  FrozenMemtable? _frozen;

  final StreamController<String> _writeEventsController;

  /// Broadcast stream that emits a namespace string after each successful write.
  Stream<String> get writeEvents => _writeEventsController.stream;

  /// The SSTable directory path. Exposed for [KvStoreImpl.ingestSstable].
  String get sstDir => _sstDir;

  /// The storage adapter. Exposed for [KvStoreImpl.ingestSstable].
  StorageAdapter get adapter => _adapter;

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Creates an [LsmEngine] from the result of crash recovery.
  ///
  /// Callers should use [CrashRecovery.open] instead of this constructor.
  static LsmEngine create({
    required String dbDir,
    required String sstDir,
    required StorageAdapter adapter,
    required KvStoreConfig config,
    required String deviceId,
    required Map<int, List<String>> levels,
    required ManifestWriter manifestWriter,
    required WalWriter walWriter,
    required Hlc initialHlc,
    required Memtable restoredMemtable,
  }) {
    final engine = LsmEngine._(
      dbDir: dbDir,
      sstDir: sstDir,
      adapter: adapter,
      config: config,
      deviceId: deviceId,
      levels: levels,
      manifestWriter: manifestWriter,
      walWriter: walWriter,
      initialHlc: initialHlc,
    );
    engine._active = restoredMemtable;
    return engine;
  }

  // ── HLC clock ─────────────────────────────────────────────────────────────

  /// Advances the HLC clock and returns the new timestamp.
  ///
  /// Uses the system wall clock as the physical component. The logical counter
  /// is incremented when multiple writes land in the same physical millisecond.
  Hlc _tick() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs > _hlc.physicalMs) {
      _hlc = Hlc(nowMs, 0);
    } else if (_hlc.logical < 0xFFFF) {
      _hlc = Hlc(_hlc.physicalMs, _hlc.logical + 1);
    } else {
      // Logical counter exhausted — advance physical time by 1ms.
      _hlc = Hlc(_hlc.physicalMs + 1, 0);
    }
    return _hlc;
  }

  /// Advances the clock to be at least [observed], then ticks once.
  ///
  /// Used when replaying WAL records or ingesting external SSTables so the
  /// engine never generates a timestamp earlier than one it has already seen.
  void advanceClock(Hlc observed) {
    if (observed > _hlc) _hlc = observed;
  }

  // ── Write operations ──────────────────────────────────────────────────────

  /// Writes a single value to the WAL and memtable.
  Future<void> put(String namespace, String key, Uint8List value) async {
    final keyBytes = KeyCodec.keyToBytes(key);
    final hlc = _tick();
    final internalKey = KeyCodec.encodeInternalKey(
      namespace,
      keyBytes,
      hlc,
      RecordType.put,
    );
    await _walWriter.writePut(
      sequence: hlc,
      namespace: namespace,
      keyBytes: keyBytes,
      value: value,
    );
    _active.put(internalKey, value);
    _writeEventsController.add(namespace);
    await _flushIfNeeded();
  }

  /// Writes a delete tombstone to the WAL and memtable.
  Future<void> delete(String namespace, String key) async {
    final keyBytes = KeyCodec.keyToBytes(key);
    final hlc = _tick();
    final internalKey = KeyCodec.encodeInternalKey(
      namespace,
      keyBytes,
      hlc,
      RecordType.delete,
    );
    await _walWriter.writeDelete(
      sequence: hlc,
      namespace: namespace,
      keyBytes: keyBytes,
    );
    _active.put(internalKey, Uint8List(0));
    _writeEventsController.add(namespace);
    await _flushIfNeeded();
  }

  /// Commits all entries in [batch] atomically (single WAL sequence per batch
  /// entry, all to memtable before checking flush).
  Future<void> writeBatch(WriteBatch batch) async {
    final namespaces = <String>{};
    for (final entry in batch.entries) {
      final keyBytes = KeyCodec.keyToBytes(entry.key);
      final hlc = _tick();
      if (entry.isDelete) {
        final internalKey = KeyCodec.encodeInternalKey(
          entry.namespace,
          keyBytes,
          hlc,
          RecordType.delete,
        );
        await _walWriter.writeDelete(
          sequence: hlc,
          namespace: entry.namespace,
          keyBytes: keyBytes,
        );
        _active.put(internalKey, Uint8List(0));
      } else {
        final value = entry.value!;
        final internalKey = KeyCodec.encodeInternalKey(
          entry.namespace,
          keyBytes,
          hlc,
          RecordType.put,
        );
        await _walWriter.writePut(
          sequence: hlc,
          namespace: entry.namespace,
          keyBytes: keyBytes,
          value: value,
        );
        _active.put(internalKey, value);
      }
      namespaces.add(entry.namespace);
    }
    for (final ns in namespaces) {
      _writeEventsController.add(ns);
    }
    await _flushIfNeeded();
  }

  // ── Read operations ───────────────────────────────────────────────────────

  /// Returns the raw value bytes for [key] in [namespace], or `null`.
  ///
  /// Search order: active memtable → frozen memtable → L0 (newest-first) →
  /// L1 → L2. The first non-tombstone hit is returned.
  Future<Uint8List?> get(String namespace, String key) async {
    final keyBytes = KeyCodec.keyToBytes(key);
    final prefix = _buildKeyPrefix(namespace, keyBytes);
    final prefixEnd = _nextPrefix(prefix);

    // 1. Active memtable.
    final fromActive = _latestFromIterable(
      _active.scan(start: prefix, end: prefixEnd),
    );
    if (fromActive != null) {
      return fromActive.isDelete ? null : fromActive.value;
    }

    // 2. Frozen memtable (if present).
    if (_frozen != null) {
      final fromFrozen = _latestFromIterable(
        _frozen!.scan(start: prefix, end: prefixEnd),
      );
      if (fromFrozen != null) {
        return fromFrozen.isDelete ? null : fromFrozen.value;
      }
    }

    // 3. L0 files — search newest-first (last in list).
    final l0 = _levels[0] ?? [];
    for (var i = l0.length - 1; i >= 0; i--) {
      final result = await _getFromSstable(
        '$_sstDir/${l0[i]}',
        prefix,
        prefixEnd,
      );
      if (result != null) return result.$1;
      if (result != null && result.$2) return result.$1;
    }

    // 4. L1, then L2.
    for (final level in [1, 2]) {
      for (final filename in (_levels[level] ?? [])) {
        final result = await _getFromSstable(
          '$_sstDir/$filename',
          prefix,
          prefixEnd,
        );
        if (result != null) return result.$1;
        if (result != null && result.$2) return result.$1;
      }
    }

    return null;
  }

  /// Returns an ordered stream of entries in [namespace].
  ///
  /// Merges the memtable, frozen memtable, and all SSTable levels. Tombstones
  /// are suppressed from the output.
  Stream<KvEntry> scan(
    String namespace, {
    String? startKey,
    String? endKey,
  }) async* {
    // Convert user-key bounds to internal-key bounds.
    final scanStart = startKey != null
        ? _buildKeyPrefix(namespace, KeyCodec.keyToBytes(startKey))
        : _buildNamespacePrefix(namespace);
    final scanEnd = endKey != null
        ? _buildKeyPrefix(namespace, KeyCodec.keyToBytes(endKey))
        : _nextPrefix(_buildNamespacePrefix(namespace));

    // Collect streams from all sources (memtable, then SSTable levels).
    final streams = <Stream<SstEntry>>[];

    // Memtable sources: convert SkipListEntry → SstEntry stream.
    streams.add(_skipListRangeToStream(_active, scanStart, scanEnd));
    if (_frozen != null) {
      streams.add(_skipListRangeToStream(_frozen!, scanStart, scanEnd));
    }

    // SSTable sources — L0 newest-first, then L1, L2.
    final l0 = _levels[0] ?? [];
    for (var i = l0.length - 1; i >= 0; i--) {
      final reader = await _openReader('$_sstDir/${l0[i]}');
      if (reader != null) {
        streams.add(reader.scan(start: scanStart, end: scanEnd));
      }
    }
    for (final level in [1, 2]) {
      for (final filename in (_levels[level] ?? [])) {
        final reader = await _openReader('$_sstDir/$filename');
        if (reader != null) {
          streams.add(reader.scan(start: scanStart, end: scanEnd));
        }
      }
    }

    // Merge all streams. The MergeIterator yields entries in ascending internal
    // key order. For a given user key, lower HLC (older version) comes first,
    // higher HLC (newer version) comes last. We must buffer and emit only the
    // LAST version per user key, checking whether it is a tombstone.
    final merge = MergeIterator(streams);

    String? bufferedKey;
    Uint8List? bufferedValue;
    bool bufferedIsDelete = false;

    await for (final entry in merge.entries) {
      final ns = KeyCodec.decodeNamespace(entry.key);
      if (ns != namespace) continue; // skip entries from other namespaces

      final userKeyHex = KeyCodec.bytesToKey(KeyCodec.decodeUserKey(entry.key));

      if (userKeyHex != bufferedKey) {
        // New user key arrived: emit the previously buffered one (if any and
        // not a tombstone).
        if (bufferedKey != null && !bufferedIsDelete) {
          yield (key: bufferedKey, value: bufferedValue!);
        }
        bufferedKey = userKeyHex;
        bufferedValue = entry.value;
        bufferedIsDelete =
            KeyCodec.decodeRecordType(entry.key) == RecordType.delete;
      } else {
        // Same user key, later HLC — update to this newer version.
        bufferedValue = entry.value;
        bufferedIsDelete =
            KeyCodec.decodeRecordType(entry.key) == RecordType.delete;
      }
    }

    // Emit the last buffered entry if not a tombstone.
    if (bufferedKey != null && !bufferedIsDelete) {
      yield (key: bufferedKey, value: bufferedValue!);
    }
  }

  // ── Flush ─────────────────────────────────────────────────────────────────

  /// Checks whether the active memtable has reached the flush threshold and
  /// flushes + compacts if so.
  Future<void> _flushIfNeeded() async {
    if (_active.sizeBytes >= _config.memtableSizeBytes) {
      await flush();
    }
  }

  /// Flushes the active memtable to a new L0 SSTable and rotates the WAL.
  ///
  /// Steps:
  /// 1. Freeze the active memtable; start a new one.
  /// 2. Rotate the WAL (writes flush marker, increments sequence).
  /// 3. Write the frozen memtable to an SSTable file.
  /// 4. Append a [VersionEdit] to the Manifest.
  /// 5. Discard the frozen memtable.
  /// 6. Run compaction if triggered.
  Future<void> flush() async {
    if (_active.length == 0) return; // nothing to flush

    // 1. Freeze and start fresh.
    _frozen = _active.freeze();
    _active = Memtable();

    // 2. Rotate WAL.
    final hlc = _tick();
    await _walWriter.rotate(hlc);

    // 3. Write SSTable from frozen memtable.
    final writer = SstableWriter();
    Hlc? minHlc;
    Hlc? maxHlc;
    var entryCount = 0;
    Uint8List? minKeyBytes;
    Uint8List? maxKeyBytes;

    for (final entry in _frozen!.entries) {
      writer.add(entry.key, entry.value);
      entryCount++;
      final entryHlc = KeyCodec.decodeHlc(entry.key);
      if (minHlc == null || entryHlc < minHlc) minHlc = entryHlc;
      if (maxHlc == null || entryHlc > maxHlc) maxHlc = entryHlc;
      minKeyBytes ??= entry.key;
      maxKeyBytes = entry.key;
    }

    final effectiveMin = minHlc ?? hlc;
    final effectiveMax = maxHlc ?? hlc;
    final filename = SstableInfo.flushName(
      _deviceId,
      effectiveMin,
      effectiveMax,
    );
    final sstPath = '$_sstDir/$filename';

    final sstBytes = writer.finish();
    await _adapter.writeFile(sstPath, sstBytes);
    await _adapter.syncFile(sstPath);

    // 4. Append VersionEdit to Manifest.
    final meta = SstableMeta(
      level: 0,
      filename: filename,
      minKey: minKeyBytes != null ? _bytesToHex(minKeyBytes) : '',
      maxKey: maxKeyBytes != null ? _bytesToHex(maxKeyBytes) : '',
      entryCount: entryCount,
      walSequence: _walWriter.activeSequence - 1, // the now-retired WAL
    );
    await _manifestWriter.append(
      VersionEdit(
        logNumber: _walWriter.activeSequence,
        nextSeq: hlc.encoded,
        added: [meta],
      ),
    );

    // Update level 0 list.
    (_levels[0] ??= []).add(filename);

    // 5. Discard frozen memtable.
    _frozen = null;

    // Delete all WAL files that have now been fully persisted in the SSTable.
    // Normally this is just the one file returned by rotate(), but after a
    // two-phase open (e.g. DatabaseOpener) older WAL files may have been
    // replayed into the restored memtable and are now superseded as well.
    // Any file with sequence < activeSequence is safe to remove.
    final allWalFiles = await _adapter.listFiles(_dbDir, extension: '.log');
    for (final name in allWalFiles) {
      if (!name.startsWith('wal-') || !name.endsWith('.log')) continue;
      final seqStr = name.substring(4, name.length - 4);
      final seq = int.tryParse(seqStr);
      if (seq == null || seq >= _walWriter.activeSequence) continue;
      await _adapter.deleteFile('$_dbDir/$name');
    }

    // 6. Rotate manifest if needed, then compact.
    await _rotateManifestIfNeeded();
    await _compactIfNeeded();
  }

  // ── Compaction ────────────────────────────────────────────────────────────

  /// Runs one round of compaction if any trigger condition is met.
  Future<void> _compactIfNeeded() async {
    // Single-file shortcut: collapse everything to one L2 file if total
    // data ≤ singleFileThresholdBytes.
    final totalFiles =
        (_levels[0] ?? []).length +
        (_levels[1] ?? []).length +
        (_levels[2] ?? []).length;

    if (totalFiles > 1 &&
        await _totalSstBytes() <= _config.singleFileThresholdBytes) {
      await _compactAll();
      return;
    }

    // L0 trigger: ≥ l0CompactionTrigger files.
    if ((_levels[0] ?? []).length >= _config.l0CompactionTrigger) {
      await _compactL0ToL1();
    }

    // L1 trigger: total L1 bytes > l1MaxBytes.
    if (await _levelBytes(1) > _config.l1MaxBytes) {
      await _compactL1ToL2();
    }
  }

  /// Compacts all L0 files (plus any existing L1 files) into one or more L1
  /// files.
  ///
  /// Both L0 and L1 are cleared and replaced with the compaction output. Using
  /// a single job for both input levels avoids double-counting issues.
  Future<void> _compactL0ToL1() async {
    final l0 = (_levels[0] ?? [])
        .map((f) => SstableRef(level: 0, filename: f))
        .toList();
    final l1 = (_levels[1] ?? [])
        .map((f) => SstableRef(level: 1, filename: f))
        .toList();
    final inputs = [...l0, ...l1];
    if (inputs.isEmpty) return;

    final hlc = _tick();
    final job = CompactionJob(
      sstDir: _sstDir,
      deviceId: _deviceId,
      outputLevel: 1,
      inputs: inputs,
      adapter: _adapter,
      manifestWriter: _manifestWriter,
      logNumber: _walWriter.activeSequence,
      nextSeq: hlc.encoded,
    );
    final edit = await job.run();

    // Build a set of output filenames so we never delete a file that was
    // written as the compaction output. This guards against the edge case
    // where the output HLC range exactly matches an input (same filename).
    final outputNames = edit.added.map((a) => a.filename).toSet();
    for (final ref in edit.removed) {
      if (outputNames.contains(ref.filename)) continue;
      await _adapter.deleteFile('$_sstDir/${ref.filename}');
    }

    // Clear both input levels and populate with the job's output.
    _levels[0] = [];
    _levels[1] = [];
    for (final added in edit.added) {
      (_levels[added.level] ??= []).add(added.filename);
    }
  }

  /// Compacts all L1 files into L2.
  Future<void> _compactL1ToL2() async {
    final inputs = (_levels[1] ?? [])
        .map((f) => SstableRef(level: 1, filename: f))
        .toList();
    if (inputs.isEmpty) return;

    final hlc = _tick();
    final job = CompactionJob(
      sstDir: _sstDir,
      deviceId: _deviceId,
      outputLevel: 2,
      inputs: inputs,
      adapter: _adapter,
      manifestWriter: _manifestWriter,
      logNumber: _walWriter.activeSequence,
      nextSeq: hlc.encoded,
    );
    final edit = await job.run();

    final outputNames = edit.added.map((a) => a.filename).toSet();
    for (final ref in edit.removed) {
      if (outputNames.contains(ref.filename)) continue;
      await _adapter.deleteFile('$_sstDir/${ref.filename}');
    }

    _levels[1] = [];
    for (final added in edit.added) {
      (_levels[added.level] ??= []).add(added.filename);
    }
  }

  /// Collapses all files across all levels into a single L2 file.
  ///
  /// Used when total data fits within [KvStoreConfig.singleFileThresholdBytes].
  Future<void> _compactAll() async {
    final inputs = [
      ...(_levels[0] ?? []).map((f) => SstableRef(level: 0, filename: f)),
      ...(_levels[1] ?? []).map((f) => SstableRef(level: 1, filename: f)),
      ...(_levels[2] ?? []).map((f) => SstableRef(level: 2, filename: f)),
    ];
    if (inputs.isEmpty) return;

    // Run a single job treating all inputs as a single merge and outputting to L2.
    final hlc = _tick();
    final job = CompactionJob(
      sstDir: _sstDir,
      deviceId: _deviceId,
      outputLevel: 2,
      inputs: inputs,
      adapter: _adapter,
      manifestWriter: _manifestWriter,
      logNumber: _walWriter.activeSequence,
      nextSeq: hlc.encoded,
    );
    final edit = await job.run();

    // Delete input files, but skip any whose filename matches the output.
    // When the merged HLC range equals an input's range the output is written
    // to the same path as that input; deleting it would erase the new file.
    final outputNames = edit.added.map((a) => a.filename).toSet();
    for (final ref in edit.removed) {
      if (outputNames.contains(ref.filename)) continue;
      await _adapter.deleteFile('$_sstDir/${ref.filename}');
    }

    // Update levels from VersionEdit outputs.
    _levels[0] = [];
    _levels[1] = [];
    _levels[2] = [];
    for (final added in edit.added) {
      (_levels[added.level] ??= []).add(added.filename);
    }
  }

  /// Runs compaction until all trigger conditions are cleared.
  Future<void> compactAll() async {
    for (var i = 0; i < 20; i++) {
      // Safety limit: at most 20 passes.
      final before = _levelsSummary();
      await _compactIfNeeded();
      if (_levelsSummary() == before) break; // stable
    }
  }

  // ── Manifest rotation ─────────────────────────────────────────────────────

  /// Rotates the Manifest if it has grown beyond [kManifestRotationThreshold].
  ///
  /// Writes a snapshot VersionEdit listing all live files, then updates CURRENT
  /// to point to the new Manifest.
  Future<void> _rotateManifestIfNeeded() async {
    if (!_manifestWriter.shouldRotate) return;

    // Lazily import to avoid circular reference — CurrentFile and
    // ManifestWriter are separate classes.
    await _doManifestRotation();
  }

  Future<void> _doManifestRotation() async {
    // The new manifest name is derived from the current one.
    // We import CurrentFile lazily here to keep this file self-contained.
    // CurrentFile is imported in crash_recovery.dart; here we replicate
    // the lightweight naming logic directly.
    final currentPath = '$_dbDir/CURRENT';
    final currentBytes = await _adapter.readFile(currentPath);
    final currentName = String.fromCharCodes(currentBytes).trimRight();

    const prefix = 'MANIFEST-';
    final seq = int.parse(currentName.substring(prefix.length));
    final newName = '$prefix${(seq + 1).toString().padLeft(5, '0')}';
    final newPath = '$_dbDir/$newName';

    // Build snapshot edit.
    final hlc = _tick();
    final allFiles = <SstableMeta>[];
    for (final lvlEntry in _levels.entries) {
      for (final filename in lvlEntry.value) {
        allFiles.add(
          SstableMeta(
            level: lvlEntry.key,
            filename: filename,
            minKey: '',
            maxKey: '',
            entryCount: 0,
          ),
        );
      }
    }
    final snapshotEdit = VersionEdit(
      logNumber: _walWriter.activeSequence,
      nextSeq: hlc.encoded,
      added: allFiles,
    );

    // Write new manifest.
    final newWriter = ManifestWriter(path: newPath, adapter: _adapter);
    await newWriter.append(snapshotEdit);

    // Atomically update CURRENT.
    final tmp = '$_dbDir/CURRENT.tmp';
    await _adapter.writeFile(tmp, Uint8List.fromList('$newName\n'.codeUnits));
    await _adapter.renameFile(tmp, currentPath);

    // Delete old manifest.
    await _adapter.deleteFile(_manifestWriter.path);

    _manifestWriter = newWriter;
  }

  // ── SSTable ingestion ─────────────────────────────────────────────────────

  /// Registers [filename] as an L0 SSTable and persists a [VersionEdit].
  ///
  /// The file must already be written to `[_sstDir]/[filename]`. This method:
  ///
  /// 1. Opens the SSTable reader to validate the footer checksum and read
  ///    entry metadata.
  /// 2. Advances the local HLC clock to be at least as recent as the
  ///    SSTable's max HLC (causal consistency).
  /// 3. Appends a [VersionEdit] to the Manifest.
  /// 4. Adds the file to the L0 level list.
  /// 5. Runs compaction if triggered.
  ///
  /// Throws [CorruptedSstableException] if the footer checksum is invalid.
  Future<void> ingestAt0(String filename) async {
    final path = '$_sstDir/$filename';
    // Open the reader — validates footer checksum and loads index/filter.
    final reader = await SstableReader.open(path, _adapter);
    final entryCount = reader.entryCount;

    // Determine HLC range from the filename, then advance the local clock.
    // This ensures subsequent local writes are causally after the ingested data.
    final info = SstableInfo.parse(filename);
    advanceClock(info.maxHlc);

    final hlc = _tick();

    final meta = SstableMeta(
      level: 0,
      filename: filename,
      // minKey/maxKey are not available without a full scan; use empty strings.
      // The Manifest uses these only for diagnostics, not for correctness.
      minKey: '',
      maxKey: '',
      entryCount: entryCount,
      // walSequence is null for peer-ingested files (they don't retire a WAL).
    );

    await _manifestWriter.append(
      VersionEdit(
        logNumber: _walWriter.activeSequence,
        nextSeq: hlc.encoded,
        added: [meta],
      ),
    );

    (_levels[0] ??= []).add(filename);

    // Notify listeners that new data is available (use '$sync' namespace to
    // signal sync-sourced data without targeting a specific user namespace).
    _writeEventsController.add(r'$sync');

    await _rotateManifestIfNeeded();
    await _compactIfNeeded();
  }

  // ── Close ─────────────────────────────────────────────────────────────────

  /// Flushes the active memtable (if [flush] is true) and releases the LOCK file.
  Future<void> close({bool flush = true}) async {
    if (flush && _active.length > 0) await this.flush();
    await _adapter.releaseLock('$_dbDir/LOCK');
    await _writeEventsController.close();
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  /// Returns a string key summarising the current level file counts (for
  /// compaction stability detection).
  String _levelsSummary() =>
      '${(_levels[0] ?? []).length}/${(_levels[1] ?? []).length}/${(_levels[2] ?? []).length}';

  /// Attempts to open an SSTable at [path], returning `null` on I/O error.
  Future<SstableReader?> _openReader(String path) async {
    try {
      return await SstableReader.open(path, _adapter);
    } on StorageException {
      return null;
    }
  }

  /// Gets the latest value for the user key identified by [prefix]/[prefixEnd]
  /// from an SSTable at [path].
  ///
  /// Returns `(value, found)` where `found` is true if any version exists
  /// (even if it is a tombstone). Returns `null` if the file is unreadable.
  Future<(Uint8List?, bool)?> _getFromSstable(
    String path,
    Uint8List prefix,
    Uint8List? prefixEnd,
  ) async {
    final reader = await _openReader(path);
    if (reader == null) return null;

    // Scan over all internal-key versions for this user key.
    // The LAST entry in the scan is the most recent (highest HLC).
    Uint8List? lastKey;
    Uint8List? lastValue;

    await for (final entry in reader.scan(start: prefix, end: prefixEnd)) {
      // Verify the entry's key actually starts with our prefix (safety check).
      if (!_hasPrefix(entry.key, prefix)) break;
      lastKey = entry.key;
      lastValue = entry.value;
    }

    if (lastKey == null) return null; // key not in this SSTable
    final type = KeyCodec.decodeRecordType(lastKey);
    if (type == RecordType.delete) return (null, true); // tombstone
    return (lastValue, true);
  }

  /// Returns the last entry from an iterable of [SkipListEntry]s (highest
  /// HLC = most recent version for a given user key).
  ///
  /// Returns `null` if [entries] is empty.
  ({bool isDelete, Uint8List value})? _latestFromIterable(
    Iterable<SkipListEntry> entries,
  ) {
    SkipListEntry? last;
    for (final e in entries) {
      last = e;
    }
    if (last == null) return null;
    final type = KeyCodec.decodeRecordType(last.key);
    return (isDelete: type == RecordType.delete, value: last.value);
  }

  /// Returns true when [key] starts with [prefix] byte-by-byte.
  static bool _hasPrefix(Uint8List key, Uint8List prefix) {
    if (key.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (key[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Builds the `[nsLen][ns][userKey16]` prefix used for range lookups.
  static Uint8List _buildKeyPrefix(String namespace, Uint8List userKeyBytes) {
    final nsBytes = namespace.codeUnits;
    final out = Uint8List(1 + nsBytes.length + 16);
    out[0] = nsBytes.length;
    out.setAll(1, nsBytes);
    out.setAll(1 + nsBytes.length, userKeyBytes);
    return out;
  }

  /// Builds the `[nsLen][ns]` prefix used for scanning an entire namespace.
  static Uint8List _buildNamespacePrefix(String namespace) {
    final nsBytes = namespace.codeUnits;
    final out = Uint8List(1 + nsBytes.length);
    out[0] = nsBytes.length;
    out.setAll(1, nsBytes);
    return out;
  }

  /// Returns the exclusive upper bound for a prefix scan.
  ///
  /// Increments the last non-0xFF byte of [prefix]. Returns `null` when
  /// [prefix] is all 0xFF bytes (scan has no upper bound).
  static Uint8List? _nextPrefix(Uint8List prefix) {
    if (prefix.isEmpty) return null;
    final result = Uint8List.fromList(prefix);
    for (var i = result.length - 1; i >= 0; i--) {
      if (result[i] < 0xFF) {
        result[i]++;
        return result;
      }
      result[i] = 0;
    }
    return null; // all 0xFF — no upper bound
  }

  /// Converts a memtable scan range to a [SstEntry] stream.
  Stream<SstEntry> _skipListRangeToStream(
    dynamic source, // Memtable | FrozenMemtable
    Uint8List start,
    Uint8List? end,
  ) async* {
    final Iterable<SkipListEntry> entries;
    if (source is Memtable) {
      entries = source.scan(start: start, end: end);
    } else if (source is FrozenMemtable) {
      entries = source.scan(start: start, end: end);
    } else {
      return;
    }
    for (final e in entries) {
      yield SstEntry(e.key, e.value);
    }
  }

  /// Total bytes across all SSTable files on disk.
  Future<int> _totalSstBytes() async {
    var total = 0;
    for (final level in _levels.values) {
      for (final filename in level) {
        try {
          total += await _adapter.fileSize('$_sstDir/$filename');
        } on StorageException {
          // File may have been deleted by a concurrent compaction.
        }
      }
    }
    return total;
  }

  /// Total bytes at a specific level.
  Future<int> _levelBytes(int level) async {
    var total = 0;
    for (final filename in (_levels[level] ?? [])) {
      try {
        total += await _adapter.fileSize('$_sstDir/$filename');
      } on StorageException {
        /* skip */
      }
    }
    return total;
  }

  // ── Public stats / info ───────────────────────────────────────────────────

  /// Returns the database directory path.
  String get dbDir => _dbDir;

  /// Returns the current device ID.
  String get deviceId => _deviceId;

  /// Returns the current HLC clock value as a hex string.
  ///
  /// Format: `<12 hex chars for physical ms>:<4 hex chars for logical counter>`
  String get currentHlcString {
    final physHex = _hlc.physicalMs.toRadixString(16).padLeft(12, '0');
    final logHex = _hlc.logical.toRadixString(16).padLeft(4, '0');
    return '$physHex:$logHex';
  }

  /// Returns SSTable file counts per level and total on-disk byte sizes.
  Future<({int l0, int l1, int l2, int totalSstBytes, int totalDbBytes})>
  levelStats() async {
    final l0 = (_levels[0] ?? []).length;
    final l1 = (_levels[1] ?? []).length;
    final l2 = (_levels[2] ?? []).length;
    final sstBytes = await _totalSstBytes();

    // Total DB bytes: SSTables + all files in _dbDir (WAL, Manifest, CURRENT,
    // LOCK). We sum sizes for all known SST files and add a pass over the
    // root dir for the remaining files.
    var rootBytes = 0;
    try {
      for (final name in await _adapter.listFiles(_dbDir)) {
        try {
          rootBytes += await _adapter.fileSize('$_dbDir/$name');
        } on StorageException {
          /* skip */
        }
      }
    } on StorageException {
      /* skip if dir listing fails */
    }
    final totalDbBytes = sstBytes + rootBytes;

    return (
      l0: l0,
      l1: l1,
      l2: l2,
      totalSstBytes: sstBytes,
      totalDbBytes: totalDbBytes,
    );
  }

  // ── Hex helper ────────────────────────────────────────────────────────────

  static String _bytesToHex(Uint8List bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}
