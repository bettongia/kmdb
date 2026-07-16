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

import 'dart:typed_data';

import '../platform/storage_adapter_interface.dart';
import '../util/hlc.dart';
import 'wal_record.dart';

/// Appends WAL records to a sequentially-numbered log file.
///
/// Each [WalWriter] owns exactly one active log file. When the engine freezes
/// the current memtable it calls [rotate] to open a new WAL file; the old file
/// is retained until the corresponding SSTable is confirmed in the Manifest.
///
/// ## File naming
///
/// ```
/// wal-{sequence:05d}.log   e.g. wal-00001.log
/// ```
///
/// ## Fsync behaviour
///
/// When [fsyncOnWrite] is true (the default for production) every [append]
/// call issues an fsync via [StorageAdapter.syncFile] after writing. Set false
/// only in tests where durability is not required — this trades crash-safety
/// for write throughput.
///
/// ## Directory-entry durability
///
/// A file's content fsync does not, on a strict-POSIX filesystem, durably
/// persist the fact that the file exists in its parent directory — that
/// requires a separate fsync of the parent directory. [append] and
/// [appendBatch] therefore also `syncDir` [dirPath] the first time they write
/// to a newly-active file (once per file, not once per write — see
/// [_syncDirOnce]), so a freshly-created WAL file's directory entry is
/// durable intrinsically rather than depending on some unrelated later
/// `syncDir` call elsewhere in the engine. See §07 ("Directory-entry
/// durability") for the full invariant.
final class WalWriter {
  WalWriter({
    required this.dirPath,
    required this.adapter,
    required int initialSequence,
    this.fsyncOnWrite = true,
  }) : _sequence = initialSequence;

  /// Directory that holds all `wal-*.log` files.
  final String dirPath;

  /// Storage adapter used for all I/O.
  final StorageAdapter adapter;

  /// Whether to fsync after each append.
  final bool fsyncOnWrite;

  int _sequence;

  /// Whether the active file's directory entry has already been synced.
  ///
  /// Starts `false` for every newly-constructed [WalWriter] (even on reopen
  /// against a file that already exists on disk — the first write after
  /// construction pays one redundant `syncDir`, which is cheap and simpler
  /// than tracking pre-existing durability) and is reset to `false` by
  /// [rotate], since the next active file has not had its directory entry
  /// synced yet.
  bool _activeDirSynced = false;

  /// The sequence number of the currently active WAL file.
  int get activeSequence => _sequence;

  /// Full path of the currently active WAL file.
  String get activePath => _walPath(_sequence);

  // ── Write operations ──────────────────────────────────────────────────────

  /// Appends a single [record] to the active WAL file.
  ///
  /// Optionally fsyncs after writing if [fsyncOnWrite] is true, and — the
  /// first time this is called for a newly-active file — durably syncs the
  /// file's directory entry too (see "Directory-entry durability" above).
  Future<void> append(WalRecord record) async {
    final bytes = record.encode();
    await adapter.appendFile(activePath, bytes);
    if (fsyncOnWrite) await adapter.syncFile(activePath);
    await _syncDirOnce();
  }

  /// Writes a Put record for the given namespace, key, and value.
  ///
  /// [keyBytes] must be exactly 16 bytes (binary UUIDv7).
  Future<void> writePut({
    required Hlc sequence,
    required String namespace,
    required Uint8List keyBytes,
    required Uint8List value,
  }) => append(
    WalRecord(
      type: WalRecordType.put,
      sequence: sequence,
      namespace: namespace,
      key: keyBytes,
      value: value,
    ),
  );

  /// Writes a Delete tombstone record.
  Future<void> writeDelete({
    required Hlc sequence,
    required String namespace,
    required Uint8List keyBytes,
  }) => append(
    WalRecord(
      type: WalRecordType.delete,
      sequence: sequence,
      namespace: namespace,
      key: keyBytes,
    ),
  );

  /// Writes a [WalBatchFrame] containing all [records] as a single atomic unit.
  ///
  /// All records are encoded under one checksum, appended in one `appendFile`
  /// call, and fsynced once (if [fsyncOnWrite] is true). This collapses N
  /// individual per-record fsyncs into one, which is both faster and the basis
  /// for the all-or-nothing crash guarantee — a truncated or corrupt frame is
  /// dropped whole during recovery, never partially applied (review finding H2).
  ///
  /// Also durably syncs the active file's directory entry the first time this
  /// is called for a newly-active file (see "Directory-entry durability" on
  /// the class doc comment).
  Future<void> appendBatch(List<WalRecord> records) async {
    final frame = WalBatchFrame(records);
    final bytes = frame.encode();
    await adapter.appendFile(activePath, bytes);
    if (fsyncOnWrite) await adapter.syncFile(activePath);
    await _syncDirOnce();
  }

  // ── Rotation ──────────────────────────────────────────────────────────────

  /// Closes the current WAL file and opens the next one, returning the path of
  /// the old (now inactive) file.
  ///
  /// No boundary marker is written into the retiring file: recovery replays
  /// every retained WAL in full (idempotent under HLC last-write-wins), so a
  /// marker would add no information and historically created a data-loss
  /// hazard — a marker fsync'd before its SSTable became durable caused
  /// recovery to skip still-live records (review finding C1). The engine should
  /// delete the returned file only after the corresponding SSTable is confirmed
  /// in the Manifest.
  Future<String> rotate() async {
    final oldPath = activePath;
    _sequence++;
    _activeDirSynced = false;
    return oldPath;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _walPath(int seq) =>
      '$dirPath/wal-${seq.toString().padLeft(5, '0')}.log';

  /// Durably syncs [dirPath] the first time this is called for the current
  /// active file, then remembers not to do it again until [rotate] resets the
  /// flag. Must be called only after the file's content has already been
  /// synced (via [StorageAdapter.syncFile]) — fault-injecting test adapters
  /// treat `syncDir` as the point a path becomes durable, so calling it before
  /// the content sync would make the path durable with empty bytes rather
  /// than the written content.
  ///
  /// No-op when [fsyncOnWrite] is false, matching the existing content-fsync
  /// skip in that mode.
  Future<void> _syncDirOnce() async {
    if (!fsyncOnWrite || _activeDirSynced) return;
    await adapter.syncDir(dirPath);
    _activeDirSynced = true;
  }
}
