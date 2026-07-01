// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// A single chunk of text produced by [VaultChunker].
///
/// Byte offsets reference the UTF-8–encoded extracted text (`text.txt`), not
/// the original vault blob. This allows snippet retrieval by reading just the
/// relevant byte range from `text.txt` without re-decoding the blob.
///
/// The JSON schema for `chunks_v1.json` mirrors this record:
/// ```jsonc
/// { "index": 0, "byteStart": 0, "byteEnd": 1842, "wordCount": 300 }
/// ```
final class VaultChunk {
  /// Creates a [VaultChunk].
  const VaultChunk({
    required this.index,
    required this.byteStart,
    required this.byteEnd,
    required this.wordCount,
  });

  /// 0-based position of this chunk within the blob's chunk sequence.
  final int index;

  /// Inclusive byte offset (in `text.txt`) where this chunk starts.
  final int byteStart;

  /// Exclusive byte offset (in `text.txt`) where this chunk ends.
  ///
  /// The chunk text can be recovered by reading bytes `[byteStart, byteEnd)`
  /// from `text.txt` and decoding as UTF-8.
  final int byteEnd;

  /// Number of tokens (words) in this chunk.
  ///
  /// Used in BM25 scoring as the document length (`|d|`). For the final chunk
  /// this may be less than the configured [VaultSearchConfig.chunkSize].
  final int wordCount;

  /// Encodes this chunk as a JSON-serialisable [Map].
  Map<String, dynamic> toJson() => {
    'index': index,
    'byteStart': byteStart,
    'byteEnd': byteEnd,
    'wordCount': wordCount,
  };

  /// Decodes a [VaultChunk] from a JSON [Map].
  ///
  /// Throws [FormatException] if required fields are missing or have wrong types.
  factory VaultChunk.fromJson(Map<String, dynamic> json) {
    return VaultChunk(
      index: (json['index'] as num).toInt(),
      byteStart: (json['byteStart'] as num).toInt(),
      byteEnd: (json['byteEnd'] as num).toInt(),
      wordCount: (json['wordCount'] as num).toInt(),
    );
  }

  @override
  String toString() =>
      'VaultChunk(index: $index, byteStart: $byteStart, byteEnd: $byteEnd, wordCount: $wordCount)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VaultChunk &&
          index == other.index &&
          byteStart == other.byteStart &&
          byteEnd == other.byteEnd &&
          wordCount == other.wordCount;

  @override
  int get hashCode => Object.hash(index, byteStart, byteEnd, wordCount);
}
