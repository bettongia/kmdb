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

/// Exception thrown when a WAL file fails a strict integrity check.
///
/// During normal crash recovery, WAL replay stops silently at the first
/// corrupted or truncated record — partial data at the tail of the file is an
/// expected consequence of a crash mid-write. [CorruptedWalException] is
/// reserved for scenarios where the corruption cannot be explained by a clean
/// truncation: for example, when interior records are corrupt while later
/// records are intact, or when a file is wholly unreadable.
///
/// Use `WalReader.replayStrict` to opt in to strict mode where any checksum
/// failure causes this exception to be thrown rather than silently stopping
/// replay.
///
/// Example:
/// ```dart
/// try {
///   await for (final record in reader.replayStrict('/db/wal-00001.log')) {
///     processRecord(record);
///   }
/// } on CorruptedWalException catch (e) {
///   log.error('WAL integrity failure: $e');
///   // Handle unrecoverable WAL corruption.
/// }
/// ```
final class CorruptedWalException implements Exception {
  const CorruptedWalException(this.message, {this.path, this.offset});

  /// Human-readable description of the corruption.
  final String message;

  /// Path to the WAL file, if known.
  final String? path;

  /// Byte offset in the file where the corruption was detected, if known.
  final int? offset;

  @override
  String toString() {
    final loc = [
      if (path != null) path,
      if (offset != null) 'offset $offset',
    ].join(', ');
    return loc.isEmpty
        ? 'CorruptedWalException: $message'
        : 'CorruptedWalException($loc): $message';
  }
}
