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

import 'dart:typed_data';

import '../encoding/value_codec.dart';
import '../engine/util/hlc.dart';

/// A single version entry stored in the `$ver:{namespace}` system namespace.
///
/// Each time a document is written to a versioned collection, a [VersionEntry]
/// is recorded alongside it in the same [WriteBatch]. The entry carries the
/// full encoded document value so that historical snapshots can be decoded
/// symmetrically with the normal read path.
///
/// ## Storage encoding
///
/// [VersionEntry] is serialised to a [Map] and encoded via [ValueCodec]:
/// ```
/// {
///   'hlc': int,                  // 64-bit encoded HLC (physicalMs<<16|logical)
///   'encodedValue': List<int>?,  // ValueCodec-encoded document bytes; null for delete
///   'promotedFrom': int?,        // source HLC if this is a promoted write
///   'isDelete': bool,            // true for delete-version entries
/// }
/// ```
///
/// ## Key in the LSM store
///
/// The entry lives at:
/// ```
/// namespace:  $ver:{userNamespace}
/// userKey:    same 16-byte binary doc key as in the user namespace
/// hlc:        write HLC — differentiates multiple versions of the same doc key
/// ```
///
/// All versions of one document form a single contiguous group in the
/// compaction merge iterator (grouped by `[nsLen][ns][16B docKey]`), sorted
/// HLC ascending. See §26 for the structural analysis.
final class VersionEntry {
  /// Creates a [VersionEntry].
  const VersionEntry({
    required this.hlc,
    required this.encodedValue,
    this.promotedFrom,
    this.isDelete = false,
  });

  /// The HLC timestamp of this write. Matches the HLC embedded in the LSM
  /// internal key for this entry, uniquely identifying this version.
  final Hlc hlc;

  /// The [ValueCodec]-encoded document bytes at the time of this write.
  ///
  /// `null` for a delete-version entry ([isDelete] == `true`). The bytes are
  /// identical to what is stored under the document's main-namespace key at
  /// the same HLC, so decoding is symmetric: `ValueCodec.decode(encodedValue)`
  /// yields the document map.
  final Uint8List? encodedValue;

  /// The HLC of the source version when this entry was created by
  /// [KmdbCollection.promoteVersion]. `null` for writes that originate from
  /// a direct `put()` or `insert()`.
  ///
  /// This field provides an explicit audit trail: callers can trace the chain
  /// of promotions back to the original write.
  final Hlc? promotedFrom;

  /// Whether this entry records a document deletion.
  ///
  /// A delete-version has [encodedValue] == `null` and is the newest entry in
  /// the `$ver:` chain when the document is in the deleted state. Promoting a
  /// prior put-version effectively un-deletes the document.
  final bool isDelete;

  // ── Serialisation ───────────────────────────────────────────────────────────

  /// Encodes this entry to a [Map] suitable for [ValueCodec.encode].
  ///
  /// The `encodedValue` bytes are stored as a Dart [List<int>] (CBOR byte
  /// string) within the outer CBOR envelope so the entire entry round-trips
  /// through [ValueCodec] without nested compression.
  Map<String, dynamic> toMap() => {
    'hlc': hlc.encoded,
    if (encodedValue != null) 'encodedValue': encodedValue!.toList(),
    if (promotedFrom != null) 'promotedFrom': promotedFrom!.encoded,
    'isDelete': isDelete,
  };

  /// Encodes this entry via [ValueCodec] for storage in the LSM engine.
  Uint8List encode() => ValueCodec.encode(toMap());

  /// Decodes a [VersionEntry] from a [ValueCodec]-encoded byte sequence.
  ///
  /// Throws [FormatException] if [bytes] cannot be decoded or are missing
  /// required fields.
  static VersionEntry decode(Uint8List bytes) {
    final map = ValueCodec.decode(bytes);
    return fromMap(map);
  }

  /// Constructs a [VersionEntry] from a decoded [Map].
  ///
  /// Throws [FormatException] if required fields are absent or have unexpected
  /// types.
  static VersionEntry fromMap(Map<String, dynamic> map) {
    final hlcEncoded = map['hlc'];
    // The stored hlc is always Hlc(0, 0) = 0 (a small int), but future writes
    // could theoretically store a non-zero value. Accept both int and BigInt
    // for the same reason as promotedFrom below.
    final int hlcInt;
    if (hlcEncoded is int) {
      hlcInt = hlcEncoded;
    } else if (hlcEncoded is BigInt) {
      hlcInt = hlcEncoded.toInt();
    } else {
      throw FormatException(
        'VersionEntry: expected int or BigInt for hlc, got ${hlcEncoded.runtimeType}',
      );
    }
    final hlc = Hlc.fromEncoded(hlcInt);

    final rawValue = map['encodedValue'];
    Uint8List? encodedValue;
    if (rawValue != null) {
      if (rawValue is List) {
        encodedValue = Uint8List.fromList(rawValue.cast<int>());
      } else {
        throw FormatException(
          'VersionEntry: expected List for encodedValue, got ${rawValue.runtimeType}',
        );
      }
    }

    final rawPromotedFrom = map['promotedFrom'];
    Hlc? promotedFrom;
    if (rawPromotedFrom != null) {
      // Large HLC values (> 2^32) are encoded as CBOR uint64 and decoded as
      // BigInt by the cbor library's toObject() method. Accept both int and
      // BigInt so that decoded entries are always readable regardless of value
      // magnitude.
      if (rawPromotedFrom is int) {
        promotedFrom = Hlc.fromEncoded(rawPromotedFrom);
      } else if (rawPromotedFrom is BigInt) {
        promotedFrom = Hlc.fromEncoded(rawPromotedFrom.toInt());
      } else {
        throw FormatException(
          'VersionEntry: expected int or BigInt for promotedFrom, got ${rawPromotedFrom.runtimeType}',
        );
      }
    }

    final isDelete = map['isDelete'] as bool? ?? false;

    return VersionEntry(
      hlc: hlc,
      encodedValue: encodedValue,
      promotedFrom: promotedFrom,
      isDelete: isDelete,
    );
  }

  @override
  String toString() =>
      'VersionEntry(hlc: ${hlc.toHex()}, '
      'isDelete: $isDelete, '
      'promotedFrom: ${promotedFrom?.toHex()})';
}

/// A decoded version of a document returned by
/// [KmdbCollection.getVersions].
///
/// [DocumentVersion] is the public query API type — it exposes a decoded
/// [value] map and a human-readable [timestamp] rather than raw bytes.
///
/// ## Example
///
/// ```dart
/// final versions = await tasks.getVersions(docKey);
/// for (final v in versions) {
///   print('${v.timestamp}: ${v.value?['title'] ?? '(deleted)'}');
/// }
/// ```
final class DocumentVersion {
  /// Creates a [DocumentVersion].
  const DocumentVersion({
    required this.id,
    required this.hlc,
    required this.timestamp,
    required this.value,
    required this.isDelete,
    this.promotedFrom,
  });

  /// The document key this version belongs to.
  final String id;

  /// The HLC timestamp of this write.
  ///
  /// Uniquely identifies this version within the collection. Pass this value
  /// to [KmdbCollection.promoteVersion] to restore this version.
  final Hlc hlc;

  /// Wall-clock time at which this version was written, derived from
  /// [hlc.physicalMs].
  ///
  /// Subject to clock skew across devices. Use [hlc] for causal ordering;
  /// use [timestamp] only for display purposes.
  final DateTime timestamp;

  /// The decoded document value at this version, or `null` for a
  /// delete-version entry.
  ///
  /// The `_id` field is **not** injected into this map (unlike the normal
  /// `KmdbCollection.get` path). Callers who need the document ID should use
  /// the [id] field.
  final Map<String, dynamic>? value;

  /// The HLC of the source version when this version was created by a
  /// promotion. `null` for writes that originate from a direct `put()` or
  /// `insert()`.
  final Hlc? promotedFrom;

  /// Whether this version records a document deletion.
  final bool isDelete;

  @override
  String toString() =>
      'DocumentVersion(id: $id, hlc: ${hlc.toHex()}, '
      'isDelete: $isDelete)';
}
