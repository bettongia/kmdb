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
import 'wal_record.dart';

/// Replays WAL records from a single log file.
///
/// Replay stops cleanly at the first checksum failure, which indicates either
/// a truncation (normal crash scenario — the last in-flight append was not
/// completed) or silent corruption (the record is discarded). No exception is
/// thrown for a checksum mismatch — callers receive all records up to that
/// point.
///
/// ## Usage
///
/// ```dart
/// final reader = WalReader(adapter: adapter);
/// await for (final record in reader.replay('/db/wal-00001.log')) {
///   // process record
/// }
/// ```
///
/// ## Crash recovery
///
/// [replay] returns *all* records from the beginning of the file. The
/// [LsmEngine] uses [replayFromLastFlush] to efficiently skip records that
/// are already safely in an SSTable.
final class WalReader {
  const WalReader({required this.adapter});

  /// Storage adapter for reading log files.
  final StorageAdapter adapter;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Replays all valid WAL records from [path] in order.
  ///
  /// Stops at the first corrupted or truncated record without throwing.
  Stream<WalRecord> replay(String path) async* {
    final Uint8List bytes;
    try {
      bytes = await adapter.readFile(path);
    } on StorageException {
      return; // file does not exist — nothing to replay
    }

    var offset = 0;
    while (offset < bytes.length) {
      final result = WalRecord.tryDecode(bytes, offset);
      if (result == null) break; // truncation or corruption — stop here
      final (record, consumed) = result;
      offset += consumed;
      yield record;
    }
  }

  /// Replays only the records that follow the last [WalRecordType.flushMarker]
  /// in [path].
  ///
  /// Records before (and including) the flush marker are already persisted in
  /// an SSTable and should not be re-applied to the memtable. If no flush
  /// marker exists, all records are returned (the file was never fully flushed
  /// before the crash).
  Stream<WalRecord> replayFromLastFlush(String path) async* {
    // We must buffer all records to find the last flush marker.
    final all = <WalRecord>[];
    await for (final r in replay(path)) {
      all.add(r);
    }

    // Find the last flush marker position.
    var startIndex = 0;
    for (var i = all.length - 1; i >= 0; i--) {
      if (all[i].type == WalRecordType.flushMarker) {
        startIndex = i + 1; // start replay from the record after the marker
        break;
      }
    }

    for (var i = startIndex; i < all.length; i++) {
      yield all[i];
    }
  }

  /// Replays all records from each WAL file in [paths] (sorted by sequence).
  ///
  /// Each file is replayed using [replayFromLastFlush]. The files must be
  /// provided in ascending sequence-number order.
  Stream<WalRecord> replayAll(List<String> paths) async* {
    for (final path in paths) {
      yield* replayFromLastFlush(path);
    }
  }
}
