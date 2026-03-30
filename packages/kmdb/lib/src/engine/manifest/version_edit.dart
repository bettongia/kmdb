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

import 'package:cbor/cbor.dart';

/// Converts a CBOR-decoded numeric value to a Dart [int].
///
/// The `cbor` package's `toObject()` may return [BigInt] for integer values
/// that exceed 32 bits. This helper handles both cases transparently.
int _toInt(dynamic v) {
  if (v is int) return v;
  if (v is BigInt) return v.toInt();
  return (v as num).toInt();
}

/// Metadata for one SSTable file referenced in a [VersionEdit].
final class SstableMeta {
  const SstableMeta({
    required this.level,
    required this.filename,
    required this.minKey,
    required this.maxKey,
    required this.entryCount,
    this.walSequence,
  });

  /// LSM level this file belongs to (0, 1, or 2).
  final int level;

  /// Bare filename (no directory path), e.g. `a1b2c3d4-….sst`.
  final String filename;

  /// Hex-encoded minimum internal key in this file.
  final String minKey;

  /// Hex-encoded maximum internal key in this file.
  final String maxKey;

  /// Number of key-value entries in this file.
  final int entryCount;

  /// WAL sequence number retired by the flush that produced this file.
  ///
  /// Non-null only for L0 flush outputs; null for compaction-produced files
  /// and peer-ingested files.
  final int? walSequence;

  Map<String, dynamic> toMap() => {
        'level': level,
        'filename': filename,
        'minKey': minKey,
        'maxKey': maxKey,
        'entryCount': entryCount,
        if (walSequence != null) 'walSequence': walSequence,
      };

  static SstableMeta fromMap(Map<dynamic, dynamic> m) => SstableMeta(
        level: _toInt(m['level']),
        filename: m['filename'] as String,
        minKey: m['minKey'] as String,
        maxKey: m['maxKey'] as String,
        entryCount: _toInt(m['entryCount']),
        walSequence: m['walSequence'] != null ? _toInt(m['walSequence']) : null,
      );
}

/// A reference to an SSTable file that was removed (input to compaction).
final class SstableRef {
  const SstableRef({required this.level, required this.filename});

  final int level;
  final String filename;

  Map<String, dynamic> toMap() => {'level': level, 'filename': filename};

  static SstableRef fromMap(Map<dynamic, dynamic> m) => SstableRef(
        level: _toInt(m['level']),
        filename: m['filename'] as String,
      );
}

/// A single atomic state transition written to the Manifest.
///
/// Describes which SSTables were added and which were removed in one operation
/// (flush, compaction, or peer ingestion). Replaying a sequence of
/// [VersionEdit]s in order reconstructs the complete LSM level state.
///
/// ## CBOR schema
///
/// ```json
/// {
///   "logNumber": 2,
///   "nextSeq": 10042,
///   "add": [{ "level": 0, "filename": "…", "minKey": "…", "maxKey": "…",
///             "entryCount": 128, "walSequence": 2 }],
///   "remove": [{ "level": 0, "filename": "…" }]
/// }
/// ```
final class VersionEdit {
  const VersionEdit({
    required this.logNumber,
    required this.nextSeq,
    this.added = const [],
    this.removed = const [],
  });

  /// WAL sequence number active when this edit was written.
  final int logNumber;

  /// Next HLC sequence number at the time of this edit (for clock recovery).
  final int nextSeq;

  /// SSTables added in this transition.
  final List<SstableMeta> added;

  /// SSTables removed in this transition.
  final List<SstableRef> removed;

  // ── Serialisation ─────────────────────────────────────────────────────────

  /// Encodes this edit to CBOR bytes.
  List<int> toCbor() {
    final map = <String, dynamic>{
      'logNumber': logNumber,
      'nextSeq': nextSeq,
      'add': added.map((e) => e.toMap()).toList(),
      'remove': removed.map((e) => e.toMap()).toList(),
    };
    return cbor.encode(CborValue(map));
  }

  /// Decodes a [VersionEdit] from CBOR bytes.
  ///
  /// Throws [FormatException] if the bytes are not a valid CBOR map.
  static VersionEdit fromCbor(List<int> bytes) {
    final decoded = cbor.decode(bytes);
    if (decoded is! CborMap) {
      throw FormatException('VersionEdit must be a CBOR map');
    }
    final m = decoded.toObject() as Map<dynamic, dynamic>;
    final addList = (m['add'] as List? ?? [])
        .cast<Map<dynamic, dynamic>>()
        .map(SstableMeta.fromMap)
        .toList();
    final removeList = (m['remove'] as List? ?? [])
        .cast<Map<dynamic, dynamic>>()
        .map(SstableRef.fromMap)
        .toList();
    return VersionEdit(
      logNumber: _toInt(m['logNumber']),
      nextSeq: _toInt(m['nextSeq']),
      added: addList,
      removed: removeList,
    );
  }
}
