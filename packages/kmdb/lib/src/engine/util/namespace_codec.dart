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

import 'dart:convert';
import 'dart:typed_data';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

// ── Namespace encoding ─────────────────────────────────────────────────────
//
// Namespaces are user-supplied collection names that appear in every internal
// key, WAL record, and engine scan prefix. Three requirements apply:
//
//   1. **Real UTF-8** — the on-disk format stores namespace bytes in a
//      length-prefixed field whose length byte is a single uint8, so the
//      namespace is limited to 255 bytes. Dart's `String.codeUnits` yields
//      UTF-16 code units, not UTF-8, and values above U+00FF are silently
//      truncated to their low 8 bits, corrupting non-Latin namespaces.
//      Using `utf8.encode`/`utf8.decode` fixes this.
//
//   2. **NFC normalisation** — two visually identical namespace strings that
//      differ only in Unicode normalisation form (e.g. NFC "é" U+00E9 vs
//      NFD "e" U+0065 + combining acute U+0301) encode to different UTF-8
//      byte sequences and would resolve to different namespaces, causing a
//      "my collection disappeared" bug. Normalising to NFC at the public
//      boundary ensures a canonical form before encoding.
//
//   3. **255-byte length guard** — the namespace length is stored in a single
//      byte prefix, so the UTF-8 byte length must not exceed 255. The guard
//      is checked against the UTF-8 byte count (not the Dart string length or
//      the code-unit count), because that is what actually lands on disk.
//
// All three namespace encoding sites (KeyCodec, WalRecord, LsmEngine scan
// prefixes) route through this single helper so they can never diverge.

/// The maximum number of UTF-8 bytes a namespace may occupy.
///
/// Enforced by the 1-byte `nsLen` field in the internal key and WAL record
/// formats. Any namespace whose UTF-8 encoding exceeds this limit is rejected
/// at the public boundary with a descriptive [ArgumentError].
const int kMaxNamespaceBytes = 255;

/// Canonicalises [namespace] and encodes it to UTF-8 bytes.
///
/// The following steps are applied in order:
///
/// 1. **NFC normalisation** — the string is normalised to Unicode NFC form so
///    that equivalent names in different normalisation forms (NFC vs NFD) map
///    to identical byte sequences.
/// 2. **UTF-8 encoding** — the normalised string is encoded with `dart:convert`
///    `utf8.encode`, which correctly represents every Unicode scalar value.
/// 3. **Length guard** — the byte length must not exceed [kMaxNamespaceBytes]
///    (255). If it does, an [ArgumentError] is thrown naming the namespace and
///    its byte length.
///
/// This function is the single source of truth for namespace-to-bytes
/// conversion. Every encoding site (internal keys, WAL records, scan prefixes)
/// must call this function rather than using `String.codeUnits` or any other
/// ad-hoc encoding.
///
/// Example:
/// ```dart
/// final bytes = namespaceToBytes('café'); // NFC-normalised UTF-8
/// ```
Uint8List namespaceToBytes(String namespace) {
  // Normalise to NFC so that visually equivalent names resolve to one
  // namespace regardless of how the caller composed the string.
  final normalised = unorm.nfc(namespace);

  // Encode to real UTF-8 (not codeUnits, which would truncate non-BMP chars).
  final bytes = utf8.encode(normalised);

  // The on-disk length prefix is one byte, so the byte length cap is 255.
  if (bytes.length > kMaxNamespaceBytes) {
    throw ArgumentError(
      'Namespace exceeds $kMaxNamespaceBytes UTF-8 bytes '
          '(got ${bytes.length}): $namespace',
      'namespace',
    );
  }

  return Uint8List.fromList(bytes);
}

/// Decodes a namespace from its UTF-8 byte representation.
///
/// This is the inverse of [namespaceToBytes]. The bytes are expected to be
/// valid UTF-8; [utf8.decode] is used (not `String.fromCharCodes`, which
/// would misinterpret multi-byte sequences as individual code points).
///
/// The result is already in NFC form because [namespaceToBytes] normalised
/// before encoding. No additional normalisation is applied on decode.
String bytesToNamespace(List<int> bytes) => utf8.decode(bytes);

/// NFC-normalises [namespace] at the public API boundary.
///
/// Call this before any KvStore method that accepts a namespace string so that
/// all downstream encoding sees a canonical NFC form. This prevents the
/// "collection disappeared" bug that would arise if a caller supplies the same
/// logical name in two different normalisation forms.
///
/// This function does **not** encode to bytes; use [namespaceToBytes] for that.
///
/// Example:
/// ```dart
/// final ns = normaliseNamespace(userInput); // NFC canonical form
/// await store.put(ns, key, value);
/// ```
String normaliseNamespace(String namespace) => unorm.nfc(namespace);

/// Returns `true` if [namespace] is a local-only derived-data namespace.
///
/// The `$$` (double-dollar) prefix marks namespaces whose contents are
/// device-local derived data that should never be synced to other devices.
/// The three built-in local-only namespace classes are:
///
/// - `$$fts:*` — BM25 inverted-index entries (lexical full-text search)
/// - `$$vec:*` — SQ8-quantized embedding vectors (semantic search)
/// - `$$index:*` — secondary index entries
///
/// At flush time the memtable is partitioned into two SSTables: one for
/// syncable namespaces and one for local-only namespaces. The sync engine
/// skips files whose filename ends in `.local.sst` (the naming convention
/// for local-only SSTables). Compaction preserves this partition.
///
/// The `$$` prefix is a strict superset of the `$` prefix: every check that
/// guards on `ns.startsWith(r'$')` (system-namespace guards in `KvStore`,
/// `CacheLayer`, `KmdbDatabase`, and `IndexDefinition`) already covers
/// `$$`-prefixed namespaces, so no new wiring is required at those call sites.
///
/// Example:
/// ```dart
/// isLocalOnly(r'$$fts:articles:body:68656c6c6f'); // true
/// isLocalOnly(r'$meta');                            // false
/// isLocalOnly('users');                             // false
/// ```
bool isLocalOnly(String namespace) => namespace.startsWith(r'$$');
