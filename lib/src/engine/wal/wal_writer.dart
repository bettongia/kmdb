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
  }) =>
      append(WalRecord(
        type: WalRecordType.put,
        sequence: sequence,
        namespace: namespace,
        key: keyBytes,
        value: value,
      ));

  /// Writes a Delete tombstone record.
  Future<void> writeDelete({
    required Hlc sequence,
    required String namespace,
    required Uint8List keyBytes,
  }) =>
      append(WalRecord(
        type: WalRecordType.delete,
        sequence: sequence,
        namespace: namespace,
        key: keyBytes,
      ));

  // ── Rotation ──────────────────────────────────────────────────────────────

  /// Writes a flush marker to the current file and opens a new WAL file.
  ///
  /// The flush marker signals that everything written before this point has
  /// been (or is being) flushed to an SSTable. On recovery, replay starts
  /// from the record after the last flush marker.
  ///
  /// Returns the path of the old (now inactive) WAL file. The engine should
  /// delete it after the corresponding SSTable is confirmed in the Manifest.
  Future<String> rotate(Hlc sequence) async {
    final oldPath = activePath;
    await append(WalRecord(
      type: WalRecordType.flushMarker,
      sequence: sequence,
    ));
    _sequence++;
    return oldPath;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _walPath(int seq) =>
      '$dirPath/wal-${seq.toString().padLeft(5, '0')}.log';
}
