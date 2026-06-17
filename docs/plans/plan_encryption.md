# Database Encryption (Phase 12)

**Status**: Investigated

**PR link**: —

## Problem statement

KMDB uploads SSTables verbatim to cloud storage as part of its sync protocol.
OS disk encryption and TLS protect the device and bytes in transit, but they do
not provide end-to-end confidentiality: the cloud provider (or anyone with
account access) can read plaintext user data. Users who deliberately choose a
local-first database over cloud-native products are disproportionately privacy-
conscious; a zero-knowledge sync option is a material gap.

This plan implements opt-in, value-level AES-256-GCM encryption extending the
existing §5 value pipeline. Encryption is transparent to the sync, compaction,
and consolidation machinery — all of which operate on keys and file structures,
never on value contents. The same DEK encrypts vault blobs before upload
(§24). Key management uses Argon2id KDF + envelope encryption so users need
only a passphrase and a generated recovery code — no key files, no PGP.

The full design rationale and alternatives analysis are in
[docs/proposals/encryption.md](../proposals/encryption.md).

---

## Open questions

- [x] **Q1 (blocking): Flag byte layout.** The current
  `CompressionFlag` enum uses `0x00` (none) and `0x01` (Zstd). The
  `fromByte` switch rejects all other values, with a comment noting
  `0x02` was the "legacy Deflate byte." Does the encryption stage
  extend the existing flag byte as a bitmask (e.g. bit 1 = encrypted →
  `0x02` = none+enc, `0x03` = Zstd+enc), or is it a second prefix byte
  (`[compression][encryption][payload]`)? The `0x02`-was-Deflate
  history makes a pure bitmask at that bit position ambiguous. A second
  byte has a higher overhead but avoids any legacy-byte confusion and
  keeps the two concerns independently evolvable.

  > **Decision: use a second, independent encryption flag byte.** The on-disk
  > format becomes `[compression_flag 1B][encryption_flag 1B][payload]`, where
  > the encryption flag is `0x00` (plaintext) or `0x01` (AES-256-GCM). Do **not**
  > overload the compression flag byte as a bitmask.
  >
  > **(a) Is the `0x02`-as-Deflate history a real concern?**
  > It is a *comment artefact*, not a live data-format concern. `CompressionFlag`
  > (`packages/kmdb/lib/src/encoding/compression_flag.dart`) defines only
  > `none(0x00)` and `zstd(0x01)`; `fromByte` throws `ArgumentError` for every
  > other byte including `0x02`. Deflate was removed before this code's current
  > form, and the §5 spec compression-flag table lists only `0x00`/`0x01` — there
  > is no Deflate row. No KMDB release ever shipped a stable on-disk format
  > emitting `0x02` for Deflate that we must preserve compatibility with. **The
  > byte is genuinely free.** However, the comment is evidence of *intent*:
  > `CompressionFlag` is the dimension reserved for *compression algorithm
  > evolution* (Deflate yesterday, dictionary-Zstd tomorrow per §5 "Zstd
  > Dictionary Compression (Future)"). Encryption is an orthogonal dimension and
  > should not consume bit-space in that enum.
  >
  > **(b) Which fits KMDB's format-evolution posture?**
  > A second byte. Rationale:
  > 1. **Independent evolution.** §5 explicitly plans to grow the compression
  >    dimension (dictionary Zstd, WASM Zstd on web). A bitmask packs two
  >    independently-growing axes into one byte and creates combinatorial
  >    `fromByte` cases (`0x00`–`0x03` today, `0x00`–`0x07` the moment a third
  >    compression algorithm appears). A separate byte lets each axis own a clean
  >    `enum` + `fromByte` and grow without touching the other.
  > 2. **Forward-compat error semantics already exist.** §5 states "Any other
  >    flag byte is rejected with `ArgumentError` — unknown flags indicate data
  >    written by a future version of KMDB or silent corruption." A dedicated
  >    `EncryptionFlag.fromByte` inherits exactly this posture: an old build that
  >    reads an encrypted value gets a clean, attributable error on the
  >    *encryption* byte rather than a confusing "unknown CompressionFlag 0x03."
  > 3. **Overhead is negligible.** 1 byte per value against a 28-byte AEAD
  >    overhead (12-byte nonce + 16-byte tag) the encryption stage already adds,
  >    and against typical 1–10KB documents. Not a deciding factor.
  > 4. **Cleaner code.** The encrypt stage is a transparent wrapper around the
  >    *entire* existing compression output (including the compression byte),
  >    exactly matching the proposal's compress-then-encrypt order. A second outer
  >    byte mirrors that layering literally; a bitmask forces both stages to
  >    co-mutate one byte.
  >
  > **Implementation note (format precision):** define the wire order as the
  > encryption byte being the **outermost** prefix written last and read first:
  > `[encryption_flag][compression_flag][compressed_payload]`, where on decode the
  > encryption byte is consumed first, the remaining bytes are decrypted, and the
  > *decrypted* bytes are then `[compression_flag][payload]` fed to the existing
  > decompress path. This keeps the compression byte *inside* the ciphertext, so
  > the compression algorithm used is not leaked to the cloud (a minor
  > confidentiality bonus) and the existing `ValueCodec.decode` compression logic
  > is reused verbatim on the plaintext. Spec §5 and the new encryption spec must
  > state this order explicitly. Add a new `EncryptionFlag` enum
  > (`none(0x00)`, `aesGcm(0x01)`) alongside `CompressionFlag`; do not extend
  > `CompressionFlag`.
  >
  > **Cross-reference / drift to fix:** §5 currently documents the legacy Deflate
  > `0x02` only implicitly and the code comment names it; both the §5 update and
  > the new encryption spec should make the two-byte layout and the
  > encrypt-outside-compress order canonical, and the §5 compression-flag table
  > should gain a sibling encryption-flag table.

- [x] **Q2 (blocking): `$meta` bootstrap sequence.** The wrapped DEK and
  Argon2id salt must be persisted somewhere the engine can read before
  user values are decrypted. `$meta` is the natural home (it already
  stores engine metadata, syncs normally, and has `putRawByName` /
  `getRawByName` helpers). The bootstrap sequence in `KmdbDatabase.open()`
  must be spelled out precisely: (1) open the LSM engine; (2) read
  `$meta` entries for the encryption blob (plaintext — the wrapped DEK
  is not itself sensitive); (3) derive/unwrap the DEK from the
  passphrase or recovery code; (4) inject the `EncryptionProvider` into
  `KvStoreConfig`; (5) proceed with normal open (crash recovery, index
  rebuild, etc.). The question is where in the existing
  `KvStoreImpl.open` / `KmdbDatabase.open` call chain this fits, and
  what the error posture is if the encryption blob is absent when a
  config is supplied (or present when no config is supplied).

  > **Decision: the bootstrap belongs in `KmdbDatabase.open()`, between
  > `KvStoreImpl.open()` and the construction of every consumer that decodes
  > values (cache, index manager, FTS/Vec managers, schema/version stores).** The
  > `EncryptionProvider` is *not* injected into `KvStoreConfig` and is *not* used
  > by `KvStoreImpl`. This is the load-bearing finding below.
  >
  > **Architectural correction — where encryption actually composes.**
  > The proposal (§8.2) and this plan's draft both say the encryption stage lives
  > "inside `ValueCodec` at the `KvStore` boundary" via a
  > `KvStoreConfig.encryptionProvider`. That is **not where `ValueCodec` runs.**
  > `ValueCodec` is a static, stateless codec invoked from ~13 call sites that all
  > sit *above* the KvStore boundary — `KmdbCollection`, `KmdbQuery`,
  > `IndexManager`, `FtsManager`, `VecManager`, `VersionManager`/`VersionEntry`,
  > and `VaultRefInterceptor`. `KvStoreImpl.put/get/writeBatch` never call
  > `ValueCodec`; they move opaque `Uint8List` through the WAL/memtable/SSTable
  > path (confirmed: `grep ValueCodec lib/src` shows zero hits under
  > `engine/kvstore/`). Therefore:
  > - The DEK/`EncryptionProvider` must be threaded into the **Query-Layer value
  >   pipeline**, not `KvStoreConfig`. Concretely: give `ValueCodec.encode`/
  >   `decode` an optional `EncryptionProvider` parameter (the stateless static
  >   methods stay static; the provider is passed per call), and thread one shared
  >   provider instance from `KmdbDatabase` down to every `ValueCodec` call site.
  >   `KmdbDatabase` already owns and wires all of those collaborators in `open()`,
  >   so it is the correct injection root.
  > - **`enc:blob` must itself be written/read as raw `$meta` bytes, never through
  >   the encrypting `ValueCodec` path** — otherwise bootstrap is circular. Use
  >   `MetaStore.getRawByName('enc:blob')` / `putRawByName`, which bypass
  >   `ValueCodec` entirely and write plaintext CBOR. `$meta` generation counters,
  >   device id, etc. are *also* not run through `ValueCodec`, so the engine
  >   metadata path stays plaintext by construction. Good: the bootstrap read has
  >   no dependency on the DEK.
  > - **`KvStoreConfig` gains no encryption field.** The draft's
  >   "Source files affected" row for `kv_store.dart`/`kv_store_impl.dart` should
  >   be re-scoped: the engine and KvStore are untouched by encryption. (This is
  >   consistent with the proposal's own §3.4 thesis that the cloud-facing/engine
  >   layer "stays structurally dumb" and never decrypts.)
  >
  > **Exact call-chain placement in `KmdbDatabase.open()`** (current open order
  > is: `KvStoreImpl.open` → `CacheLayer` → `IndexManager` (+ interrupted-build
  > check) → `FtsManager`/`VecManager` recovery → vault recovery → `SchemaManager`
  > register/load → `VersionConfigStore` load/persist → wire registry/drop
  > callbacks → `KmdbDatabase._(...)`). Insert the bootstrap **immediately after
  > `KvStoreImpl.open()` returns and before `CacheLayer`/`IndexManager` are
  > built**:
  >
  > 1. `final (store, openResult) = await KvStoreImpl.open(...)` — unchanged.
  >    Crash recovery + WAL replay run here on *ciphertext* values, which is fine:
  >    recovery operates on keys, HLCs, and opaque value bytes; it never decodes.
  > 2. `final blob = await store.meta.getRawByName('enc:blob')` (plaintext CBOR).
  > 3. **Resolve the four states** (see error posture below). On the happy "open
  >    existing encrypted DB" path, decode the blob, run Argon2id(passphrase,
  >    salt) → KEK (or HKDF(recoveryEntropy) → recovery-KEK), AES-GCM-unwrap the
  >    matching wrapped-DEK → DEK, and construct the
  >    `AesGcmEncryptionProvider(dek)`. On the "create new encrypted DB" path,
  >    generate DEK+salt+recovery entropy, wrap, and `putRawByName('enc:blob', …)`
  >    **before** any user write can occur.
  > 4. Hold the resulting `EncryptionProvider?` (null when unencrypted) and pass
  >    it into `CacheLayer`, `IndexManager`, `FtsManager`, `VecManager`,
  >    `SchemaManager`, the version stores, and `KmdbDatabase._` so all
  >    `ValueCodec` calls route through it. (`$meta`-backed stores that use
  >    `getRawByName`/`putRawByName` — schema, version config — stay plaintext and
  >    need no provider.)
  > 5. Continue the existing open sequence unchanged (cache, indexes, vault
  >    recovery, schemas, version configs, callbacks).
  >
  > Note the ordering subtlety: vault recovery and index/FTS/Vec build all decode
  > values, so they **must** run *after* step 3 — they already do, since they are
  > later in `open()`. The interrupted-index-build check and the FTS/Vec
  > `checkAndTransitionOnOpen` calls only read index *state* (not user docs) but
  > any rebuild they trigger needs the provider, so keeping the bootstrap at the
  > very top of `open()` (step 3) is the safe placement.
  >
  > **Error posture (four states), resolved as a 2×2 on
  > `{enc:blob present?} × {EncryptionConfig supplied?}`:**
  >
  > | `enc:blob` | `EncryptionConfig` | Behaviour |
  > | :--------- | :----------------- | :-------- |
  > | absent     | none               | Normal unencrypted open. Provider = null. |
  > | present    | none               | **Throw `EncryptionError.databaseIsEncrypted`.** Decoding would yield ciphertext-as-CBOR garbage / `FormatException`; fail loudly and early instead. |
  > | absent     | supplied (unlock)  | **Throw `EncryptionError.databaseIsNotEncrypted`.** Opening a plaintext DB with an unlock config is a caller mistake; silently ignoring the passphrase would be worse. |
  > | absent     | supplied (`create`)| Provision a new encrypted DB: generate + wrap + persist `enc:blob`, return provider. This is the *only* path that writes a new blob. |
  > | present    | supplied (unlock)  | Unwrap DEK. If neither passphrase nor recovery code matches (AES-GCM tag failure on unwrap), **throw `EncryptionError.badCredentials`** (wrong passphrase / wrong recovery code). |
  >
  > The `create` vs `unlock` distinction is carried by the config itself: per the
  > proposal's §8.1 API, `EncryptionConfig.create()` is a distinct factory from the
  > `EncryptionConfig(passphrase:/recoveryCode:)` unlock constructor. `open()` must
  > be able to tell them apart (e.g. an internal `isProvisioning` flag on the
  > config) so the "absent + supplied" cell can branch between
  > `databaseIsNotEncrypted` (unlock) and provisioning (create). **Add these
  > `EncryptionError` cases to the §11/new-encryption spec and to the plan's
  > Phase 2 invariant step.**
  >
  > **Crash-safety note for provisioning:** the `enc:blob` write at creation must
  > be durable *before* the first encrypted user value is written, or a crash
  > between the two leaves undecryptable values with no wrapped DEK. Since
  > `putRawByName` goes through the normal WAL+memtable path, fold the `enc:blob`
  > write into the open sequence and `flush()` (or rely on the first user
  > `WriteBatch` ordering) such that no encrypted value can precede a durable
  > blob. The implementation plan should call this out and the
  > `FaultyStorageAdapter` harness (per the 2026-05-22 review §8) should cover
  > "crash after first encrypted put, before blob fsync" — though folding blob
  > creation entirely within `open()` before returning the handle makes this
  > naturally safe.

- [x] **Q3 (medium): `PlatformIdStore` scope.** Roadmap 0.07 pairs
  encryption with a `PlatformIdStore` abstraction for per-platform
  secure storage, noting it could back both the DEK cache
  (`flutter_secure_storage`) and the device ID (currently in `$meta`).
  Should `PlatformIdStore` be designed as part of this plan, or should
  the DEK caching use `flutter_secure_storage` directly and
  `PlatformIdStore` be left for a follow-on? Scope needs a decision
  before the implementation plan can be finalized.

  > **Decision: defer `PlatformIdStore`. This plan uses `flutter_secure_storage`
  > directly for the DEK session cache, behind a *small internal* seam, and does
  > not design or implement the general `PlatformIdStore` abstraction.**
  >
  > **Findings:**
  > - `PlatformIdStore` does **not** exist in the codebase today — `grep`
  >   confirms it appears only in `docs/roadmap/0_07.md`, the encryption
  >   proposal, the roadmap review (Q4), and the researcher's notes. It is a
  >   roadmap *aspiration*, not an existing seam this plan must integrate with.
  > - The roadmap frames it as *"injectable via a `PlatformIdStore` interface;
  >   default falls back to `$meta`"* and explicitly couples it to **device ID**
  >   storage. The device ID currently lives in the `DEVICE_ID` file (primary)
  >   with a `$meta` fallback (see `KvStoreImpl.ensureDeviceId` /
  >   `MetaStore.getDeviceId`). Reworking device-ID storage onto a new secure-
  >   storage abstraction is an *orthogonal* change to encryption with its own
  >   sync/identity-churn considerations (the existing DEVICE_ID file design
  >   exists precisely to keep identity out of the synced `$meta`, decision D4).
  >   Folding it into the encryption plan would expand scope into the device-
  >   identity subsystem with no encryption benefit.
  > - The roadmap-review Q4 itself only asks that the plan *state* whether the
  >   two are co-designed or independent — it does not mandate co-design.
  >
  > **Rationale for deferral:**
  > 1. **Scope discipline.** The encryption plan is already large (value
  >    pipeline, key management, bootstrap, vault, CLI, spec). The DEK cache needs
  >    exactly one capability — "store/read/delete a few opaque secret bytes
  >    keyed by a string on this platform" — which `flutter_secure_storage`
  >    provides directly. A general `PlatformIdStore` that *also* abstracts device
  >    ID, falls back to `$meta`, and is consumer-injectable is a broader design
  >    that should not be back-derived from one caller.
  > 2. **Avoid premature abstraction.** Designing the interface with a single
  >    known consumer (DEK cache) risks baking in the wrong shape for the second
  >    consumer (device ID), which has different durability/sync semantics. Let
  >    the device-ID migration drive the interface when 0.07 picks it up.
  > 3. **Web already opts out.** Per proposal §4.3/§6.3, web does **not** persist
  >    the DEK at all (re-derive per session). So the secure-storage seam is
  >    native/mobile-only in practice — a thin wrapper, not a cross-platform
  >    abstraction layer, is sufficient for v1.
  >
  > **Concrete recommendation for this plan:** introduce a minimal internal
  > interface (e.g. `DekCache` with `Future<void> store(...)`,
  > `Future<Uint8List?> read(...)`, `Future<void> clear(...)`) with one
  > `flutter_secure_storage`-backed implementation and one no-op/in-memory
  > implementation for web and tests. Keep it deliberately encryption-scoped and
  > *not* named `PlatformIdStore`. When roadmap 0.07 designs the real
  > `PlatformIdStore`, the DEK cache becomes one of its consumers — a clean
  > follow-on refactor, not a blocker now.
  >
  > **Follow-on to record:** add a roadmap/plan note that `PlatformIdStore`
  > (device ID + DEK cache unification, `$meta` fallback) is deferred and should
  > subsume this plan's `DekCache` seam when undertaken. The proposal's §11 Q4 and
  > roadmap-review Q4 are answered by this deferral decision.

- [x] **Q4 (blocking — raised by reviewer): per-call encryption contract +
  do system namespaces reach the sync folder?** Because `ValueCodec` is a single
  static codec shared by user documents, `$ver:` history, `$vault` refcounts,
  and the source-doc reads inside `IndexManager`/`FtsManager`/`VecManager`, a
  global "encrypt on/off" is too coarse. The plan must define the exact per-call
  rule for which `ValueCodec` calls receive the provider. This depends on a fact
  that must be confirmed with **kmdb-architect against §12**: sync is **file-level**
  (whole-SSTable upload) with **no namespace filtering at upload** (verified —
  `sync_engine.dart` has no per-namespace skip). If `$fts:`/`$vec:`/`$cache:`/
  `$index:` values are written into ordinary SSTables that are uploaded, then
  leaving them plaintext **leaks indexed/derived content to the cloud**,
  contradicting the threat model — in which case "encrypt everything that goes
  through `ValueCodec`, keyed by the one DEK" is the simpler and safer rule (keys
  stay plaintext regardless, so the documented index-key local leak is unchanged).
  Conversely `$ver:` history is unambiguously user data and **must** be encrypted;
  `$vault` refcounts are not user content and may stay plaintext if the per-call
  contract allows it. Resolve:
  (a) confirm whether system namespaces reach the sync folder (§12);
  (b) record the per-call contract for every `ValueCodec` call site;
  (c) add the resulting in-scope/non-goal lines to the Investigation Non-goals.

  > **Decision (a): system-namespace values DO reach the cloud. The proposal's
  > "system namespaces are excluded from sync" claim is FALSE for SSTable
  > *contents*. The threat-model wording must change, and the safe rule is
  > "encrypt everything that goes through `ValueCodec`."**
  >
  > **Finding — sync is whole-file with no content filter (verified against code
  > and §12):**
  > - `SyncEngine.push` (`packages/kmdb/lib/src/sync/sync_engine.dart`, steps 3–5)
  >   lists local `.sst` files for this device, then for each file does
  >   `readFile(...)` → `cloudAdapter.upload(...)` — the **entire SSTable byte
  >   stream is uploaded verbatim.** There is no decode, no key inspection, no
  >   namespace filter.
  > - `_syncNamespaces` is stored on `SyncEngine`, exposed via a getter, and
  >   resolved in `KmdbDatabase._buildSyncEngine` (it strips `$`-prefixed
  >   namespaces) — **but it is never consulted in `push()`, `pull()`, or the
  >   `ConsolidationCoordinator`.** `grep _syncNamespaces sync_engine.dart`
  >   returns only the field/getter/constructor — zero use sites in the upload
  >   path. The set is effectively dead for its stated filtering purpose.
  > - The consolidation coordinator likewise merges and re-uploads SSTable bytes
  >   without namespace inspection; consolidation **output SSTables therefore also
  >   contain system-namespace keys** (it is an N-way merge of the same files).
  > - **Spec/code drift:** §12 "Namespace-Scoped Sync" (lines 421–423) asserts
  >   *"During SSTable upload, the sync layer filters to include only entries for
  >   sync-enabled namespaces."* **No such filtering exists in the code.** This is
  >   an independent §12 documentation bug that must be corrected regardless of
  >   the encryption work (file an architect doc-fix: either implement the filter
  >   or strike the claim).
  >
  > **Which namespaces are KvStore-persisted (and thus land in uploaded SSTables):**
  > - `$index:` (secondary indexes), `$fts:` (BM25), `$vec:` (vector index),
  >   `$ver:` (version history), `$vault` (refcounts), and `$meta` — **all are
  >   written via `WriteBatch` → `store.writeBatch(Internal)`**, i.e. the same
  >   memtable/SSTable path as user documents (confirmed: `fts_manager.dart`
  >   commits via `_store.writeBatchInternal`; `vault_ref_interceptor.dart` writes
  >   `$vault` refcounts in the document's `WriteBatch`). They are **not** held in
  >   a separate file — they ride in ordinary SSTables and are uploaded.
  > - **`$cache` is the exception:** the materialised-view cache (§15.3) is
  >   **not implemented** — `cache_layer.dart` explicitly notes *"Scan results are
  >   not materialised in the session cache at this layer."* The session cache is
  >   in-memory (`SessionCache`/`LruMap`) only. **No `$cache` namespace is written
  >   to the KvStore today**, so it cannot reach the cloud. (If §15.3 is ever
  >   implemented as KvStore-backed, it inherits the same rule below.)
  >
  > **Consequence:** leaving `$index:`/`$fts:`/`$vec:` values plaintext leaks
  > **derived/indexed user content** (indexed field values, tokenised terms,
  > embeddings) to the cloud — a direct contradiction of the zero-knowledge threat
  > model. `$ver:` is verbatim user data. `$meta` and `$vault` are engine
  > bookkeeping. The keys (index entries embed field *values in the key*) stay
  > plaintext regardless — that is the documented local-disk leak (covered by OS
  > disk encryption) and is now *also* a cloud leak for the key portion (see
  > non-goal note), but the **value** portion can and must be protected.
  >
  > **Decision (b): per-call `ValueCodec` encryption contract.** When a provider
  > is present (encrypted DB), pass it on **every** `ValueCodec.encode`/`decode`
  > call **except** the `$meta` raw blob path (which never uses `ValueCodec` —
  > `getRawByName`/`putRawByName`, per Q2). Concretely:
  >
  > | `ValueCodec` call site | Namespace | Encrypt? | Reason |
  > | :--------------------- | :-------- | :------- | :----- |
  > | `KmdbCollection`/`KmdbQuery` doc read/write | user | **Yes** | User data. |
  > | `IndexManager` source-doc decode + index *value* writes | `$index:` | **Yes** | Index values are derived user content and reach the cloud. |
  > | `FtsManager` term/docinfo/stats value writes | `$fts:` | **Yes** | Tokenised user content reaches the cloud. |
  > | `VecManager` embedding/value writes | `$vec:` | **Yes** | Embeddings are derived user content; reach the cloud. |
  > | `VersionManager`/`VersionEntry` (`$ver:`) | `$ver:` | **Yes** | Verbatim prior user document versions. |
  > | `VaultRefInterceptor`/`VaultRefCount` (`$vault` refcounts) | `$vault` | **Yes** (see Q6) | Rides in synced SSTables; encrypt for uniformity — see Q6. |
  > | `enc:blob` (wrapped DEK + salt) | `$meta` (raw) | **No** | Bootstrap; must be readable before the DEK exists. Never routed through `ValueCodec`. |
  > | `$meta` generation counters, device id, etc. | `$meta` (raw) | **No** | Not `ValueCodec`-encoded; plaintext by construction. |
  >
  > **The simplifying rule for the implementer:** *every `ValueCodec` call site
  > listed in the Investigation table receives the shared `EncryptionProvider?`.*
  > There is no call site that should be deliberately left plaintext while a
  > provider is active. This makes the per-call contract a single uniform
  > "thread the provider everywhere `ValueCodec` is called" — the static
  > `enc:blob`/`$meta` plaintext path is already off the `ValueCodec` path by Q2,
  > so it needs no special-casing. This also resolves the "global on/off too
  > coarse" concern: the granularity is per-call, but the *policy* is uniform, so
  > there is no risk of a forgotten call site leaking a namespace.
  >
  > **Decision (c): Non-goal / threat-model corrections (see updated
  > "Local information leak" and Non-goals sections below):**
  > 1. Strike "system namespaces are excluded from sync" from the proposal's
  >    threat model. They are **not** excluded; their *values* are now encrypted
  >    and their *keys* (which for `$index:` embed field values) remain plaintext
  >    in synced SSTables — a documented **cloud** leak of indexed field *keys*,
  >    not merely local. Index-key confidentiality remains a non-goal for v1
  >    (proposal §2/§12), now explicitly extended to the cloud.
  > 2. Record the independent §12 doc bug (the non-existent upload-time namespace
  >    filter) for the architect to fix separately from encryption.

- [x] **Q5 (sub-decision A — raised by reviewer): KVLT package encryption.**
  When encryption is enabled and vault blobs are ciphertext on disk, what should
  a `.kvlt` export contain — ciphertext as-is, decrypted plaintext, or
  re-encrypted under a separate export key?

  > **Decision: Option 2 — decrypt to plaintext on export; encrypt on import.**
  > A `.kvlt` package is a **plaintext, portable, self-contained** interchange
  > unit. The DEK never travels with it.
  >
  > **Findings (what `.kvlt` is for, who consumes it):**
  > - `VaultPackage` (`vault_package.dart`) is the KVLT archive format used by the
  >   CLI `export`, `dump`, `insert --import`, and `update --import` commands
  >   (`kmdb_cli/lib/src/commands/{export,dump,insert,update}_command.dart`) and
  >   by backup/restore (§24 "Package Layout"). Its purpose is **interchange and
  >   backup** — moving a document plus its referenced vault objects between
  >   databases, machines, or users.
  > - The package's `document.json` is **already plaintext JSON** (it is the
  >   decoded document map, written via `JsonEncoder`). The container itself is
  >   not encrypted (today it is not even Zstd-compressed at the frame level).
  >
  > **Rationale:**
  > 1. **Internal consistency.** A package whose `document.json` is plaintext but
  >    whose blobs are ciphertext is self-contradictory: the recipient can read
  >    the document and the vault URIs but cannot open the bytes. Option 1
  >    (ciphertext as-is) produces a package that is useless without out-of-band
  >    transfer of the source DB's DEK — defeating the point of a portable archive.
  > 2. **Cross-database semantics.** Vault content addresses are SHA-256 over
  >    **plaintext** (preserved by this plan — see "Vault encryption"). Import into
  >    a *different* database re-ingests the blob and re-encrypts it under the
  >    *destination* DEK. Carrying source ciphertext would force the destination to
  >    either store foreign ciphertext (un-decryptable) or decrypt-then-re-encrypt
  >    anyway — so plaintext-in-package is the only coherent boundary.
  > 3. **Option 3 (separate export key) is over-engineering for v1.** It adds a
  >    key-exchange problem the project explicitly defers (proposal §2:
  >    multi-unlocker and key rotation are non-goals). It can be a future
  >    "encrypted export" enhancement without changing the v1 format.
  >
  > **Implementation contract:** `VaultPackage.write` (and its CLI callers) must
  > be fed **plaintext** blob bytes — the export path decrypts via the
  > `EncryptionProvider` before packaging, exactly as a normal vault read does
  > (see Phase 4 "Decrypt on read"). `VaultPackage` itself stays
  > encryption-agnostic (it already only moves opaque bytes). On `--import`, the
  > ingested plaintext blob flows through the normal vault write path and is
  > re-encrypted under the destination DEK. **Security note to document:** a
  > `.kvlt` file is plaintext at rest — protecting it is the user's responsibility
  > (it is an export, conceptually a decrypted backup). State this in §24 and the
  > encryption spec.

- [x] **Q6 (sub-decision B — raised by reviewer): `$vault` refcount encryption.**
  Should `$vault` per-blob reference counts (encoded via `ValueCodec`) be
  encrypted, or excluded as a system namespace?

  > **Decision: encrypt them — consistent with the Q4 uniform "encrypt every
  > `ValueCodec` call site" rule.**
  >
  > **Findings:**
  > - Ref counts live in the `$vault` namespace (`kVaultNamespace = r'$vault'` in
  >   `vault_recovery.dart`), keyed by SHA-256 hex, value =
  >   `ValueCodec.encode({'refCount': N})`. Written by `VaultRefInterceptor` inside
  >   the document's `WriteBatch`; read by the fail-safe `VaultRefCount.read` via
  >   `ValueCodec.decode`. They **do pass through `ValueCodec`** and **do ride in
  >   uploaded SSTables** (Q4 finding).
  >
  > **Rationale:**
  > 1. **Uniformity beats cleverness.** The Q4 contract is "thread the provider
  >    through every `ValueCodec` call site." Carving out `$vault` as a plaintext
  >    exception reintroduces exactly the "which call sites are special?" fragility
  >    Q4 was written to eliminate. The implementer threads one provider into
  >    `VaultRefInterceptor`/`VaultRefCount` like every other call site.
  > 2. **Low information value but non-zero.** A refcount value is `{'refCount': N}`
  >    — it leaks little, but encrypting it costs ~29 bytes of AEAD overhead per
  >    blob and buys consistency; there is no performance reason to special-case it
  >    (refcounts are tiny and rare relative to documents).
  > 3. **Bootstrap-safe.** Unlike `enc:blob`, `$vault` refcounts are **not** read
  >    before the DEK exists — vault recovery runs *after* the encryption bootstrap
  >    (Q2 step 3 constructs the provider at the very top of `open()`, before vault
  >    recovery). Encrypting them creates no circular dependency. (Confirm in
  >    implementation: `vault_recovery.dart` ref-count reads occur after the
  >    provider is available.)
  >
  > **Non-goal note:** the `$vault` *key* (the SHA-256 content address) stays
  > plaintext — same posture as all other namespace keys (Q4). Only the value is
  > encrypted.

- [x] **Q7 (sub-decision C — raised by reviewer): Flutter dependency boundary.**
  `flutter_secure_storage` and `cryptography_flutter` are Flutter packages;
  `kmdb` must stay pure-Dart. Where does the concrete secure-storage
  implementation live, and what does the injectable seam look like?

  > **Decision: `kmdb` stays pure-Dart. Define a pure-Dart `DekCache` interface
  > (the Q3 seam) inside `kmdb`; the `flutter_secure_storage`-backed implementation
  > lives in a NEW pure-add-on package, `kmdb_flutter` — NOT in `kmdb` and NOT in
  > `kmdb_ui`. Do NOT add `cryptography_flutter`/`flutter_secure_storage` to
  > `packages/kmdb/pubspec.yaml`.**
  >
  > **Findings (the boundary is real and load-bearing):**
  > - `packages/kmdb/pubspec.yaml` declares `environment: sdk: ^3.12.0` with **no
  >   `flutter:` key and no Flutter dependencies** — it is a pure-Dart library.
  > - `packages/kmdb_cli/pubspec.yaml` is **also pure-Dart** (`sdk: ^3.12.0`,
  >   depends on `kmdb`) and runs under `dart test`. If `kmdb` grew a transitive
  >   Flutter dependency, `kmdb_cli`'s `dart pub get` / `dart test` would break
  >   (the Flutter SDK is not resolvable under plain `dart`). This is the concrete
  >   regression the reviewer's note (3) warns about — it **must** be avoided.
  > - The Q3 decision already mandates a minimal `DekCache` seam
  >   (`store`/`read`/`clear`) plus a no-op/in-memory implementation for web and
  >   tests. Q7 only needs to place the *Flutter-backed* implementation.
  >
  > **Rationale for a separate `kmdb_flutter` package (not a conditional export,
  > not `kmdb_ui`):**
  > 1. **Conditional export does not work here.** Conditional exports switch on
  >    `dart.library.io` vs `dart.library.js_interop` (native vs web) — they
  >    **cannot** express "Flutter present vs not." A `flutter_secure_storage`
  >    import in any conditionally-exported file still forces the dependency into
  >    `kmdb`'s pubspec, breaking pure-Dart `dart test` for `kmdb` and `kmdb_cli`.
  >    The platform-conditional-export pattern used elsewhere in `kmdb` (§19) is
  >    the wrong tool for the Flutter boundary.
  > 2. **`kmdb_ui` is the wrong home.** `kmdb_ui` is a **separate downstream repo**
  >    (`github.com/bettongia/kmdb-ui`), not in this workspace. The DEK cache is a
  >    core capability any Flutter *host* needs (not just the reference UI), so it
  >    belongs in a workspace package that the UI repo and other Flutter consumers
  >    can both depend on.
  > 3. **A thin Flutter add-on package is the established pattern.** It mirrors the
  >    existing optional opt-in adapters (`kmdb_google_drive`, `kmdb_icloud`): a
  >    small package depending on `kmdb` (for the `DekCache` interface) plus
  >    `flutter_secure_storage`, exposing one `FlutterSecureDekCache implements
  >    DekCache`. Pure-Dart consumers (CLI, tests, headless) inject the
  >    in-memory/no-op `DekCache`; Flutter apps inject `FlutterSecureDekCache`.
  >
  > **Interface shape (pure-Dart, in `kmdb`):**
  >
  > ```dart
  > /// Caches an unwrapped DEK in platform-appropriate secure storage so the
  > /// user is not re-prompted for a passphrase every session. Pure-Dart seam;
  > /// concrete secure-storage impls live outside `kmdb`.
  > abstract interface class DekCache {
  >   Future<void> store(String dbId, Uint8List dek);
  >   Future<Uint8List?> read(String dbId);
  >   Future<void> clear(String dbId);
  > }
  >
  > /// Default for web, CLI, tests, and headless use: never persists the DEK
  > /// (web re-derives per session per proposal §4.3/§6.3).
  > final class InMemoryDekCache implements DekCache { /* … */ }
  > ```
  >
  > `EncryptionConfig` accepts an optional `DekCache` (default `InMemoryDekCache`);
  > the new `kmdb_flutter` package provides `FlutterSecureDekCache`.
  >
  > **`cryptography_flutter` placement:** same logic. `cryptography` (pure-Dart) is
  > the core dependency added to `kmdb`; `cryptography_flutter` (which registers
  > faster native AES/Argon2id via Flutter plugins) is a **runtime accelerator
  > only** — `package:cryptography` works without it in pure Dart. So
  > `cryptography_flutter` also goes in `kmdb_flutter`, registered by the Flutter
  > host at startup, **not** in `packages/kmdb/pubspec.yaml`. The "Source files
  > affected" pubspec row must be corrected accordingly (see below): only
  > `cryptography` is added to `kmdb`; the two Flutter packages move to
  > `kmdb_flutter`.

---

## Investigation

### Source files affected

| File | Change |
| :--- | :----- |
| `packages/kmdb/lib/src/encoding/compression_flag.dart` | Extend or replace with a combined flag type; depends on Q1 resolution |
| `packages/kmdb/lib/src/encoding/value_codec.dart` | Add `encrypt`/`decrypt` stage *outside* the compression byte (per Q1); take an optional `EncryptionProvider` parameter on `encode`/`decode` (methods stay static) |
| `packages/kmdb/lib/src/encoding/encryption_flag.dart` (new) | `EncryptionFlag` enum (`none(0x00)`, `aesGcm(0x01)`) with `fromByte` mirroring `CompressionFlag`'s forward-compat error posture (per Q1) |
| ~~`kv_store.dart` / `kv_store_impl.dart`~~ | **No change (per Q2).** Encryption composes in the Query-Layer value pipeline, not at the KvStore boundary; `KvStoreConfig` gains **no** encryption field and `KvStoreImpl` never sees the provider. |
| All `ValueCodec` call sites (Query Layer, search, versioning, vault): `kmdb_collection.dart`, `kmdb_query.dart`, `index/index_manager.dart`, `search/lexical/fts_manager.dart`, `search/semantic/vec_manager.dart`, `versioning/version_*.dart`, `vault/vault_ref_interceptor.dart`, `vault/vault_ref_count.dart` | Thread the shared `EncryptionProvider?` from `KmdbDatabase` into each `ValueCodec.encode`/`decode` call (per Q2) |
| `packages/kmdb/lib/src/engine/kvstore/meta_store.dart` | Add `getEncryptionBlob`/`putEncryptionBlob` helpers for `enc:blob` (wrapped DEK, salt, KDF params) **using the raw `getRawByName`/`putRawByName` path** so the blob is plaintext CBOR and bootstrap is non-circular (per Q2) |
| `packages/kmdb/lib/src/query/kmdb_database.dart` | Accept `EncryptionConfig`; run the encryption bootstrap immediately after `KvStoreImpl.open()` and before cache/index/vault construction; thread the resulting provider into every value-decoding collaborator (per Q2) |
| `packages/kmdb/lib/src/vault/vault.dart` (or equivalent) | Encrypt blob bytes with same DEK before write; compute SHA-256 over plaintext |
| New: `packages/kmdb/lib/src/encryption/` | `EncryptionConfig`, `EncryptionProvider`, `EncryptionSetupResult`, key derivation, session cache |
| `packages/kmdb/pubspec.yaml` | Add **only** pure-Dart `cryptography` (per Q7). **Do NOT** add `cryptography_flutter` or `flutter_secure_storage` here — they are Flutter packages and would break `kmdb`'s and `kmdb_cli`'s pure-Dart `dart test`. |
| `packages/kmdb/lib/src/encryption/dek_cache.dart` (new) | Pure-Dart `DekCache` interface + `InMemoryDekCache` default (per Q3/Q7) |
| New package: `packages/kmdb_flutter/` | `FlutterSecureDekCache implements DekCache` over `flutter_secure_storage`; depends on `cryptography_flutter` for native AES/Argon2id acceleration (per Q7). Mirrors the `kmdb_google_drive`/`kmdb_icloud` opt-in add-on pattern. |
| `packages/kmdb/lib/src/vault/vault_package.dart` + CLI export/dump/import callers | Export path decrypts blobs to plaintext before packaging; import path re-encrypts under destination DEK (per Q5). `VaultPackage` itself stays encryption-agnostic. |
| `packages/kmdb_cli/` | `--passphrase` / `--recovery-code` flags; `init --encrypted`; `encryption change-passphrase` |
| New: `docs/spec/NN_encryption.md` | Spec for the encryption subsystem (take next available number at creation time) |

### Value pipeline extension

The existing pipeline (§5) is:

```
CBOR → Zstd (optional) → [compression flag byte] → KvStore.put
```

The new pipeline:

```
CBOR → Zstd (optional) → [compression flag] → AES-256-GCM → [encryption flag] → KvStore.put
```

The encryption stage wraps the entire post-compression payload (including the
compression flag). The nonce (96-bit random) is prepended to the ciphertext;
the GCM tag (16 bytes) is appended. The `EncryptionProvider` is stateless from
the caller's perspective — it holds the cached DEK internally.

### Key management

Follows the proposal (§4) without change:

- Random 256-bit DEK, wrapped by a KEK derived from the passphrase via
  Argon2id (m=64MB, t=3, p=1, random 256-bit salt).
- Second independent wrapping of the DEK under a recovery-KEK derived from a
  128-bit random recovery entropy via HKDF-SHA256.
- Both wrapped-DEK entries and the Argon2id salt stored as a CBOR blob under
  `enc:blob` in `$meta` (plaintext — the DEK itself is never stored
  unprotected).
- After unlock, the unwrapped DEK is cached via the injected `DekCache` (Q3/Q7).
  The default `InMemoryDekCache` (used by CLI/tests/web — web re-derives per
  session) does not persist; Flutter hosts inject `FlutterSecureDekCache` from
  the new `kmdb_flutter` package, which is backed by `flutter_secure_storage`
  (platform specifics per §4.3 of the proposal). `kmdb` itself never imports
  `flutter_secure_storage`.

### Vault encryption

- SHA-256 content address computed over plaintext (preserving dedup semantics).
- Stored and uploaded blob is ciphertext: `[96-bit nonce][AES-GCM ciphertext][16-byte tag]`.
- `manifest.json` gains an `encrypted: true` flag.
- Random nonces accepted for v1 (minor ciphertext duplication across devices
  for identical plaintext blobs is acceptable; deterministic nonces via
  `HKDF(DEK, sha256)` deferred to future work per proposal §7.2).
- **`.kvlt` export is plaintext (Q5).** Export/dump/backup decrypt blobs before
  packaging; `--import` re-encrypts under the destination DEK. A `.kvlt` file is
  plaintext at rest — protecting it is the user's responsibility (it is a
  decrypted export, not an encrypted backup). Encrypted export is a v1 non-goal.

### Sync impact

Zero changes to `SyncEngine`, the consolidation coordinator, or cloud adapters.
SSTables upload verbatim — but per the **Q4** finding they contain *all*
namespaces' values, including the derived system namespaces `$index:`/`$fts:`/
`$vec:` and `$ver:`/`$vault`, because sync is whole-file with **no** upload-time
namespace filter (the `_syncNamespaces` set is never consulted in `push()`).
Confidentiality therefore depends entirely on the value-level encryption: every
`ValueCodec` call site is encrypted (Q4), so every value byte in every uploaded
SSTable is ciphertext. The `$meta` SSTable containing the wrapped DEK
(`enc:blob`) syncs normally **in plaintext** (the wrapped DEK is not sensitive);
a new device is prompted for the passphrase, unwraps the DEK, and can decrypt
all value SSTables.

### Non-goals (v1)

In-place migration, key rotation, **index/term/embedding *key* confidentiality
(the cloud-leak of `$index:` field-value keys — beyond documentation)**,
multi-unlocker, default-on encryption, WAL file-level encryption, and encrypted
`.kvlt` export (Q5 — packages are plaintext at rest). All deferred per proposal
§2 and §12.

### Local + cloud information leak (documented; Q4-corrected)

Secondary indexes store indexed field values **in their keys** (`$index:`
namespace). The proposal asserted these namespaces are "excluded from sync";
**Q4 disproves that** — sync is whole-file and `sync_engine.dart` performs no
namespace filtering, so `$index:`/`$fts:`/`$vec:` keys ride in the uploaded
SSTables. (The §12 "Namespace-Scoped Sync" filtering claim is a separate
documentation bug; see Q4(c).) Consequences:

- **Values** in every namespace (user, `$index:`, `$fts:`, `$vec:`, `$ver:`,
  `$vault`) are encrypted (Q4) — no value leak, local or cloud.
- **Keys** remain plaintext everywhere (encryption is value-level only). For
  `$index:` the key embeds the indexed field *value*, so indexed field values
  leak as plaintext **both on local disk and in synced SSTables in the cloud**.
  This is a documented, accepted non-goal for v1 (key-level / structural
  confidentiality is out of scope). On local disk this is covered by OS disk
  encryption for Level 2+ (proposal §9.2); in the cloud it is an accepted
  residual leak the threat-model section must state explicitly.
- `$cache` does not currently reach disk or cloud at all — the materialised-view
  cache (§15.3) is unimplemented; the session cache is in-memory only.

---

## Implementation plan

> **Note:** do not begin implementation until this plan reaches `Investigated` status.

### Dependencies

- [x] Resolve Q1 (flag byte layout) — second independent `EncryptionFlag` byte, encrypt-outside-compress
- [x] Resolve Q2 (`$meta` bootstrap sequence) — bootstrap in `KmdbDatabase.open()`; provider threaded through `ValueCodec` call sites, **not** `KvStoreConfig`
- [x] Resolve Q3 (`PlatformIdStore` scope) — deferred; use a minimal encryption-scoped `DekCache` over `flutter_secure_storage`
- [x] Resolve Q4 (per-call encryption contract + do system namespaces reach the sync folder) — system namespaces DO reach the cloud; encrypt every `ValueCodec` call site uniformly; §12 namespace-filter claim is a separate doc bug
- [x] Resolve Q5 (KVLT package encryption) — export decrypts to plaintext; import re-encrypts under destination DEK
- [x] Resolve Q6 (`$vault` refcount encryption) — encrypt (uniform with Q4)
- [x] Resolve Q7 (Flutter dependency boundary) — `DekCache` interface in `kmdb`; `FlutterSecureDekCache` + `cryptography_flutter` in a new `kmdb_flutter` package; only pure-Dart `cryptography` added to `kmdb`

### Phase 1 — Core encryption primitives

- [ ] Add `cryptography` + `cryptography_flutter` + `flutter_secure_storage`
      to `packages/kmdb/pubspec.yaml`
- [ ] Create `packages/kmdb/lib/src/encryption/` package directory
- [ ] Implement `EncryptionProvider` interface (`encrypt` / `decrypt`)
- [ ] Implement `AesGcmEncryptionProvider` (holds cached DEK; 96-bit random
      nonce per call; GCM tag appended)
- [ ] Implement key derivation: Argon2id(passphrase, salt) → KEK,
      AES-GCM-unwrap(KEK, wrappedDek) → DEK
- [ ] Implement recovery code path: HKDF-SHA256(recoveryEntropy) →
      recovery-KEK → AES-GCM-wrap/unwrap DEK
- [ ] Implement `EncryptionConfig` and `EncryptionConfig.create()` factory
      (generates random DEK + salt + recovery entropy; returns
      `EncryptionSetupResult` with recovery code mnemonic)
- [ ] Implement DEK session cache via `flutter_secure_storage`

### Phase 2 — Value pipeline integration

- [ ] Resolve flag byte design (Q1) and update `CompressionFlag` or
      create a new flag type accordingly
- [ ] Extend `ValueCodec.encode` to accept optional `EncryptionProvider`;
      apply after compression
- [ ] Extend `ValueCodec.decode` to detect encryption flag and decrypt
      before decompression
- [ ] Thread the shared `EncryptionProvider?` from `KmdbDatabase` into **every**
      `ValueCodec.encode`/`decode` call site listed in the Investigation table
      (Query Layer, search, versioning, vault). **Do NOT add an
      `encryptionProvider` field to `KvStoreConfig` and do NOT route through
      `KvStoreImpl`** — per the Q2 decision the engine/KvStore layer is untouched.
- [ ] Apply the **resolved Q4 per-call contract**: pass the provider on
      **every** `ValueCodec.encode`/`decode` call site (user docs, `$index:`,
      `$fts:`, `$vec:`, `$ver:`, and `$vault` refcounts — see the Q4 table and
      Q6). There is **no** deliberately-plaintext `ValueCodec` call site; the
      only plaintext path (`enc:blob`/`$meta`) is already off `ValueCodec` via
      `getRawByName`/`putRawByName` (Q2). Reason: sync uploads SSTables whole-file
      with no namespace filter, so derived system-namespace values reach the
      cloud and must be encrypted.
- [ ] Define the `EncryptionError` type (`databaseIsEncrypted`,
      `databaseIsNotEncrypted`, `badCredentials`) and the `isProvisioning`
      discriminator on `EncryptionConfig` (so the four-state table in Q2 can
      branch create vs unlock).
- [ ] Enforce the database-encrypted/not-encrypted invariant on open per the
      Q2 four-state table (presence of `enc:blob` × presence of
      `EncryptionConfig`), including the empty-DB-only guard for provisioning
      (reject `create` config against a DB that already has user namespaces).

### Phase 3 — `$meta` bootstrap

- [ ] Add `getEncryptionBlob` / `putEncryptionBlob` helpers to `MetaStore`
      (CBOR-encoded: salt, wrappedDekPassphrase, wrappedDekRecovery, KDF params)
- [ ] Implement bootstrap sequence in `KmdbDatabase.open()` per Q2 resolution:
      `KvStoreImpl.open()` → read `enc:blob` via `getRawByName` → derive/unwrap
      DEK → build `EncryptionProvider` → **thread the provider into the
      cache/index/FTS/Vec/version/vault collaborators** (NOT `KvStoreConfig`) →
      continue the existing open sequence
- [ ] Ensure provisioning durability: on `create`, write `enc:blob` durably
      (fsync) **before** any encrypted user value can be written — fold blob
      creation entirely within `open()` before the handle is returned (per Q2
      crash-safety note)
- [ ] Handle passphrase-change: unlock with the *current* passphrase/recovery,
      re-derive KEK, re-wrap DEK, write the new `enc:blob` to `$meta` as a single
      atomic `$meta` put (`kmdb encryption change-passphrase`)

### Phase 4 — Vault encryption

- [ ] Encrypt vault blob bytes with `EncryptionProvider` before write to
      `vault/blobs/.../blob`; compute SHA-256 over plaintext
- [ ] Store blob as `[nonce][ciphertext][tag]`; prepend nonce from
      `EncryptionProvider.encrypt` return
- [ ] Decrypt on read before returning to caller (real seam is
      `vault/vault_store.dart` ingest/read, **not** `ValueCodec` — vault blobs
      are content-addressed files written via the vault storage adapter)
- [ ] Add `encrypted: true` flag to vault `manifest.json` (`vault_manifest.dart`)
- [ ] Make `vault_recovery.dart` decrypt before re-verifying SHA-256 (the
      content address is over plaintext, so recovery must decrypt the stored
      ciphertext blob before hashing)
- [ ] Decide and document KVLT package (`vault_package.dart`) behaviour under
      encryption: does export/import carry ciphertext or plaintext blobs? Record
      the decision (or list as an explicit non-goal)

### Phase 5 — CLI support

- [ ] Add `--passphrase` / `--recovery-code` flags + interactive prompt **once**
      in the shared CLI open path (the base `command.dart` / `sync_helpers.dart`
      that all ~30 db-opening commands route through), not per-command; an
      encrypted DB opened without credentials must fail with a clear message,
      not a stack trace
- [ ] Implement `kmdb init --encrypted`: create encrypted database, print
      recovery code
- [ ] Implement `kmdb encryption change-passphrase`: re-wrap DEK under new
      passphrase

### Phase 6 — Spec, tests, and docs

- [ ] Write `docs/spec/NN_encryption.md` (take next available `NN` at
      creation time): algorithm, pipeline format, key management, bootstrap
      sequence, vault integration, platform notes, API reference
- [ ] Update `docs/spec/05_value_encoding.md` to document the extended
      pipeline and new flag byte(s)
- [ ] Update `docs/spec/24_vault.md` to document vault blob encryption and the
      plaintext `.kvlt` export contract (Q5)
- [ ] Correct `docs/spec/12_sync.md` "Namespace-Scoped Sync" (lines ~421–423):
      the claimed upload-time namespace filter does **not** exist in
      `sync_engine.dart`. Either strike the claim (recommended for this plan,
      since encryption no longer relies on namespace exclusion) or file the
      filter as separate work. Update the threat-model wording so it no longer
      asserts system namespaces are excluded from sync (Q4(c)).
- [ ] Update `docs/spec/13_query_api.md` for the `EncryptionConfig` parameter on
      `KmdbDatabase.open()` and the `EncryptionError` cases (the bootstrap and
      provider live in the Query Layer, **not** in `KvStoreConfig` per Q2 — do
      not add encryption fields to §11)
- [ ] Update `docs/spec/99_glossary.md` (DEK, KEK, Argon2id, wrapped DEK,
      recovery code)
- [ ] Unit tests for `EncryptionProvider` (round-trip, wrong key, tampered
      ciphertext, nonce uniqueness across calls)
- [ ] Unit tests for key derivation (known-vector Argon2id output, recovery
      code unwrap)
- [ ] Unit tests for `ValueCodec` with encryption (compress+encrypt,
      encrypt-only, unknown flag rejection, mismatch error)
- [ ] Unit tests for `MetaStore` encryption blob helpers (round-trip,
      missing-blob detection)
- [ ] Unit tests for `KmdbDatabase.open()` encryption bootstrap
      (correct passphrase, wrong passphrase → `EncryptionError`, recovery code
      unlock, encrypted-db-no-config error, unencrypted-db-with-config error)
- [ ] Integration test: write encrypted → flush → reopen → read back
      (verifying SSTable contents are opaque without DEK)
- [ ] **Fault-injection test (`FaultyStorageAdapter`, per CLAUDE.md / 2026-05-22
      review §8):** crash between `enc:blob` provisioning and the first encrypted
      user write — verify no undecryptable value can precede a durable blob
- [ ] Test: opening a non-empty plaintext DB with a `create` config is rejected
      (empty-DB-only provisioning guard)
- [ ] Test: version-history (`$ver:`) values round-trip encrypted; vault refcount
      (`$vault`) values follow the documented Q4 encryption contract
- [ ] Integration test: passphrase change (re-wrap DEK, reopen with new
      passphrase)
- [ ] Vault integration test: ingest blob → read back decrypted; verify
      SHA-256 address matches plaintext
- [ ] Add release checklist entry for manual web-platform verification
      (Argon2id timing in browser, re-derive-per-session behaviour)
- [ ] Ensure ≥90% test coverage on new `encryption/` package directory

---

## Plan review (kmdb-plan-reviewer, 2026-06-17)

**Status: `Questions`.** The cryptographic design is sound and Q1–Q3 are well
resolved. The Q2 resolution independently caught the central architectural fact
— `ValueCodec` is a static codec invoked *above* the KvStore boundary, so
`KvStoreImpl` never touches it and `KvStoreConfig.encryptionProvider` is the
wrong seam (verified: zero `ValueCodec` refs under `lib/src/engine/kvstore/`).
That correction is now reflected in the Investigation table. Three things keep
this short of `Investigated`:

1. **New blocking Q4 (raised here): per-call encryption contract + sync scope.**
   `ValueCodec` is shared by user docs, `$ver:` history, `$vault` refcounts, and
   the index/FTS/Vec source-doc reads, so a global on/off is too coarse. And the
   proposal's "system namespaces are excluded from sync" claim is unverified —
   sync is file-level with no per-namespace upload filter (`sync_engine.dart`).
   If `$fts:`/`$vec:`/`$cache:`/`$index:` ride along in synced SSTables,
   leaving them plaintext leaks to the cloud. This must be confirmed against §12
   and the per-call rule recorded. This is a confidentiality decision, not a nit.

2. **Stale Implementation-plan phases — now fixed in place.** Phases 2/3/4/5/6
   still described the overturned `KvStoreConfig`/`KvStoreImpl` plumbing and a
   vague vault seam; a Sonnet implementer follows the checklist literally, so
   these were traps. I rewrote them to match the Q2 decision (provider threaded
   through `ValueCodec` call sites), named the real vault files
   (`vault_store.dart`, `vault_manifest.dart`, `vault_recovery.dart`,
   `vault_package.dart`), pointed the spec update at §13 not §11, added the
   `EncryptionError`/`isProvisioning` step, the empty-DB provisioning guard, the
   shared CLI open path, the vault-recovery decrypt-before-hash step, and a
   `FaultyStorageAdapter` crash test.

3. **A few decisions still owed** (folded into the phases): KVLT package
   ciphertext-vs-plaintext behaviour; whether `$vault` refcounts are encrypted;
   and the `flutter_secure_storage`/`cryptography_flutter` dependency leaking
   Flutter into the otherwise pure-Dart `kmdb` package (the Q3 `DekCache` seam is
   the right mitigation — keep the Flutter-only impl out of core; confirm
   `kmdb_cli`'s pure-Dart `dart test` still resolves).

Minor notes (non-blocking): spec `31_encryption.md` is the likely next number
and the `NN` placeholder is correctly left unbound per `docs/plans/README.md`;
encryption is a v0.07 roadmap item (no 0.08 drift); `maxValueBytes` is enforced
on post-encoding bytes so the ~29-byte AEAD overhead can tip a boundary document
over 1 MiB — note in the spec.

**To reach `Investigated`:** resolve Q4 (the one remaining design decision) and
the three deferred decisions in (3). Everything else is now spec-level concrete.

## Architect investigation (kmdb-architect, 2026-06-17)

**Status advanced to `Investigated`.** Q4 and the three deferred decisions
(now Q5/Q6/Q7) are resolved with code-grounded findings:

- **Q4(a) — confirmed against code + §12:** system namespaces **do** reach the
  cloud. `SyncEngine.push` uploads SSTables whole-file; `_syncNamespaces` is
  resolved and passed but **never consulted** in `push`/`pull`/consolidation.
  `$index:`/`$fts:`/`$vec:`/`$ver:`/`$vault` all write through the shared
  `WriteBatch`→SSTable path and ride in uploaded files. `$cache` is the lone
  exception (materialised-view cache §15.3 unimplemented; session cache is
  in-memory). **Independent finding:** §12 "Namespace-Scoped Sync" lines 421–423
  claim an upload-time namespace filter that does not exist in the code — a
  documentation bug to fix separately from encryption (either implement the
  filter or strike the claim).
- **Q4(b):** uniform per-call contract — thread the provider through **every**
  `ValueCodec` call site; the only plaintext path (`enc:blob`/`$meta`) is already
  off `ValueCodec` (raw `getRawByName`/`putRawByName`, per Q2), so no call site
  is deliberately skipped.
- **Q5:** `.kvlt` export decrypts to plaintext (the package's `document.json` is
  already plaintext; ciphertext blobs would be incoherent and unusable);
  `--import` re-encrypts under the destination DEK.
- **Q6:** encrypt `$vault` refcounts — uniform with Q4; bootstrap-safe (vault
  recovery runs after provider construction).
- **Q7:** `DekCache` interface + `InMemoryDekCache` live in pure-Dart `kmdb`; the
  `flutter_secure_storage`-backed `FlutterSecureDekCache` and `cryptography_flutter`
  live in a **new `kmdb_flutter` add-on package** (mirroring `kmdb_google_drive`/
  `kmdb_icloud`). Only pure-Dart `cryptography` is added to `kmdb`, preserving the
  pure-Dart `dart test` for `kmdb` and `kmdb_cli`. Conditional export cannot
  express the Flutter boundary (it switches native/web only), so it is the wrong
  tool here.

The "Source files affected" table, Sync impact, Non-goals, Local/cloud leak, Key
management, and Vault-encryption sections are updated accordingly.

**Doc-fix follow-on (separate from this plan):** the §12 namespace-filter claim
must be reconciled with `sync_engine.dart` (no filter exists). Recommend the
architect either implement the upload-time filter or correct §12; either way it
does not block this plan, since the encryption contract no longer relies on
namespace exclusion for confidentiality.

## Summary

_To be completed after implementation._
