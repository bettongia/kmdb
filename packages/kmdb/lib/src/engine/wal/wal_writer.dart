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

  /// The sequence number of the currently active WAL file.
  int get activeSequence => _sequence;

  /// Full path of the currently active WAL file.
  String get activePath => _walPath(_sequence);

  // ── Write operations ──────────────────────────────────────────────────────

  /// Appends a single [record] to the active WAL file.
  ///
  /// Optionally fsyncs after writing if [fsyncOnWrite] is true.
  Future<void> append(WalRecord record) async {
    final bytes = record.encode();
    await adapter.appendFile(activePath, bytes);
    if (fsyncOnWrite) await adapter.syncFile(activePath);
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
  Future<void> appendBatch(List<WalRecord> records) async {
    final frame = WalBatchFrame(records);
    final bytes = frame.encode();
    await adapter.appendFile(activePath, bytes);
    if (fsyncOnWrite) await adapter.syncFile(activePath);
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
    return oldPath;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _walPath(int seq) =>
      '$dirPath/wal-${seq.toString().padLeft(5, '0')}.log';
}
