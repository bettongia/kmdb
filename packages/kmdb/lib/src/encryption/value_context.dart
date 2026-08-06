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

/// @docImport 'encryption_envelope.dart';
/// @docImport 'encryption_provider.dart';
/// @docImport '../encoding/value_codec.dart';
/// @docImport '../engine/kvstore/meta_store.dart';
/// @docImport '../vault/vault_store.dart';
/// @docImport '../vault/search/vault_search_manager.dart';
/// @docImport '../vault/search/vault_bm25_writer.dart';
/// @docImport '../engine/platform/storage_adapter_interface.dart';
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

/// Identifies *where* an encrypted (or to-be-encrypted) value lives, so it can
/// be bound into the AES-GCM associated data (AAD) via [toAad].
///
/// ## Why this exists (0.10.01 WI-3 / finding E-2)
///
/// Before this type, [AesGcmEncryptionProvider] encrypted with no associated
/// data at all: a ciphertext authenticated only *itself*, never *where it
/// belonged*. An adversary who can write SSTables could relocate a valid
/// encrypted value from document A to document B — it would decrypt cleanly
/// and the GCM tag would verify, because the tag never covered the key.
///
/// [ValueContext] fixes this by making the *real* KvStore `(namespace, key)` —
/// the coordinates the value is actually stored under — part of the encrypted
/// payload's associated data. Because the write site and the read site always
/// address the same KvStore entry, the AAD matches automatically: neither side
/// has to reconstruct anything, and there is no way to drift.
///
/// ## Scope: location, not freshness
///
/// The AAD binds **where** a value belongs (namespace + key), not **when** it
/// was written (HLC / version). This is a deliberate, resolved scope decision
/// (see `docs/plans/completed/plan_0_10_01_value_aad.md`'s "Resolved scope
/// decision" section), not an oversight:
///
/// - The authoritative write-HLC is assigned by the LSM engine at commit
///   time, strictly *below* the query-layer encryption call — it is not
///   available yet when [toAad] would need it. Binding it is a layering
///   impossibility, not a cost trade-off.
/// - `recordType` (e.g. "this is a live document" vs "this is a `$ver:`
///   history entry") is *not* a separate field either — the real storage
///   namespace (`{ns}` vs `$ver:{ns}`) already encodes that distinction, so a
///   redundant `recordType` field would add nothing.
///
/// Consequently, this AAD **fixes relocation and cross-namespace transplant**
/// (a ciphertext moved to a different key or namespace now fails GCM
/// authentication) but does **not** detect **rollback/replay** — re-placing an
/// *older* ciphertext of the *same* document back at the *same* key with a
/// newer HLC authenticates just fine, because ns+key are unchanged. Rollback
/// detection requires binding freshness, which is only reachable at a layer
/// that authenticates the writer and carries monotonic device state — that is
/// out of scope here and deferred to WI-4 (sync authentication).
///
/// ## KvStore-backed values
///
/// For any value that is a real KvStore `(namespace, key)` entry — collection
/// documents, `$ver:` history entries, `$$fts:`/`$$vec:` index entries, vault
/// ref-count entries, and so on — construct a [ValueContext] directly with the
/// namespace and key the value is actually stored under:
/// ```dart
/// final context = ValueContext(namespace, docKey);
/// ```
///
/// ## Non-KvStore values
///
/// A handful of encrypted-at-rest values are **not** KvStore entries at all —
/// whole files written by a [StorageAdapter] (vault blobs, `extract/`
/// artifacts) or a field inside such a file (the vault manifest's
/// `originalName`). For these, "the real KvStore namespace and key" does not
/// exist, so each gets a named constructor that single-sources one fixed,
/// AAD-only namespace literal. These literals are *not* real KvStore
/// namespaces — they exist purely to give these values a stable, collision-
/// free AAD domain:
///
/// - [ValueContext.vaultBlob] — vault blob bytes, keyed by SHA-256 address.
/// - [ValueContext.vaultExtract] — `extract/` artifact files, keyed by path.
/// - [ValueContext.vaultManifestName] — the vault manifest's `originalName`
///   field, keyed by SHA-256 address. **Deliberately a distinct literal from
///   [ValueContext.vaultBlob]** — reusing the blob literal would make the
///   manifest-name AAD byte-identical to the blob-bytes AAD for the same
///   SHA-256, permitting the two ciphertexts to be swapped (an AAD collision
///   that would defeat the whole point of binding).
/// - [ValueContext.meta] — `$meta` raw-by-name entries and the local-only
///   `$$…state` state stores' symbolic names. `$meta` *is* a real KvStore
///   namespace, but this constructor exists for call-site readability at the
///   many `MetaStore` sites that only have the symbolic name in scope, not a
///   literal namespace string.
/// - [ValueContext.vaultCorpus] — pure sugar, not a new literal: it just
///   forwards to the base constructor so a corpus-sentinel call site reads
///   self-documenting rather than passing two positional strings.
final class ValueContext {
  /// Creates a [ValueContext] for a real KvStore `(namespace, key)` entry.
  ///
  /// Use this directly for collection documents, `$ver:` history entries,
  /// `$$fts:`/`$$vec:`/`$$index:` entries, and any other value that is
  /// actually stored at `(namespace, key)` in the KvStore.
  const ValueContext(this.namespace, this.key);

  /// Named constructor for `$meta` raw-by-name entries and `$$…state` store
  /// symbolic names (generation counters, the dirty-open flag, the tombstone
  /// GC floor, the namespace registry, schema/index definitions).
  ///
  /// [MetaStore.getRawByName]/[MetaStore.putRawByName] (and the sibling
  /// `$$genstate`/`$$dirtystate`/`$$gcstate`/`$$indexstate` helpers) always
  /// have the symbolic [name] in scope, so binding it directly — rather than
  /// the internal XXH64-hashed physical key — is both simpler and sufficient:
  /// the AAD only needs to be a symmetric, collision-free logical identifier
  /// for the entry, not a byte-for-byte mirror of what lands on disk.
  ///
  /// Uses the `$meta` namespace literal, mirrored from [MetaStore.kNamespace]
  /// rather than imported from it — `meta_store.dart` already imports
  /// [EncryptionEnvelope]/[EncryptionProvider], both of which need to depend
  /// on this file for their new `context` parameter, so importing
  /// `meta_store.dart` here would create an import cycle. `$meta` is one of
  /// KMDB's three original system namespace prefixes and is exceptionally
  /// unlikely to change; `value_context_test.dart` asserts the two literals
  /// stay identical.
  const ValueContext.meta(String name) : this(_kMetaNamespaceLiteral, name);

  /// Named constructor for vault blob bytes, keyed by their SHA-256 content
  /// address.
  ///
  /// Vault blobs are content-addressed and deduplicated across many
  /// documents/namespaces, so no single document key "owns" a blob — the
  /// SHA-256 is the only stable identifier available at both the write
  /// ([VaultStore.ingest]) and read ([VaultStore.getBytes],
  /// `LocalDirectoryVaultAdapter.hydrateVaultBlob`) sites.
  ///
  /// This binding is defense-in-depth alongside the content→address check
  /// vault reads already perform after decryption: this AAD authenticates
  /// *before* decrypt (a relocated ciphertext fails GCM auth outright); the
  /// post-decrypt SHA-256 check verifies content integrity independently.
  /// Both are intended to run.
  const ValueContext.vaultBlob(String sha256)
    : this(_kVaultBlobNamespaceLiteral, sha256);

  /// Named constructor for `extract/` artifact files (`text.txt`,
  /// `chunks_v1.json`, `vectors_{modelId}_sq8.bin`), keyed by their path.
  ///
  /// `path` is the stable identifier already passed to both
  /// `VaultSearchManager.writeExtractArtifact` and `.readExtractArtifact` — no
  /// new parameter is needed at those call sites. These artifacts are
  /// local-only and fully regenerable from the vault blob, but are bound
  /// anyway to keep the invariant uniform across every encrypted-at-rest
  /// value; the cost of doing so is nil.
  const ValueContext.vaultExtract(String path)
    : this(_kVaultExtractNamespaceLiteral, path);

  /// Named constructor for the vault manifest's `originalName` field, keyed by
  /// SHA-256 address.
  ///
  /// **Uses its own fixed namespace literal, distinct from
  /// [ValueContext.vaultBlob].** The manifest's `originalName` field and the
  /// blob's bytes are two different encrypted values that happen to share a
  /// SHA-256 address; if this constructor reused [ValueContext.vaultBlob]'s
  /// literal, the two AADs would be byte-identical for the same SHA-256,
  /// letting an attacker swap the two ciphertexts (an AAD collision that would
  /// defeat the binding). A distinct literal makes the two domains
  /// non-interchangeable no matter what SHA-256 they share.
  const ValueContext.vaultManifestName(String sha256)
    : this(_kVaultManifestNameNamespaceLiteral, sha256);

  /// Named constructor for the vault search corpus-sentinel entry, matching
  /// the real KvStore `(namespace, key)` the writer and reader already share.
  ///
  /// This is pure sugar over the base constructor — **not** a new namespace
  /// literal. The corpus sentinel *is* a real KvStore entry: its namespace
  /// (`VaultBm25Writer.corpusNamespace(sha256)`) and key
  /// (`kVaultCorpusSentinelKey`) are already single-sourced shared helpers, so
  /// callers compute them exactly as they do today and simply pass the result
  /// through this constructor for a self-documenting call site.
  const ValueContext.vaultCorpus(String namespace, String key)
    : this(namespace, key);

  /// The real KvStore namespace this value is stored under, or a fixed
  /// AAD-only literal for a non-KvStore value (see the named constructors).
  final String namespace;

  /// The real KvStore key this value is stored under, or a stable identifier
  /// (SHA-256 address, file path, symbolic name) for a non-KvStore value.
  final String key;

  /// The `0x01` domain/version byte prepended to every [toAad] output.
  ///
  /// Cheap insurance so that a future change to the AAD composition cannot be
  /// silently confused with the current one — an old build reading a future
  /// AAD format (or vice versa) fails authentication instead of miscomparing.
  static const int _kDomainByte = 0x01;

  /// Mirror of [MetaStore.kNamespace] — see [ValueContext.meta]'s doc comment
  /// for why this is duplicated rather than imported.
  static const String _kMetaNamespaceLiteral = r'$meta';

  /// Fixed AAD-only namespace literal for vault blob bytes (never a real
  /// KvStore namespace — vault blobs are adapter files, not KvStore entries).
  static const String _kVaultBlobNamespaceLiteral = r'$$vault:aad:blob';

  /// Fixed AAD-only namespace literal for `extract/` artifact files.
  ///
  /// Deliberately distinct from the real KvStore namespace
  /// `$$vault:extract:{sha256}` (extraction *status*, a genuine KvStore
  /// entry) — this literal is for the `extract/` *files on disk* (extracted
  /// text, chunk metadata, vectors), which are a different value class
  /// entirely.
  static const String _kVaultExtractNamespaceLiteral = r'$$vault:aad:extract';

  /// Fixed AAD-only namespace literal for the vault manifest's `originalName`
  /// field. Distinct from [_kVaultBlobNamespaceLiteral] — see
  /// [ValueContext.vaultManifestName]'s doc comment.
  static const String _kVaultManifestNameNamespaceLiteral =
      r'$$vault:aad:manifest-name';

  /// Composes the associated data for this context:
  /// `domainByte(0x01) ‖ lenPrefixed(namespace) ‖ lenPrefixed(key)`.
  ///
  /// Both `namespace` and `key` are UTF-8 encoded and each prefixed with its
  /// own big-endian 4-byte length (mirroring the length-prefix style already
  /// used for WAL records and Manifest entries elsewhere in the engine).
  /// Length-prefixing — rather than concatenating the two strings directly —
  /// is essential: without it, `("ab", "c")` and `("a", "bc")` would produce
  /// the same AAD bytes, letting a value bound to one (namespace, key) pair
  /// authenticate under a different, colliding pair.
  Uint8List toAad() {
    final nsBytes = utf8.encode(namespace);
    final keyBytes = utf8.encode(key);
    final out = Uint8List(1 + 4 + nsBytes.length + 4 + keyBytes.length);
    final bd = ByteData.sublistView(out);
    var offset = 0;

    out[offset] = _kDomainByte;
    offset += 1;

    bd.setUint32(offset, nsBytes.length, Endian.big);
    offset += 4;
    out.setAll(offset, nsBytes);
    offset += nsBytes.length;

    bd.setUint32(offset, keyBytes.length, Endian.big);
    offset += 4;
    out.setAll(offset, keyBytes);

    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is ValueContext && namespace == other.namespace && key == other.key;

  @override
  int get hashCode => Object.hash(namespace, key);

  @override
  String toString() => 'ValueContext(namespace: $namespace, key: $key)';
}
