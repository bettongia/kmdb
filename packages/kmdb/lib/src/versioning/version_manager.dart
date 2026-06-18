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

import '../encoding/value_codec.dart';
import '../encryption/encryption_provider.dart';
import '../engine/kvstore/kv_store.dart';
import '../engine/kvstore/meta_store.dart';
import '../engine/util/hlc.dart';
import '../query/write_augmentor.dart';
import 'version_config.dart';
import 'version_entry.dart';

/// System namespace prefix for all document version entries.
///
/// Version history for a document in collection `tasks` lives under the
/// namespace `$ver:tasks`. The `$ver:` prefix is registered in the
/// `ReclamationPolicyRegistry` so that `VersionRetentionPolicy` (with its
/// `filterGroup` method) is applied during compaction.
const String kVersionNamespacePrefix = r'$ver:';

/// Returns the `$ver:` namespace name for [userNamespace].
///
/// Example: `versionNamespace('tasks')` → `'$ver:tasks'`.
String versionNamespace(String userNamespace) =>
    '$kVersionNamespacePrefix$userNamespace';

// ── VersionConfigStore ────────────────────────────────────────────────────────

/// Manages per-collection [VersionConfig] persistence and read-back.
///
/// [VersionConfigStore] reads and writes versioning configuration for each
/// collection to the `$meta` namespace. Because `$meta` syncs, the config is
/// consistent across all devices automatically.
///
/// ## Key naming
///
/// Config entries use the symbolic key `version:config:{collection}` in
/// `$meta`, resolved through the standard [MetaStore.getRawByName] /
/// [MetaStore.putRawByName] helpers.
///
/// ## Encryption
///
/// `VersionConfig` values travel through [ValueCodec] and are therefore
/// encrypted when the database is encrypted. This is consistent with the Phase
/// 12 decision to encrypt every `ValueCodec` call site uniformly.
final class VersionConfigStore {
  /// Creates a [VersionConfigStore] backed by [meta].
  const VersionConfigStore(this._meta);

  final MetaStore _meta;

  static String _configKey(String collection) => 'version:config:$collection';

  /// Returns the [VersionConfig] for [collection], or the
  /// [VersionConfig.defaults] if no config has been written.
  ///
  /// [encryption] must match the provider used when [put] was called.
  Future<VersionConfig> get(
    String collection, {
    EncryptionProvider? encryption,
  }) async {
    final bytes = await _meta.getRawByName(_configKey(collection));
    if (bytes == null) return VersionConfig.defaults;
    try {
      final map = await ValueCodec.decode(bytes, encryption: encryption);
      return VersionConfig.fromMap(map);
    } catch (_) {
      // Defensive: corrupt or unrecognised bytes → defaults rather than crash.
      return VersionConfig.defaults;
    }
  }

  /// Persists [config] for [collection] in `$meta`.
  Future<void> put(
    String collection,
    VersionConfig config, {
    EncryptionProvider? encryption,
  }) async {
    final bytes = await ValueCodec.encode(
      config.toMap(),
      encryption: encryption,
    );
    await _meta.putRawByName(_configKey(collection), bytes);
  }
}

// ── VersionWriteAugmentor ─────────────────────────────────────────────────────

/// Intercepts document writes to emit a companion `$ver:` entry in the same
/// [WriteBatch].
///
/// Registered as a [WriteAugmentor] in [KmdbDatabase]. On every document write
/// or delete it:
/// 1. Checks if versioning is enabled for the collection.
/// 2. If enabled, appends a [VersionEntry] put to the [WriteBatch] under the
///    `$ver:{namespace}` key using the same [docKey] as the document.
///
/// ## Atomicity
///
/// The augmentor runs inside [KmdbCollection._writeDocument] and
/// [KmdbCollection._deleteDocument]. The `$ver:` entry is therefore part of
/// the **same** `WriteBatch` as the document write, index entries, and vault
/// ref mutations. H2 encodes this as one WAL frame, so a crash that prevents
/// the document write prevents the version entry and vice versa.
///
/// ## HLC in the version entry value
///
/// The [VersionEntry.hlc] field stored in the value is `Hlc(0, 0)` — a
/// placeholder, because the actual HLC assigned to the entry by the LSM engine
/// is not known at augmentor time (it is set when the batch is committed).
///
/// The authoritative HLC for each version is the one embedded in the
/// **internal key** of the `$ver:` entry. [KvStore.scanVersionHistory] extracts
/// this HLC from the internal key and surfaces it as [VersionHistoryEntry.hlc].
/// [readVersions] uses this HLC to populate [DocumentVersion.hlc]. The stored
/// [VersionEntry.hlc] field is not used for ordering or promotion lookup —
/// only for future compatibility if the entry is read standalone.
///
/// ## Delete-versions
///
/// When [newDoc] is `null` (a delete), the augmentor writes a `$ver:` entry
/// with [VersionEntry.isDelete] == `true` and [VersionEntry.encodedValue] ==
/// `null`. The document reads as absent (from the main-namespace tombstone),
/// but its history stays promotable until trimmed.
///
/// ## Disabled versioning
///
/// When [VersionConfig.isDisabled] is true for the collection, no `$ver:`
/// entry is appended.
///
/// ## Encryption
///
/// When [encryption] is non-null, the `$ver:` entry bytes are encrypted using
/// the same provider as all other `ValueCodec` call sites, so version history
/// is protected by the database DEK.
final class VersionWriteAugmentor implements WriteAugmentor {
  /// Creates a [VersionWriteAugmentor].
  const VersionWriteAugmentor({required this.configs, this.encryption});

  /// Per-collection versioning configuration, keyed by user namespace.
  ///
  /// If a namespace is absent, [VersionConfig.defaults] applies.
  final Map<String, VersionConfig> configs;

  /// Optional encryption provider. When non-null, `$ver:` entries are
  /// encrypted with AES-256-GCM before being written to the KV store.
  final EncryptionProvider? encryption;

  @override
  Future<void> interceptWrite({
    required WriteBatch batch,
    required String namespace,
    required String docKey,
    required Map<String, dynamic>? newDoc,
    required Map<String, dynamic>? oldDoc,
  }) async {
    final config = configs[namespace] ?? VersionConfig.defaults;
    if (config.isDisabled) return;

    final isDelete = newDoc == null;
    // Store the encoded value for puts; null for deletes. The encoding is
    // identical to what the main namespace stores — decoding is symmetric.
    final encodedValue = isDelete
        ? null
        : await ValueCodec.encode(newDoc, encryption: encryption);

    // Store Hlc(0,0) as the placeholder — the real HLC is the internal key's HLC,
    // surfaced via scanVersionHistory(). See class doc for the rationale.
    final entry = VersionEntry(
      hlc: const Hlc(0, 0),
      encodedValue: encodedValue,
      isDelete: isDelete,
    );
    batch.put(
      versionNamespace(namespace),
      docKey,
      await entry.encode(encryption: encryption),
    );
  }
}

// ── readVersions ──────────────────────────────────────────────────────────────

/// Reads all version history entries for [docKey] in [namespace] from [store].
///
/// Returns [DocumentVersion] objects sorted by HLC **descending** (newest
/// first). The HLC for each version is taken from the internal key (via
/// [KvStore.scanVersionHistory]) — not from the stored [VersionEntry.hlc]
/// placeholder, which is always `Hlc(0, 0)`.
///
/// [namespace] must be a user namespace (e.g. `'tasks'`). This function
/// reads from the corresponding `$ver:tasks` namespace automatically.
///
/// [encryption] must match the provider used when the entries were written, or
/// `null` for plaintext values.
///
/// Returns an empty list if no version entries exist for the key (e.g.
/// versioning was disabled when the document was created, or the document
/// has never been written).
Future<List<DocumentVersion>> readVersions(
  KvStore store,
  String namespace,
  String docKey, {
  EncryptionProvider? encryption,
}) async {
  final verNs = versionNamespace(namespace);
  final entries = <DocumentVersion>[];

  await for (final histEntry in store.scanVersionHistory(verNs, docKey)) {
    try {
      // Use the hlc from the internal key (authoritative) — not from the
      // stored VersionEntry.hlc placeholder.
      final hlc = histEntry.hlc;

      // Decode the VersionEntry to access isDelete, encodedValue, and
      // promotedFrom. We cannot rely on histEntry.isDelete (the LSM record
      // type) because $ver: entries are always stored as puts; the actual
      // delete flag lives in the VersionEntry payload.
      VersionEntry? ve;
      if (histEntry.value.isNotEmpty) {
        try {
          ve = await VersionEntry.decode(
            histEntry.value,
            encryption: encryption,
          );
        } catch (_) {
          // Skip undecodable entries rather than crashing.
          continue;
        }
      }

      final isDelete = ve?.isDelete ?? false;

      Map<String, dynamic>? decodedValue;
      if (!isDelete && ve?.encodedValue != null) {
        decodedValue = await ValueCodec.decode(
          ve!.encodedValue!,
          encryption: encryption,
        );
      }

      entries.add(
        DocumentVersion(
          id: docKey,
          hlc: hlc,
          timestamp: DateTime.fromMillisecondsSinceEpoch(hlc.physicalMs),
          value: decodedValue,
          isDelete: isDelete,
          promotedFrom: ve?.promotedFrom,
        ),
      );
    } catch (_) {
      // Skip malformed entries rather than crashing.
      continue;
    }
  }

  // Sort HLC descending (newest first).
  entries.sort((a, b) => b.hlc.compareTo(a.hlc));
  return entries;
}

/// Reads the version entry for [docKey] at the given [hlc] from [store].
///
/// Returns the [VersionEntry] bytes if found, or `null` if no entry exists
/// for that exact HLC. Used by [KmdbCollection.promoteVersion] to retrieve
/// a specific historical version.
///
/// [encryption] must match the provider used when the entries were written.
///
/// Scans `$ver:{namespace}` for entries whose internal-key HLC matches [hlc].
/// Because each write in a batch gets a unique HLC (logical counter
/// incremented per entry), and both the document and the `$ver:` entry are in
/// the same batch, the `$ver:` HLC differs from the document's HLC by exactly
/// one logical tick. Callers should use the HLC returned by [readVersions]
/// (from the internal key) as the [hlc] argument.
Future<VersionEntry?> readVersionAt(
  KvStore store,
  String namespace,
  String docKey,
  Hlc hlc, {
  EncryptionProvider? encryption,
}) async {
  final verNs = versionNamespace(namespace);
  await for (final histEntry in store.scanVersionHistory(verNs, docKey)) {
    if (histEntry.hlc == hlc) {
      try {
        return await VersionEntry.decode(
          histEntry.value,
          encryption: encryption,
        );
      } catch (_) {
        return null;
      }
    }
    // HLCs are ascending; stop once we've passed the target.
    if (histEntry.hlc.compareTo(hlc) > 0) break;
  }
  return null;
}
