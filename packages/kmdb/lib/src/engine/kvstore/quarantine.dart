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

/// @docImport 'kv_store.dart';
/// @docImport 'meta_store.dart';
/// @docImport '../sstable/sstable_reader.dart';
/// @docImport '../platform/storage_adapter_interface.dart';
/// @docImport '../../sync/sync_engine.dart';
/// @docImport '../../sync/pull_result.dart';
library;

import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../util/hlc.dart';

/// The reason a peer SSTable was quarantined by `SyncEngine.pull`.
///
/// Each value maps 1:1 to one of the five exception types `pull` catches
/// around `KvStore.ingestSstable` — see that method's catch clauses for the
/// exact throw sites. The enum exists so a host application can branch on
/// *why* a file was dropped without coupling to exception identity (which
/// would require importing engine-internal exception types and pattern-
/// matching on `runtimeType`).
///
/// **Not included:** `StaleSstableIngestException` never reaches this enum —
/// a sub-floor file is deferred (`DeferredSstable`), not quarantined; it is
/// retried automatically and is never persisted. See that type's doc comment
/// for why the two cases must stay structurally distinct.
enum QuarantineReason {
  /// The file's structural checksum(s) failed — thrown as
  /// `CorruptedSstableException` by `SstableReader.open` or a data-block
  /// decode. The file's bytes were altered after being written, whether by
  /// bit-rot, a truncated upload, or deliberate tampering.
  corruptedSstable,

  /// The file failed to parse for a reason that surfaced as a
  /// `FormatException` — e.g. a malformed varint encountered while decoding
  /// the index block. The file's checksum(s) passed but its internal
  /// structure does not conform to the SSTable format.
  invalidFormat,

  /// A structural bounds violation slipped past `SstableReader`'s own
  /// validation and was caught as a bare `RangeError` — belt-and-suspenders
  /// defence against an index or block entry that points outside the bytes
  /// actually available in memory.
  structuralBoundsViolation,

  /// A footer or index field pointed past the end of the file, surfaced as
  /// `StorageException` from `StorageAdapterNative.readFileRange` (or the
  /// equivalent web adapter) when it refused to satisfy an out-of-bounds
  /// range read.
  storageError,

  /// Reading or decoding the file attempted to allocate more memory than is
  /// reasonable for its declared size, thrown as `OutOfMemoryError`. Caught
  /// explicitly — never via a bare `catch` — because `OutOfMemoryError` is an
  /// `Error`, not an `Exception`, and a bare `catch` would also trap
  /// `SyncCancelledException`, which must always propagate uncaught.
  outOfMemory,
}

/// A single durable record of a peer SSTable that `SyncEngine.pull` rejected
/// and permanently quarantined — the file's contents were dropped and the
/// per-peer high-water mark was advanced past it, so it will never be
/// re-fetched.
///
/// ## Why this is persisted (finding A3)
///
/// Quarantine is a **permanent, one-way** decision made by exactly one
/// `pull()` call — the one that dropped the file — and never revisited. Before
/// this type existed, the only trace of that decision was a console `print`;
/// if the host application did not happen to inspect that specific pull's
/// result (a background sync, or the process being killed mid-cycle), the
/// signal was lost forever even though the data loss was permanent. Each
/// [QuarantinedSstable] is therefore written to the device-local
/// `MetaStore.kQuarantineNamespace` log *before* the high-water mark that
/// makes the drop irreversible is persisted — see `SyncEngine.pull`'s
/// crash-safety ordering note — so the record survives a crash, a missed
/// pull result, or the application never having asked.
///
/// ## Storage
///
/// Encoded via [toCbor]/[fromCbor] as a raw CBOR map (not [ValueCodec] — this
/// is not a `Map<String, dynamic>`-shaped document value, it is an opaque
/// engine-state blob, the same category as the other `$$…state` entries in
/// `MetaStore`) and wrapped with `EncryptionEnvelope` when a provider is
/// configured. See `MetaStore.appendQuarantine`.
final class QuarantinedSstable {
  /// Creates a [QuarantinedSstable] record.
  const QuarantinedSstable({
    required this.peerDeviceId,
    required this.filename,
    required this.maxHlc,
    required this.reason,
    required this.detail,
    required this.quarantinedAt,
  });

  /// The 8-character hex device ID of the peer that produced the rejected
  /// file, parsed from [filename].
  final String peerDeviceId;

  /// The bare SSTable filename that was rejected (e.g.
  /// `a1b2c3d4-017F8A0A00000000-017F8A0AFFFF0000.sst`).
  final String filename;

  /// The file's `maxHlc`, parsed from [filename] before any of the
  /// untrusted file body was read. This is the HLC the per-peer high-water
  /// mark was advanced past — the data at or below this HLC from this peer
  /// is what was permanently dropped.
  final Hlc maxHlc;

  /// Which of the five caught exception types triggered the quarantine.
  final QuarantineReason reason;

  /// The rejecting exception's message string.
  ///
  /// Deliberately a `String`, never the live exception `Object` — this value
  /// is persisted to disk and must not carry a reference to (or attempt to
  /// serialise) an arbitrary runtime exception instance.
  final String detail;

  /// Wall-clock time at which the quarantine was recorded.
  final DateTime quarantinedAt;

  // ── Serialisation ───────────────────────────────────────────────────────────

  /// Current CBOR map schema version, mirroring the pattern used by
  /// `EncryptionBlob.kVersion`.
  static const int kVersion = 1;

  /// Encodes this record as a raw CBOR map.
  ///
  /// Not routed through `ValueCodec` — see the class doc comment for why.
  /// Uses `CborValue`'s automatic Dart-value conversion, the same idiom
  /// `ValueCodec._toCbor` uses for document maps, rather than hand-building
  /// typed `Cbor*` leaves. The caller (`MetaStore.appendQuarantine`) wraps the
  /// returned bytes with `EncryptionEnvelope` before writing.
  Uint8List toCbor() {
    final map = <String, dynamic>{
      'v': kVersion,
      'peerDeviceId': peerDeviceId,
      'filename': filename,
      'maxHlc': maxHlc.encoded,
      'reason': reason.name,
      'detail': detail,
      'quarantinedAt': quarantinedAt.toUtc().millisecondsSinceEpoch,
    };
    return Uint8List.fromList(cbor.encode(CborValue(map)));
  }

  /// Decodes a [QuarantinedSstable] from CBOR bytes previously produced by
  /// [toCbor].
  ///
  /// Throws [FormatException] if [bytes] is not valid CBOR, is not a map, or
  /// is missing/mistyped a required field — including an unrecognised
  /// [QuarantineReason] name (e.g. a record written by a newer build than
  /// this one understands).
  factory QuarantinedSstable.fromCbor(Uint8List bytes) {
    final CborValue decoded;
    try {
      decoded = cbor.decode(bytes);
    } catch (e) {
      throw FormatException('Invalid quarantine record CBOR: $e');
    }
    if (decoded is! CborMap) {
      throw FormatException(
        'Quarantine record must be a CBOR map, got ${decoded.runtimeType}',
      );
    }
    final map = decoded.toObject() as Map<dynamic, dynamic>;

    String getString(String key) {
      final v = map[key];
      if (v is! String) {
        throw FormatException(
          'Missing or invalid string field "$key" in quarantine record: '
          'got ${v?.runtimeType}',
        );
      }
      return v;
    }

    int getInt(String key) {
      final v = map[key];
      if (v is int) return v;
      if (v is BigInt) return v.toInt();
      throw FormatException(
        'Missing or invalid int field "$key" in quarantine record: '
        'got ${v?.runtimeType}',
      );
    }

    final reasonName = getString('reason');
    final reason = QuarantineReason.values
        .where((r) => r.name == reasonName)
        .firstOrNull;
    if (reason == null) {
      throw FormatException(
        'Unrecognised QuarantineReason "$reasonName" in quarantine record',
      );
    }

    return QuarantinedSstable(
      peerDeviceId: getString('peerDeviceId'),
      filename: getString('filename'),
      maxHlc: Hlc.fromEncoded(getInt('maxHlc')),
      reason: reason,
      detail: getString('detail'),
      quarantinedAt: DateTime.fromMillisecondsSinceEpoch(
        getInt('quarantinedAt'),
        isUtc: true,
      ),
    );
  }
}
