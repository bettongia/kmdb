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
import 'wal_exceptions.dart';
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
/// await for (final record in reader.replay(path)) {
///   // process record
/// }
/// ```
///
/// ## Crash recovery
///
/// [replay] returns *all* records from the beginning of the file. Crash
/// recovery replays each retained WAL file in full; re-applying a record that
/// is already in an SSTable is idempotent under HLC last-write-wins.
final class WalReader {
  const WalReader({required this.adapter});

  /// Storage adapter for reading log files.
  final StorageAdapter adapter;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Replays all valid WAL records from [path] in order.
  ///
  /// Stops at the first corrupted or truncated record without throwing.
  /// Atomic batch frames (see §7) are transparently flattened — each entry
  /// inside the frame is yielded as a separate [WalRecord], in the order it
  /// was encoded. A truncated or checksum-failing frame is dropped whole
  /// (all-or-nothing) and replay stops there.
  Stream<WalRecord> replay(String path) async* {
    final Uint8List bytes;
    try {
      bytes = await adapter.readFile(path);
    } on StorageException {
      return; // file does not exist — nothing to replay
    }

    var offset = 0;
    while (offset < bytes.length) {
      // Need at least 9 bytes to peek at the type byte (checksum + type).
      if (bytes.length - offset < 9) break;
      final typeByte = bytes[offset + 8];
      if (typeByte == WalRecordType.batch.byte) {
        final frame = WalBatchFrame.tryDecode(bytes, offset);
        if (frame == null) break; // drop the whole frame and stop
        final (decoded, consumed) = frame;
        offset += consumed;
        for (final r in decoded.records) {
          yield r;
        }
      } else {
        final result = WalRecord.tryDecode(bytes, offset);
        if (result == null) break;
        final (record, consumed) = result;
        offset += consumed;
        yield record;
      }
    }
  }

  /// Replays all valid WAL records from [path] in strict mode.
  ///
  /// Unlike [replay], this method throws [CorruptedWalException] on the first
  /// checksum failure rather than stopping silently. Use this when you need to
  /// distinguish between a clean truncation (expected after a crash) and
  /// unexpected interior corruption that would indicate hardware-level data
  /// loss or filesystem bugs.
  ///
  /// The non-strict [replay] is used by crash recovery because the final
  /// in-flight write is always expected to be truncated. Use [replayStrict]
  /// only for offline integrity checks or diagnostic tooling.
  ///
  /// Throws [CorruptedWalException] on checksum failure.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   await for (final r in reader.replayStrict('/db/wal-00001.log')) {
  ///     processRecord(r);
  ///   }
  /// } on CorruptedWalException catch (e) {
  ///   print('Integrity failure: $e');
  /// }
  /// ```
  Stream<WalRecord> replayStrict(String path) async* {
    final Uint8List bytes;
    try {
      bytes = await adapter.readFile(path);
    } on StorageException {
      return; // file does not exist — nothing to replay
    }

    var offset = 0;
    while (offset < bytes.length) {
      if (bytes.length - offset < 9) {
        throw CorruptedWalException(
          'incomplete record header at byte $offset',
          path: path,
          offset: offset,
        );
      }
      final typeByte = bytes[offset + 8];
      if (typeByte == WalRecordType.batch.byte) {
        final frame = WalBatchFrame.tryDecode(bytes, offset);
        if (frame == null) {
          throw CorruptedWalException(
            'batch frame decode failed at byte $offset',
            path: path,
            offset: offset,
          );
        }
        final (decoded, consumed) = frame;
        offset += consumed;
        for (final r in decoded.records) {
          yield r;
        }
      } else {
        final result = WalRecord.tryDecode(bytes, offset);
        if (result == null) {
          throw CorruptedWalException(
            'record decode failed at byte $offset',
            path: path,
            offset: offset,
          );
        }
        final (record, consumed) = result;
        offset += consumed;
        yield record;
      }
    }
  }
}
