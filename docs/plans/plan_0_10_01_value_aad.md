# Bind encrypted values to their context with AES-GCM associated data (E-2)

**Status**: Implementing

**PR link**: https://github.com/bettongia/kmdb/pull/68

> **Provenance.** Finding **E-2** of the
> [2026-07-18 release-readiness review](../reviews/release-readiness-review-2026-07-18.md),
> under the [0.10.01 hardening track](../roadmap/0_10_01.md). Split out of
> `plan_0_10_01_sync_trust_boundary.md` on 2026-07-19 (Q-E) because it depends
> on **neither** the secret store nor the sync authenticator — it uses the
> existing DEK — and is the breaking format change that most wants to land
> early.

## Problem statement

`AesGcmEncryptionProvider` encrypts with a fresh random 96-bit nonce and **no
associated data**. A search of `packages/kmdb/lib/src/encryption` for `aad`,
`associatedData`, or `additionalAuthenticatedData` returns nothing.

A ciphertext therefore authenticates only *itself*, never *where it belongs*.
Nothing cryptographically binds an encrypted value to its document key,
namespace, collection, or version. An adversary who can write SSTables — and
S-1 confirmed crafting them is practical — can:

- **Relocate** a valid encrypted value from document A to document B. It
  decrypts cleanly and the GCM tag verifies, because the tag never covered the
  key.
- **Roll back** a document by re-placing an older ciphertext at the same key
  with a newer HLC — a replay that authentication cannot detect.
- **Transplant** values across namespaces or collections.

In each case the victim sees correctly-decrypting, apparently-authentic data the
owner never wrote there.

## Why now rather than later

**This will never be cheaper.** `0.1.0` freezes the on-disk format. Adding AAD
afterwards requires a migration; adding it now requires only a version bump,
because KMDB has never been released and no user holds a compatibility
expectation.

It is also worth doing **even if the threat model were narrowed** to a passive
adversary: context-bound ciphertext preserves the option to strengthen the model
later without a second format break.

## Open questions

- [x] **How does AAD reach `ValueCodec`?** (review R-7 / Q-D)
      → **A required `ValueContext` parameter.** `encode`/`decode` already accept
      an optional named `encryption:`, so the shape is identical — but the
      context must be **required**. An optional parameter that is omitted
      silently produces unbound ciphertext, which is precisely the bug being
      fixed. Required means the compiler enumerates every call site.
- [x] **What exactly goes into the AAD for each value class?**
      → **`AAD = domainByte(0x01) ‖ lenPrefixed(namespace) ‖ lenPrefixed(key)`**,
      using the **real KV storage namespace and key**. The storage namespace
      already encodes the record class (`tasks` vs `$ver:tasks` vs `$meta` vs
      `$$fts:…`), so a separate `recordType` field is **redundant and dropped**.
      Length-prefix the fields so `("ab","c")` and `("a","bc")` cannot collide.
      See the corrected value-class table below.
- [x] **Does the AAD need a version/domain-separation prefix?**
      → **Yes — a single leading `0x01` domain byte.** Cheap insurance so a
      future change to the composition cannot be confused with the current one.
- [x] **`$ver:` entries — bind the HLC or the logical key?**
      → **Bind `ns + key` only, no HLC.** The architect grounding
      (2026-08-05) showed this is **not** a replay-vs-cost trade-off:
      (a) there is no verbatim-ciphertext move anywhere — every write and every
      `promote` decodes and re-encrypts from scratch
      (`version_manager.dart:174-188`, `kmdb_collection.dart:428/870`), so binding
      more context costs nothing; and (b) the authoritative write-HLC is
      **not available at encrypt time** — it is assigned by the LSM engine at
      commit, *below* the query-layer encryption, and the stored
      `VersionEntry.hlc` is a `Hlc(0,0)` placeholder (`version_entry.dart:66-68`).
      Binding the HLC is therefore a layering impossibility, not a cost.

### Open questions raised by review (2026-08-05) — RESOLVED (maintainer, 2026-08-06)

The four questions above are correctly resolved for **KvStore-backed values**, where
the plan's central insight holds beautifully: if the AAD is *always* the actual
`(namespace, key)` the bytes are stored under, symmetry between the write site and
the read site is **automatic** — both hit the same KvStore entry at the same
coordinates, so neither has to reconstruct anything. That is verified sound.

The gap is the class of encrypted-at-rest data that is **not** a KvStore
`(namespace, key)` entry at all, for which "the real KV storage namespace and key"
does not exist. These need explicit AAD definitions or the implementer will invent
namespace literals — and a write/read mismatch produces a *silent* GCM
authentication failure on every encrypted vault read (indistinguishable from
tampering), which is exactly the failure class this plan exists to surface loudly.

All four resolved by the maintainer (2026-08-06). The unifying mechanism: give
`ValueContext` **named constructors** so each non-KvStore literal lives in exactly
one place and cannot diverge between the write site and the read site (the silent
GCM-auth-failure risk these questions guard against).

- [x] **Q-R1 — AAD for vault blobs.** → **Bind, keyed on the SHA-256 address.**
      Maintainer chose to bind all encrypted-at-rest data uniformly. Use a named
      constructor `ValueContext.vaultBlob(sha256)` composing
      `domainByte ‖ lenPrefixed(<one fixed vault-blob namespace literal>) ‖
      lenPrefixed(sha256Hex)`, applied **identically** at the write
      (`vault_store.dart:252`) and both reads (`VaultStore.getBytes`,
      `LocalDirectoryVaultAdapter.hydrateVaultBlob`,
      `local_directory_vault_adapter.dart:239`). The `(or docKey)` either/or is
      **dropped** — the SHA-256 is the stable identifier (blobs are content-
      addressed and deduped across many docs/namespaces, so no single docKey
      owns a blob). This is **defense-in-depth** alongside S-4's post-decrypt
      content→address check (`vault_store.dart:240`): AAD authenticates *before*
      decrypt, S-4 verifies *after*. Both is intended.
- [x] **Q-R2 — AAD for `extract/` artifacts.** → **Bind, keyed on the `path`
      string.** Named constructor `ValueContext.vaultExtract(path)` composing
      `domainByte ‖ lenPrefixed(<one fixed extract-artifact namespace literal>) ‖
      lenPrefixed(path)`. `path` is the stable identifier already passed to both
      `writeExtractArtifact(path, …)` (`vault_search_manager.dart:224`) and
      `readExtractArtifact(path)` (`:257`) — no new parameter needed. Local-only
      and regenerable, but bound anyway to keep the invariant uniform (cost is
      nil, same rationale as `$$fts:`/`$$vec:`).
- [x] **Q-R3 — vault search index-value / corpus-sentinel reads.** → **Thread it.**
      `VaultSearchManager.unwrapIndexValue(bytes)`
      (`vault_search_manager.dart:189`) grows a `ValueContext` parameter; callers
      (`vault_searcher.dart:333/364/490`) supply the `(ns, key)` they already hold
      from the scan cursor. The corpus-sentinel read (`:333`) must bind the same
      sentinel key the writer uses (`:1117`) — a named `ValueContext.vaultCorpus(…)`
      keeps that sentinel literal single-sourced. Not a design fork; called out so
      the implementer supplies matching context rather than the wrong coordinates.
- [x] **Q-R4 — DEK-wrap envelope.** → **Intentionally OUT of scope.** The DEK wrap
      in `key_derivation.dart` (`:135/:177`) uses `AesGcm` directly and stays that
      way: the wrapped DEK is keyed by the passphrase/recovery KEK, and it is not
      relocatable in a way that makes a victim decrypt *authentic-looking* data
      (a wrong KEK simply fails). §31 (Phase 5) must state this explicitly so its
      absence is not read as an oversight.

### Open question raised by review round 2 (2026-08-06) — RESOLVED (maintainer, 2026-08-06)

**Resolution:** BIND, via a **distinct fifth named constructor
`ValueContext.vaultManifestName(sha256)`** with its **own** fixed namespace
literal (NOT reusing the `vaultBlob` literal). Rationale: the maintainer's Q-R1
principle already puts this encrypted-at-rest field in scope; the only judgment
was *which* context, and reusing `vaultBlob(sha256)` would make the manifest-name
AAD byte-identical to the blob-bytes AAD for the same `sha256` — an AAD collision
that permits swapping the two ciphertexts, defeating the binding. Domain
separation therefore requires its own literal. Apply it identically at the write
(`vault_store.dart:299`) and read (`VaultStore.getManifest`, `:409`); add a
value-class table row and a Phase 4 relocation test (serve a valid `originalName`
ciphertext under a different `sha256`'s manifest → assert GCM auth failure). This
resolution is forced by the established principle plus a cryptographic
correctness constraint; it introduces no new design fork.

- [x] **Q-R5 — AAD for the vault-manifest `originalName` field.** The 0.08
      confidentiality reconciliation encrypts the blob's `originalName` inside
      `manifest.json` via `EncryptionEnvelope.wrap` at the write
      (`vault_store.dart:299`) and `EncryptionEnvelope.unwrap` at the read
      (`VaultStore.getManifest`, `vault_store.dart:409`). This is a **fifth**
      vault `EncryptionEnvelope` site (verified: the only wrap/unwrap sites in
      `lib/src/vault/` are blob write `:252`, blob read `:369`, blob hydrate read
      `local_directory_vault_adapter.dart:239`, extract write/read `:224/:257`,
      the generic writer wrap `:1117`, `unwrapIndexValue` `:190`, and **these two**
      — `:299/:409`). It is a **non-KvStore adapter artifact** (a field inside a
      `manifest.json` file written under `hashDir(sha256)`), so "the real KV
      (namespace, key)" does not exist for it, and **none of the Q-R1–Q-R4 named
      constructors currently cover it**. The plan text does not mention `manifest`,
      `originalName`, or `getManifest` anywhere.

      Under the maintainer's Q-R1 principle ("bind all encrypted-at-rest data
      uniformly"), this field is in scope: an attacker who crafts `manifest.json`
      files can relocate a valid `originalName` ciphertext onto a different blob's
      manifest, and today it would decrypt and authenticate cleanly. The `sha256`
      is in scope at both sites (write: computed at Step 1 `vault_store.dart`;
      read: `getManifest(sha256)` parameter), so it is bindable — but the
      **decision the implementer must not improvise** is *which* context:
      - Reusing `ValueContext.vaultBlob(sha256)` makes the manifest-name AAD
        **identical** to the blob-bytes AAD for the same `sha256` — they share the
        one fixed vault-blob namespace literal + `sha256`. That is a (narrow)
        transplant vector within a single `sha256` and defeats the point of
        binding, so it is probably wrong.
      - The likely-correct answer is a **fifth named constructor**
        (e.g. `ValueContext.vaultManifestName(sha256)`) with its own fixed
        namespace literal, single-sourced across `:299` and `:409`, plus a
        Phase 4 relocation test (serve a valid `originalName` ciphertext under a
        different `sha256`'s manifest, assert GCM auth failure) and a table row.

      A write/read mismatch here is a **silent GCM authentication failure on every
      encrypted `getManifest`** — indistinguishable from tampering — which is the
      exact failure class Q-R1–Q-R3 were resolved to eliminate. This must be a
      maintainer call, not an implementer guess.

### Resolved scope decision — AAD binds *location*, not *freshness* (maintainer, 2026-08-05)

Because the write-HLC does not exist at encrypt time (above), E-2's AAD binds an
encrypted value to **where it belongs** (namespace + key) but cannot bind **when
it was written** (HLC/version). Consequently:

- **Fixed by E-2:** relocation and transplant — moving a valid ciphertext to a
  different document key or a different namespace/collection. The GCM tag now
  covers ns+key, so a relocated ciphertext fails authentication.
- **Explicitly OUT of scope for E-2, deferred to WI-4 (sync authentication):**
  rollback / replay — re-placing an older ciphertext of the *same* document at
  the *same* key with a newer HLC, and intra-key `$ver:` version reordering.
  These require binding *freshness*, which is only reachable at the layer that
  authenticates the writer and can carry monotonic device state. §31 must state
  this boundary honestly (Phase 5).

## Investigation

### Current shape

```dart
static Future<Uint8List> encode(Map<String, dynamic> value, {
  EncryptionProvider? encryption,
}) async
static Future<Map<String, dynamic>> decode(Uint8List bytes, {
  EncryptionProvider? encryption,
}) async
```
(`lib/src/encoding/value_codec.dart:92`, `:140`)

The raw grep for `ValueCodec.encode|decode` in `lib/` returns **~51**, but ~9 of
those are doc-comment references (`compression_flag.dart:23-24`,
`value_codec.dart:309`, `version_entry.dart:74/95`, `kmdb_database.dart:353/588`,
`write_augmentor.dart:38`, `vault_ref_count.dart:75-76`), so the **real call
sites are ~40**. The important ones are in the collection layer (enumerated in
the value-class table above: `kmdb_collection.dart:125/238/275/301/408/436/578/870/963`),
where the namespace and document key are already in scope, so threading is
mechanical rather than architectural. Note the separate ~45 `EncryptionEnvelope`
`wrap`/`unwrap` sites and the `EncryptionProvider` interface change are additional
surfaces (see below).

### Value classes needing an AAD definition

Not every value has a natural document key. Each of these needs an explicit
decision, and the plan should not let an implementer improvise:

Corrected against the code by the architect grounding (2026-08-05). The AAD is
always `domainByte ‖ lenPrefixed(realStorageNamespace) ‖ lenPrefixed(key)`; the
"context" column below is just *what those two fields resolve to* for each class.

| Class | Storage namespace | Key bound | Notes |
| :--- | :--- | :--- | :--- |
| Collection documents | `{userNs}` | document key | `recordType` dropped — namespace already distinguishes. Sites: `kmdb_collection.dart:125/238/275/301/408/436/578/870/963`, `kmdb_query.dart:415/511`. |
| `$ver:` history entries | `$ver:{userNs}` | document key | Bind ns+key, **no HLC** (see open questions). The `$ver:` namespace already differs from the live `{userNs}`, so a version ciphertext cannot be transplanted into the live slot. Sites: `version_manager.dart:188`, `kmdb_collection.dart:428/900`. |
| `$meta` raw-by-name + all `$$…state` | `$meta` / `$$genstate` / `$$dirtystate` / `$$gcstate` / `$$indexstate` | the symbolic **name** (`gen:{ns}`, `dirty`, `gc:tombstoneFloor`, `namespaces`, `schema:{coll}`, `schema:__registry__`, index defs) | One `ValueContext.meta(name)` covers all of these — the name is in scope at every `MetaStore` `getRawByName`/`putRawByName` and the state helpers. Broader than "$meta scalars"; schema + registry + index-state all funnel here. |
| `version:config` | `$meta` | config name | **Double-encrypted** — `VersionConfigStore.put` calls `ValueCodec.encode(…, encryption)` *then* `meta.putRawByName` → `EncryptionEnvelope.wrap`. **Both** layers need a `ValueContext`. The one value that hits both primitives. |
| Vault blobs (adapter files) | fixed literal via `ValueContext.vaultBlob` | **SHA-256 address** | Not KvStore entries — see Q-R1. `(or docKey)` dropped: blobs are content-addressed/deduped, no docKey owns one. Defense-in-depth alongside S-4. Sites: `vault_store.dart:252`, `VaultStore.getBytes`, `local_directory_vault_adapter.dart:239`. |
| `extract/` artifacts (adapter files) | fixed literal via `ValueContext.vaultExtract` | **path** | Not KvStore entries; local-only/regenerable — see Q-R2. Sites: `vault_search_manager.dart:224/257`. |
| Vault-manifest `originalName` (field in `manifest.json`) | fixed literal via `ValueContext.vaultManifestName` (**distinct** from `vaultBlob`) | **SHA-256 address** | Not a KvStore entry — see Q-R5. Own literal to avoid AAD collision with blob bytes. Sites: `vault_store.dart:299` (write), `:409` (getManifest read). |
| Vault ref / KvStore-keyed vault entries | vault KvStore namespace | ref key / sha256 | Sites: `vault_ref_interceptor.dart:164/198/326/355`, `vault_ref_count.dart:136`. |
| Vault search index + corpus sentinel | `$$vault:fts:`/`$$vault:vec:idx:` | scan-cursor `(ns,key)` / sentinel via `ValueContext.vaultCorpus` | Q-R3: `unwrapIndexValue` grows a context param. Sites: `vault_search_manager.dart:190/1117`, `vault_searcher.dart:333/364/490`. |
| `$$fts:` / `$$vec:` | `$$fts:…` / `$$vec:…` | namespace/field/term/docId | Local-only but still bind; cost is nil. Sites: `fts_manager.dart` + `vec_manager.dart` (enumerated in grounding). |

**Value classes with NO ciphertext (no AAD — noted so their absence is not read as an oversight):**

- **`$$index:*` entries** store an **empty** `Uint8List(0)` presence key
  (`index_writer.dart:99`); confidentiality comes from the HMAC namespace-suffix
  token (`indexToken`), not value encryption. Nothing to bind.
- **`$$cache` materialised views** are **not implemented** — only a comment
  (`kv_store_impl.dart:537`). No encode/decode site exists. Nothing to bind.

### Interaction with the encryption envelope and the provider interface

Two additional surfaces beyond `ValueCodec.encode`/`decode` must be threaded —
the plan previously understated both:

1. **`EncryptionEnvelope`** (0.08 reconciliation) wraps scalar/opaque values that
   bypass `ValueCodec` (~45 `wrap`/`unwrap` sites in `lib/`, enumerated above).
   Every site has a natural namespace+key or name in scope — audited, none lack
   bindable context.
2. **`EncryptionProvider.encrypt`/`decrypt`** (`encryption_provider.dart:39/47`)
   take **no `aad` parameter today.** Threading AAD requires changing that
   interface *and* `AesGcmEncryptionProvider` (`:143/:170`) — a **fourth work
   surface** alongside `ValueCodec`, `EncryptionEnvelope`, and the call-site
   fixups. `package:cryptography` 2.9.0 supports it (`Cipher.encrypt`/`decrypt`
   both accept `List<int> aad = const []`), so the change is mechanical.
   **Blast radius of the interface change (reviewer-confirmed, small):** only
   the one production `AesGcmEncryptionProvider` and two test doubles
   (`_XorProvider`, `_BadKeyProvider`, both in
   `test/encryption/value_codec_encryption_test.dart`) implement the interface;
   only four production `.encrypt`/`.decrypt` call sites exist. `key_derivation.dart`
   uses `AesGcm` directly, not the interface (Q-R4), and is untouched.

### Latent bug this work surfaces (a concrete win for the required parameter)

`vault_searcher.dart:632` calls `ValueCodec.decode(fieldPathBytes)` **without
`encryption:`**, while the writer (`vault_ref_interceptor.dart:164`) supplies it.
On an encrypted database the fieldPath decode already fails silently today
(caught → empty path). Making `ValueContext` **required** forces this call site
to be corrected.

## Implementation plan

### Phase 1 — Define the context type

- [x] `ValueContext` carrying the **real storage namespace + key** (the only two
      bound fields). For KvStore-backed values a single `ValueContext(namespace,
      key)` suffices. Provide **named constructors** for the values whose
      namespace literal is *not* a live KvStore namespace, so each literal is
      single-sourced and cannot diverge between write and read (per Q-R1–Q-R3):
      - `ValueContext.meta(name)` — maps a `$meta`/`$$…state` symbolic name to the key slot.
      - `ValueContext.vaultBlob(sha256)` — one fixed vault-blob namespace literal + SHA-256.
      - `ValueContext.vaultExtract(path)` — one fixed extract-artifact literal + path.
      - `ValueContext.vaultCorpus(...)` — the corpus-sentinel literal, matching writer/reader.
      - `ValueContext.vaultManifestName(sha256)` — one fixed manifest-name literal
        + SHA-256, **distinct** from the `vaultBlob` literal (Q-R5) so the
        manifest-`originalName` AAD cannot collide with the blob-bytes AAD.
      Implemented in `lib/src/encryption/value_context.dart`. `vaultCorpus` ended
      up a literal redirecting constructor (`this(namespace, key)`) rather than
      taking a sha256 — see the deviation note below.
- [x] A canonical, unambiguous byte encoding — `domainByte(0x01) ‖
      lenPrefixed(namespace) ‖ lenPrefixed(key)`; length-prefixed, not
      concatenated, so `("ab", "c")` and `("a", "bc")` cannot collide.
      Implemented with 4-byte big-endian length prefixes (not the 1-byte
      namespace-length-prefix style used in the WAL/key-codec format) — chosen
      because AAD keys are not all subject to that 255-byte cap (e.g. extract
      artifact paths), so a wider prefix avoids introducing a new limit.
- [x] The leading `0x01` domain/version byte.
- [x] Doc comments explaining *why* ns+key are bound and why freshness is not
      (see the scope decision above).

### Phase 2 — Thread it through

- [x] Add an `aad` parameter to `EncryptionProvider.encrypt`/`decrypt`
      (`encryption_provider.dart:39/47`) and implement it in
      `AesGcmEncryptionProvider` (`:143/:170`) by passing `aad` to
      `package:cryptography`'s `AesGcm.encrypt`/`decrypt`. **This interface is
      the fourth work surface and must land before the callers can thread AAD.**
- [x] Add a **required** `ValueContext` parameter to `ValueCodec.encode`/`decode`,
      which composes the AAD (`domainByte ‖ lenPrefixed(ns) ‖ lenPrefixed(key)`)
      and forwards it to the provider.
- [x] Fix every resulting compile error — the point of making it required.
      (This also corrects the latent `vault_searcher.dart:632` omission — it was
      missing `encryption:` entirely, not just `context:`.) The compiler
      enumerated 79 sites (not ~40 + ~45 — many plan line-number hints had
      drifted, confirming the reviewer's warning to treat them as hints only).
- [x] Same for **`EncryptionEnvelope`** call sites (~45 in `lib/`). Note several
      `$$…state` reads bypass `MetaStore` and need context supplied at the call
      site directly — `$$genstate` in `cache_layer.dart`, `$$indexstate` in
      `index_manager.dart` — confirmed exactly as the reviewer described.
- [x] **`version:config` is double-encrypted** — thread a `ValueContext` through
      *both* the `ValueCodec.encode` and the `EncryptionEnvelope.wrap` in
      `VersionConfigStore.put`/get. Note: `MetaStore.getRawByName`/`putRawByName`
      themselves needed **no signature change** — they already have `name` in
      scope and build `ValueContext.meta(name)` internally, so only the
      *caller's* inner `ValueCodec` layer needed an explicit context.
- [x] **Vault blobs** — thread `ValueContext.vaultBlob(sha256)` through the
      `EncryptionEnvelope.wrap`/`unwrap` at the write (`vault_store.dart`) and
      **both** reads (`VaultStore.getBytes`,
      `LocalDirectoryVaultAdapter.hydrateVaultBlob`).
- [x] **`extract/` artifacts** — thread `ValueContext.vaultExtract(path)` through
      `writeExtractArtifact`/`readExtractArtifact` (`vault_search_manager.dart`).
- [x] **Vault-manifest `originalName`** — thread
      `ValueContext.vaultManifestName(sha256)` through the `EncryptionEnvelope.wrap`
      at `vault_store.dart` (write) and `unwrap` in `VaultStore.getManifest`.
      Distinct literal from `vaultBlob` (Q-R5).
- [x] **Vault search index reads** — grow `unwrapIndexValue(bytes)`
      (`vault_search_manager.dart`) a `ValueContext` param; callers
      (`vault_searcher.dart`) pass the scan-cursor `(ns, key)`. Bind
      the corpus-sentinel via `ValueContext.vaultCorpus(...)` matching the writer.
- [x] **Out of scope (state, don't change):** the direct-`AesGcm` DEK wrap in
      `key_derivation.dart` (Q-R4). Confirmed untouched.
- [x] **Deviation (not in the plan's census) — compaction `$ver:`-drop callback.**
      `KvStore.setVersionDropCallback`'s callback previously received only raw
      `List<Uint8List>` value bytes with no namespace/docKey — compaction-time
      drops had no other way to recover the `(namespace, docKey)` a required
      `ValueContext` now demands for `VersionEntry.decode`/
      `VaultRefInterceptor.decrementVersionRefs`. Widened to a new
      `DroppedVersionEntry` typedef (`{namespace, docKey, value}`), decoded from
      the dropped entry's internal key via `KeyCodec.decodeNamespace`/
      `decodeUserKey`/`bytesToKey` in `CompactionJob.flushGroupBuffer`, threaded
      through `LsmEngine`/`KvStoreImpl`/`CacheLayer`/`KmdbDatabase`. This is the
      "sixth encrypted site" class of surprise the task explicitly asked to be
      reported — it is a signature change, not a value-context ambiguity.

### Phase 3 — Format version

- [x] Bump **`MetaStore.kCurrentFormatVersion`** from `1` to `2` — this is the
      correct lever, **not** the per-value 1-byte `EncryptionFlag` prefix (which
      is self-describing per value and must not be repurposed).
- [x] Make `KvStoreImpl.open()` **reject** a database whose stored
      `formatVersion` marker is `< kCurrentFormatVersion` with an explicit
      diagnostic. Confirmed the reviewer's sharp edge: the existing code only
      branched on `formatVersion == null`; added a new `else if (formatVersion <
      MetaStore.kCurrentFormatVersion)` branch throwing `LegacyDatabaseFormatException`
      (extended with optional `foundVersion`/`currentVersion` fields to produce a
      distinct, specific message for this case vs. the marker-absent case). No
      migration is written (greenfield; no released databases).

### Phase 4 — Tests

- [x] **Relocation:** encrypt at key A, place the ciphertext at key B, assert
      authentication failure. This is the test that proves the fix. **Use the real
      `AesGcmEncryptionProvider`** — a toy XOR/no-op provider ignores AAD and makes
      the assertion vacuous.
      Implemented in `test/encryption/value_aad_test.dart` ("Relocation and
      cross-namespace transplant" group), plus the `EncryptionEnvelope`-layer
      variant in the same group.
- [x] **Cross-namespace transplant:** same, across namespaces.
      Implemented alongside the relocation test above (same group).
- [x] **Vault-blob relocation:** place a valid blob ciphertext at a different
      SHA-256 address, assert **GCM auth** failure — distinct from (and prior to)
      S-4's post-decrypt content→address check.
      Implemented in `test/encryption/vault_encryption_test.dart`
      ("Relocation — blob bytes and manifest originalName" group), asserting
      `EncryptionErrorCode.badCredentials` specifically (not
      `VaultContentMismatchException`).
- [x] **`extract/` artifact relocation:** rewrite an artifact under a different
      path, assert auth failure.
      Implemented in `test/vault/search/vault_search_manager_test.dart`
      ("Relocation — extract/ artifacts" group).
- [x] **Manifest-`originalName` relocation:** serve a valid `originalName`
      ciphertext under a different `sha256`'s manifest, assert **GCM auth**
      failure (Q-R5). Also assert it does *not* collide with the blob-bytes AAD
      for the same `sha256` (distinct literals).
      Implemented in `test/encryption/vault_encryption_test.dart` (same
      "Relocation" group as vault-blob, above) — includes both the
      cross-sha256 relocation test and a same-sha256 blob↔manifest-name
      AAD-collision test.
- [x] **Encrypted docref fieldPath round-trip:** on an *encrypted* DB, assert the
      `vault_searcher` fieldPath decode succeeds — the `catch(_)` there
      (`:634`-ish) would otherwise make a wrong-context regression silent.
      Implemented in `test/vault/search/vault_searcher_test.dart`
      ("encrypted extract/ artifacts" group) — asserts the fieldPath comes
      back **non-empty and correct**, not merely "no throw".
- [x] **Rollback (negative / boundary test):** replace a value with an older
      ciphertext for the **same** key and assert it **still authenticates** —
      documenting honestly that E-2's AAD does *not* detect rollback (freshness
      is not bound; deferred to WI-4). This test pins the scope boundary so a
      later reader does not mistake it for a gap.
      Implemented in `test/encryption/value_aad_test.dart` ("Scope boundary —
      AAD binds location, not freshness" group).
- [x] **`$ver:` isolation:** a `$ver:{ns}` ciphertext transplanted into the live
      `{ns}` slot at the same key fails authentication (namespace differs).
      Implemented in `test/encryption/value_aad_test.dart` (`$ver: isolation`
      group), including the reverse direction and a real `VersionEntry`
      round-trip.
- [x] **`version:config` double-encryption:** round-trips correctly with a
      `ValueContext` threaded through both layers.
      Implemented in `test/encryption/value_aad_test.dart`
      ("version:config double-encryption round-trip" group) — also asserts the
      outer `EncryptionEnvelope` layer is genuinely active (raw bytes start
      with `EncryptionFlag.aesGcm`) and that a wrong provider falls back to
      `VersionConfig.defaults` (the documented defensive posture, not a thrown
      exception).
- [x] Round-trip tests for every `ValueContext` constructor / value class.
      Implemented in `test/encryption/value_aad_test.dart` ("Round-trip per
      ValueContext constructor" group) plus unit-level composition/collision
      tests for `ValueContext` itself in the new
      `test/encryption/value_context_test.dart`.
- [x] Old-format database (`formatVersion` = 1) fails to open with the expected
      diagnostic. **Assert the new `< kCurrentFormatVersion` branch** — the
      current open logic gates only on a *null* marker and would otherwise accept
      a v1 DB.
      Implemented in `test/encryption/value_aad_test.dart` ("Old-format
      database rejection" group) — seeds a raw `formatVersion=1` marker
      (bypassing `KvStoreImpl.open`'s gate) and asserts
      `LegacyDatabaseFormatException` with `foundVersion=1`/
      `currentVersion=2`, plus a companion test that a brand-new database is
      stamped `2`.
- [x] **Fault injection (CLAUDE.md-required):** using `FaultyStorageAdapter`,
      exercise a crash on the open/recovery and `$ver:` write paths under AAD —
      the in-memory adapter is durability-blind. At minimum: crash mid-`$ver:`
      write and reopen; crash during the format-marker write and reopen.
      Implemented in `test/encryption/value_aad_test.dart` ("Fault injection
      (FaultyStorageAdapter)" group): (1) an AAD-bound live document + its
      companion `$ver:` entry survive a crash-and-WAL-replay and both
      authenticate on reopen; (2) a crash between the format-marker/`enc:blob`
      write and the first encrypted user value leaves the database safely
      reopenable under both possible crash outcomes.
- [x] **Deviation (surfaced during implementation, not in the original
      census):** the compaction `$ver:`-drop callback (`DroppedVersionEntry`)
      is exercised directly in `test/encryption/value_aad_test.dart`
      ("Compaction \$ver:-drop deviation" group) — registers a real
      `setVersionDropCallback`, forces a real all-levels compaction that trims
      `$ver:` history, and asserts the dropped entries' `(namespace, docKey)`
      are correct and decode successfully under real AES-GCM encryption via
      the reconstructed `ValueContext`, plus a wrong-context regression guard.

### Phase 5 — Spec

- [x] Update §31 (encryption) with the AAD composition
      (`domainByte ‖ lenPrefixed(ns) ‖ lenPrefixed(key)`) and its rationale.
      Added a new "Associated Data (AAD Binding)" section (with "Non-KvStore
      values" and scope-boundary subsections), updated the "Encoding Pipeline
      with Encryption" diagram, "Provider Threading", "API Reference", the
      "Database Format-Version Gate" (four-way discrimination, v1→v2), and the
      "Protected (encrypted)" list (confidentiality-vs-authenticity note).
- [x] Update §05 (value encoding) for the format version bump.
      Added a "Database Format Version" section and an AAD note in the "With
      encryption" pipeline diagram.
- [x] **State the scope boundary explicitly in §31:** AAD binds *location*
      (ns+key), not *freshness* (HLC/version). E-2 fixes relocation/transplant;
      rollback/replay and intra-key version reordering are out of scope and
      deferred to WI-4 (sync authentication). Also note AAD does not protect
      against a peer that legitimately holds the DEK.
      Covered in §31's new "Scope: location, not freshness" and "Out of
      scope: the DEK-wrap envelope" subsections.

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` — confirm >95% on all new files.
      `packages/kmdb` overall 95.1% (7381/7765), `packages/kmdb_cli` overall
      95.2% (2919/3065) — both well above the 90% CLAUDE.md floor. The new
      `value_context.dart` is 100% covered (30/30); `encryption_provider.dart`
      95.6%. (Deviation: fixing this plan's `ValueCodec`/`EncryptionEnvelope`
      required-parameter break also required threading `context:` through
      `packages/kmdb_cli` — 81 call sites across lib/ and test/, not scoped
      by the original plan/reviewer census since it only covered
      `packages/kmdb`. Also removed one genuinely dead, pre-existing
      `kmdb_cli` function, `readVaultRefCount`, which used a stale/incorrect
      key scheme and was unreachable from any call site.)
- [x] Hand off to the **`kmdb-qa` agent** for sign-off (2026-08-08) — **PASS**,
      no code changes required. Verified all seven high-risk seams: the 81
      kmdb_cli context assignments bind the same `(namespace, key)` the library
      reads under; the compaction `DroppedVersionEntry` context matches the
      `$ver:` write path; `readVaultRefCount` genuinely dead; every relocation
      test uses the real `AesGcmEncryptionProvider` and asserts `badCredentials`;
      fault-injection and the `< kCurrentFormatVersion` gate exercised.
- [x] Run `make pre_commit` — **green** (format_check, analyze 0 issues across 7
      packages, license_check, kmdb 2489 tests). Full `kmdb_cli` suite run
      separately (kmdb-only gate doesn't cover it): **1177 passed**.
- [x] Verify licence headers on all new files (2026) — confirmed present.

## Reviewer assessment (kmdb-plan-reviewer, 2026-08-05)

**Verdict: strong plan, one genuine gap → `Questions`.** The problem is real and
worth fixing now (format is about to freeze at `0.1.0`), the architecture fit is
clean, and the four originally-open questions are resolved correctly. The reason
this is not yet `Investigated` is a single, high-consequence unspecified decision
(Q-R1/Q-R2/Q-R3 above): the AAD for encrypted data that is **not** a KvStore
`(namespace, key)` entry. A wrong guess there fails silently at runtime, which is
precisely the class of bug the plan is meant to eliminate.

### What I verified holds (do not re-litigate)

- **The "bind the real KV `(namespace, key)`" design is sound and self-symmetric**
  for every KvStore-backed value. Write and read hit the same entry at the same
  coordinates, so the AAD matches by construction — no reconstruction, no drift.
  This is the plan's best idea and it is correct.
- **`recordType` is genuinely redundant.** The live doc and its `$ver:` twin store
  byte-identical `encodedValue` (`version_manager.dart:173-176`); the *only*
  distinguisher is the namespace (`tasks` vs `$ver:tasks`), which the AAD now
  binds. Confirmed.
- **HLC binding is a layering impossibility, not a cost trade-off.** Verified:
  `version_manager.dart:178-181` constructs `VersionEntry(hlc: const Hlc(0,0), …)`;
  the authoritative HLC is assigned by the LSM engine at commit, below query-layer
  encryption. Confirmed.
- **No fifth encode/decode surface below the KvStore boundary.** WAL, SSTable, and
  memtable store opaque encoded bytes; there is no `ValueCodec`/`EncryptionEnvelope`
  use in the engine internals. The four named surfaces are the right set.
- **Interface change blast radius (Q2) is tiny.** Only two implementers of
  `EncryptionProvider` exist besides `AesGcmEncryptionProvider`: `_XorProvider` and
  `_BadKeyProvider`, both in `test/encryption/value_codec_encryption_test.dart`.
  Only four production `.encrypt`/`.decrypt` call sites exist
  (`value_codec.dart:159/211`, `encryption_envelope.dart:73/109`).
  `key_derivation.dart` uses `AesGcm` directly and is untouched by the interface
  change (see Q-R4).
- **The `vault_searcher.dart:632` latent-bug fix is mechanical.** The `(ns, key)`
  is in scope right above it: `docRefNs = '$kVaultDocRefPrefix$sha256'`, key
  `docId` (`:627-628`), matching the writer at `vault_ref_interceptor.dart:161-164`.
- **The format-version lever (Phase 3) is the right one**, with one sharp edge:
  `KvStoreImpl.open()` today only branches on `formatVersion == null`
  (`kv_store_impl.dart:178-207`); a non-null marker "falls through" as *accepted*.
  Bumping to `2` therefore requires **adding a new branch**
  `if (formatVersion != null && formatVersion < kCurrentFormatVersion) throw …` —
  the existing null-handling will *not* reject a v1 DB on its own. Reuse or extend
  `LegacyDatabaseFormatException`. The plan's wording covers this; the implementer
  must not assume the current code already gates on the value.

### Site-inventory accuracy (fix before implementing, not a blocker)

The required-parameter strategy means the compiler enumerates every site, so an
incomplete list is not fatal — but the table currently reads as authoritative and
is **wrong in one place** and **incomplete in several**, which will mislead:

- **Misleading:** the `$meta`/`$$…state` row says the name is "in scope at every
  `MetaStore` `getRawByName`/`putRawByName` and the state helpers." It is **not**:
  `$$genstate` is read directly in `cache_layer.dart:299` and `$$indexstate` is
  read/written directly in `index_manager.dart:573/586` — neither goes through
  `MetaStore`. Their AAD must still be `(kGenStateNamespace, genKey(ns))` /
  `(kIndexStateNamespace, indexKey(ns,path))`, which *are* in scope there, so the
  work is fine — but the "funnels through MetaStore" framing is false.
- **Missing `ValueCodec` sites** not in the table: `version_entry.dart:113/126`,
  `version_manager.dart:76/90/247`, `vault_ref_count.dart:136`,
  `vault_extraction_state.dart:311/324`, `index_manager.dart:528` (decodes a
  document during index build — context `(userNs, docKey)`).
- **Wrapper signatures** that must also grow the context param (caught by the
  compiler, but worth naming): `VersionEntry.encode/decode`,
  `VaultExtractionState.encode/decode`, `VaultSearchManager.unwrapIndexValue`.
- **Line numbers have drifted** (e.g. the `$ver:` row cites
  `kmdb_collection.dart:900`; the actual encode sites are `:870` and `:963`). Treat
  every line number in this plan as a hint, not a coordinate.

### Test-strategy additions (Phase 4)

The listed tests cover the golden and boundary paths well. Add:

- [ ] **Relocation/transplant tests must use `AesGcmEncryptionProvider`, not
      `_XorProvider`.** `_XorProvider` ignores nonce and AAD, so a relocation test
      built on it would pass vacuously (it never authenticates anything). The
      real-provider path is what proves the tag covers the AAD.
- [ ] **Docref fieldPath round-trip on an *encrypted* DB** (regression for the
      `vault_searcher.dart:632` fix). The `catch (_)` at `:634` swallows decode
      failure into an empty path, so a wrong-context regression is **silent** — the
      test must assert the fieldPath comes back **non-empty and correct**, not just
      "no throw."
- [ ] **Vault-artifact relocation** (once Q-R1/Q-R2 are resolved): serve a valid
      encrypted blob under the wrong SHA and assert failure — and assert it fails on
      **GCM authentication**, distinct from S-4's post-decrypt SHA-mismatch, or the
      test passes for the wrong reason and would still pass with AAD removed.
- [ ] **Old-format rejection** must write a marker byte of `1` into an otherwise
      current-shaped DB and assert the new `< kCurrentFormatVersion` branch fires
      (not merely the pre-existing `null`-marker path).
- [ ] **Fault injection (CLAUDE.md requirement — currently absent).** This touches
      the open/recovery and `$ver:` write paths. Add at minimum a
      `FaultyStorageAdapter` test that an AAD-bound value written, then recovered
      after a simulated crash, still authenticates; and a crash between stamping the
      format-version marker and the first encrypted value. Confirm in the plan
      whether any AAD test must move to the release checklist
      (`docs/spec/28_release_checklist.md`) — I believe all are automatable, but the
      plan should say so explicitly rather than leave it implicit.

### Recommendation

Resolve Q-R1–Q-R4 (they are quick maintainer calls, but they *are* calls, and the
cost of guessing wrong is silent auth failure on encrypted vault data). Fold the
answers into the value-class table, correct the MetaStore-funnelling claim, and add
the five tests above. With those in place the plan clears the implementation-
readiness bar and can go to `Investigated`. Everything else is already there.

## Reviewer assessment round 2 (kmdb-plan-reviewer, 2026-08-06)

**Verdict: Q-R1–Q-R4 are sound; one new same-class gap found (Q-R5) → stays
`Questions`.** The maintainer's resolutions are correct and well-grounded, and the
named-constructor mechanism is the right fix for the silent-GCM-failure risk. The
only thing standing between this plan and `Investigated` is a fifth encrypted
non-KvStore artifact that the round-1 inventory missed: the vault-manifest
`originalName` (Q-R5 above). It is the *same* class of gap as Q-R1/Q-R2 and has
the *same* silent-failure consequence, so it must be resolved the same way before
implementation.

### What I re-verified holds (do not re-litigate)

- **Q-R1 (vault blobs) is executable and single-sourced.** The `sha256` is
  computed at Step 1 of `VaultStore.put` — *before* the wrap at `:252` — so
  `ValueContext.vaultBlob(sha256)` is available at the write; both reads
  (`getBytes(sha256)` `:369`, `hydrateVaultBlob(sha256)` `local_directory_vault_adapter.dart:239`)
  take `sha256` as a parameter. Three sites, one named constructor, no hand-written
  literal. Confirmed.
- **Q-R2 (extract artifacts) is executable and single-sourced.** `path` is the
  sole parameter of both `writeExtractArtifact(path)` `:224` and
  `readExtractArtifact(path)` `:257`; `ValueContext.vaultExtract(path)` threads
  cleanly. Confirmed.
- **Q-R3 (corpus sentinel + index reads) is coherent — and these are actually
  KvStore-keyed.** The corpus sentinel is read via `_kvStore.get(corpusNs,
  kVaultCorpusSentinelKey)` (`vault_searcher.dart:328-329`) and written through the
  generic `_wrapWriterEntries` loop (`:1117`), which binds `(entry.namespace,
  entry.key)`. `unwrapIndexValue` growing a `ValueContext` param, with callers at
  `:333/:364/:490` supplying their scan-cursor `(ns,key)`, is symmetric by
  construction. `ValueContext.vaultCorpus(...)` must resolve to exactly
  `(VaultBm25Writer.corpusNamespace(sha256), kVaultCorpusSentinelKey)` — both are
  already single-sourced (a shared helper + a `const`), so it is sugar, not a new
  literal. Confirmed sound.
- **Q-R4 (DEK wrap out of scope) is correct** and already slated for §31.
- **`ValueContext` type design (Phase 1) is coherent.** Plain `ValueContext(ns,
  key)` for KvStore values plus the four named constructors; no leftover
  "single `ValueContext(namespace,key)` is sufficient" contradiction — the earlier
  wording was superseded and the added constructors are consistent with it.
- **Phase 4 covers every binding class the resolutions *name*** — blob and extract
  get explicit relocation tests asserting GCM auth failure (distinct from S-4);
  corpus/index values are covered by the auto-symmetric KvStore round-trip; the
  CLAUDE.md fault-injection requirement is present on the open/recovery and `$ver:`
  paths. The one class *not* covered is the one not yet named (Q-R5).

### The single blocker

Resolve **Q-R5**. It is a quick maintainer call (almost certainly: a fifth named
constructor `ValueContext.vaultManifestName(sha256)` with its own fixed namespace
literal, one table row, one Phase 4 relocation test). Once that is folded in —
mirroring exactly how Q-R1/Q-R2 were handled — the plan clears the
implementation-readiness bar. Nothing else is outstanding; the required-parameter
strategy will compiler-enumerate the remaining mechanical sites.

## Reviewer assessment round 3 — final (kmdb-plan-reviewer, 2026-08-06)

**Verdict: Q-R5 resolved soundly; no new blocker → `Investigated`.**

The Q-R5 resolution is correct and consistent with how Q-R1/Q-R2 were handled: a
distinct fifth named constructor `ValueContext.vaultManifestName(sha256)` with its
own single-sourced namespace literal, threaded identically at write and read, plus
a value-class table row and a Phase 4 GCM-auth-failure relocation test. Verified
against the code:

- **`sha256` is in scope at both sites.** Write: computed at `vault_store.dart:215`
  before the `:299` wrap. Read: `getManifest(sha256)` parameter, used at the `:409`
  unwrap. `getManifest` is the single read path (including the dedup read at `:223`),
  so binding is symmetric by construction.
- **Both sites use `EncryptionEnvelope.wrap`/`unwrap`** (`:299` / `:409`), matching
  the Phase 2 threading that grows those primitives a `ValueContext` parameter.
- **The distinct-literal requirement is cryptographically forced, not stylistic.**
  Reusing `vaultBlob(sha256)` would make the manifest-name AAD byte-identical to the
  blob-bytes AAD for the same `sha256` (same literal + same address), permitting a
  swap of the two ciphertexts. A separate literal is mandatory.
- **The census is complete — there is no sixth encrypted non-KvStore artifact.**
  Every `EncryptionEnvelope` wrap/unwrap in `lib/` is one of: KvStore-keyed with a
  real `(namespace, key)` (all of `meta_store`, `cache_layer:299` `$$genstate`,
  `index_manager:573/586` `$$indexstate`, `fts_manager`, `vec_manager`); an
  explicitly-resolved vault non-KvStore case (Q-R1 blobs `:252`/`:369`/adapter
  `:239`, Q-R2 extract `:224`/`:257`, Q-R3 index/corpus `:190`/`:1117`, Q-R5
  manifest `:299`/`:409`); or the out-of-scope DEK wrap (Q-R4,
  `key_derivation.dart:135`/`:177`, the only two direct-`AesGcm` sites). Nothing is
  unaccounted.
- **No internal contradiction.** Phase 1 (`:301-303`), Phase 2 (`:336-339`), the
  value-class table row (`:245`), and Phase 4 (`:373-376`) all name the distinct
  `vaultManifestName` literal consistently.

The required-parameter strategy means the compiler enumerates every remaining
mechanical site, so the drifted line numbers noted in round 1 are hints rather than
blockers. The plan clears the implementation-readiness bar: a Sonnet implementer can
execute it with no significant design decisions left. Handing off to
**`kmdb-plan-implement`**.

## Summary

_To be completed when the work is done._
