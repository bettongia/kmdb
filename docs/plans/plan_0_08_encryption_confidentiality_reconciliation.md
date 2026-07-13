# Encryption confidentiality reconciliation

**Status**: Implementing

**PR link**: —

## Overview

This plan closes the four "Encryption confidentiality reconciliation" gaps
tracked in `docs/roadmap/0_08.md`. All four are already documented as known
limitations in §31's (`docs/spec/31_encryption.md`) "Threat Model &
Confidentiality Boundaries" section — this plan closes them, it does not
discover them for the first time.

**The four gaps:**

1. **Gap 1** — `FtsManager`, `VecManager`, and the three vault-search writers
   write index values as raw CBOR instead of going through an encryption
   primitive, leaving tokenised terms and embedding vectors unencrypted on
   local disk.
2. **Gap 2** — FTS/index/vault namespace names embed the term/value in
   plaintext hex, letting an attacker with local SSTable access enumerate the
   full search vocabulary even after Gap 1 is fixed. Closed with DEK-derived
   HMAC namespace tokens.
3. **Gap 3** — `MetaStore` (`$meta`) writes raw CBOR directly to the engine,
   leaking the namespace registry (collection names), device ID, and
   generation counters to the cloud (`$meta` rides syncable SSTables).
4. **Gap 4** — vault `manifest.json`'s `originalName` field is plaintext JSON
   that syncs to the cloud verbatim.

**Threat model (corrected during review — see Review, Pass 1):** Gap 1 and
Gap 2 only protect against *local disk theft* — every namespace they touch is
`$$`-prefixed and therefore local-only (never synced, per WI-0). Gap 3 and
Gap 4 are the only two gaps in this plan that protect against a
*cloud-provider* reading your data. This distinction shaped the phase
ordering below and a deliberate, user-confirmed decision to keep Gap 2 in
scope despite it being the largest, riskiest, and least cloud-relevant piece
of work here (see Open questions, Q8).

**Key design decisions:**

- **Two encryption primitives, chosen per value shape.** `ValueCodec`
  (existing, `Map<String, dynamic>`-only) for values that are genuinely CBOR
  maps; a new `EncryptionEnvelope.wrap`/`unwrap` helper (factored out of
  WI-10's existing inlined pattern) for everything else — scalars, lists, and
  raw byte blobs, which turns out to be *most* of the values in scope,
  including every single `MetaStore` value. This split emerged during review
  (Pass 3) after the original plan assumed `ValueCodec` applied everywhere.
- **A database-level format-version gate, not a per-value check**, detects
  legacy (pre-this-plan) databases at `open()` and refuses them cleanly. A
  per-value "does this look like a valid flag byte" check was tried and
  rejected during review (Pass 4/5) — it silently misparses common legacy
  values, because CBOR encodes small integers 0/1 as bytes that collide with
  the two valid encryption flag bytes.
- **Breaking format change, no migration path.** Existing databases must be
  recreated once this lands — consistent with the original Phase 12
  encryption precedent. Documented in §31 and the release checklist.

**Phases** (ordered by mechanical complexity, not severity — see
Implementation plan for the full rationale): Phase 0 sets up the shared
`EncryptionEnvelope` primitive and resolves all open questions; Phase 1
closes Gap 1; Phase 2 closes Gap 3; Phase 3 closes Gap 4; Phase 4 closes
Gap 2; Phase 5 updates docs/spec.

**Workflow (see Implementation plan for the full policy):** one branch/
worktree for the whole plan, but each of Phases 1–5 gets its own
checklist-verify → pre-commit → `kmdb-qa` sign-off → commit sequence rather
than one review at the very end — the same reasoning that made this plan's
own review take five focused passes instead of one. One PR at the end,
multiple commits, merged (not squashed) into `main`. A dedicated
`kmdb-architect` spec-alignment pass runs once, after Phase 5, to confirm
§31/§24/§99/the roadmap describe the complete implemented state.

All open questions (Q1–Q8) are resolved. This plan reached `Investigated`
after five review passes with the `kmdb-plan-reviewer` agent — see Review for
the full history of what each pass found and how it was fixed. Each pass
surfaced a genuine, code-grounded defect (a wrong threat model, an
unspecified async design, an impossible migration scenario, a
`ValueCodec`-can't-take-bytes mismatch, a CBOR/flag-byte collision, and a
new-vs-legacy database discrimination gap) — none were bikeshedding, and all
are closed with concrete resolutions in the sections below.

## Problem statement

§31 (`docs/spec/31_encryption.md`) already contains an honest, current "Threat
Model & Confidentiality Boundaries" section (lines 437–639) that documents
five known gaps between encryption's design intent and its implementation.
This plan closes the first four of those documented gaps, recorded for
tracking purposes in `docs/roadmap/0_08.md`:

- **Gap 1** — `FtsManager`, `VecManager`, and the vault-search writers
  (`VaultBm25Writer`, `VaultVecWriter`, `VaultExtractionState`) write index
  values via raw `cbor.encode()` instead of `ValueCodec.encode(encryption:)`,
  leaving tokenised term lists, quantised embedding vectors, and extraction
  metadata unencrypted on local disk.
- **Gap 2** — FTS/index/vault namespace names embed the hex-encoded term or
  indexed value directly in the namespace, which is never encrypted (it's part
  of the SSTable key). An attacker with local SSTable access can enumerate the
  full search vocabulary and indexed field values by scanning namespace names,
  even after Gap 1 is fixed.
- **Gap 3** — `MetaStore` writes raw CBOR directly to the engine, bypassing
  `ValueCodec` entirely. This leaks the namespace registry (collection names),
  device ID, generation counters, and indexed field paths to anywhere the
  containing SSTable travels — including the cloud.
- **Gap 4** — Vault `manifest.json` is plaintext JSON containing
  `originalName`, which travels to the cloud with the synced manifest and is
  not acknowledged anywhere as a plaintext surface for an encrypted database.

**Per-gap threat model (this is the load-bearing correction from plan
review — get this right before reading further):**

- **Gap 1 and Gap 2 are local-disk-at-rest only.** Every namespace they touch
  (`$$fts:`, `$$vec:`, `$$index:`, `$$vault:fts:`, `$$vault:vec:idx:`,
  `$$vault:extract:`) is `$$`-prefixed and therefore local-only —
  `isLocalOnly(ns) => ns.startsWith(r'$$')` (`namespace_codec.dart:148`) — and
  `SyncEngine` skips `.local.sst` files entirely (`sync_engine.dart:245`).
  This is exactly what WI-0's `$`→`$$` rename achieved. The threat these two
  gaps address is **physical theft of (or a backup of) an encrypted
  database's local directory by an adversary who does not hold the
  passphrase** — not a cloud-provider surface. §31's gap 2 already states
  this plainly.
- **Gap 3 (`$meta`, single-`$`) and Gap 4 (`manifest.json`) are genuine
  cloud-provider exposure.** `$meta` rides syncable SSTables and
  `manifest.json` is synced verbatim — these are the only two gaps in this
  plan that a cloud storage provider can actually read.

This plan closes all four gaps before the v1 beta, per the user's explicit
direction to leave no gap in `docs/roadmap/0_08.md`'s "Encryption
confidentiality reconciliation" section unaddressed. This includes Gap 2 even
though — under the corrected threat model above — it is a local-disk-only
concern and the single largest, riskiest piece of work in this plan (a new
HMAC primitive, an index-state format change, and rebuild-on-upgrade
behaviour). **This was surfaced explicitly during plan review and the user
confirmed Gap 2 stays in scope, accepting that risk knowingly** (see Q8).

This plan also folds in a handful of adjacent findings surfaced by grounding
it against the current code (not just the roadmap text, which predates
WI-0/WI-3/WI-10 and contains some now-stale namespace names and claims) via
the `kmdb-architect` agent.

**Relationship to v0.06 vault work:** WI-0 (local-only namespace segregation),
WI-3 (vault search core), and WI-10 (encrypt `extract/` filesystem artifacts)
are all Complete and directly relevant:

- WI-0 renamed `$fts:`/`$vec:`/`$index:` → `$$fts:`/`$$vec:`/`$$index:` and
  `$vfts:`/`$vault:extract:` → `$$vault:fts:`/`$$vault:extract:`, and its own
  text (0_06.md line 100–103) flagged that the Gap 2 HMAC-token rename "also
  touches FtsManager / IndexManager — do in one pass where they overlap." **That
  coordination did not happen** — WI-0 shipped the `$`→`$$` rename only; hex
  terms/values are still emitted verbatim (confirmed at
  `fts_manager.dart:1040`, `index_writer.dart:139`,
  `vault_bm25_writer.dart:152`). Gap 2 is greenfield work, not a WI-0
  follow-up.
- WI-3 introduced the vault-search writers and shipped them with the same raw
  CBOR defect the original Gap 1 audit predicted and flagged for verification.
  Confirmed not fixed (0_08.md's own "Confirmed during WI-10 planning" note).
  All three vault-search writers are therefore in scope for Gap 1 alongside
  `FtsManager`/`VecManager`.
- WI-10 encrypted the three `extract/` **filesystem** artifacts
  (`text.txt`, `chunks_v1.json`, `vectors_*.bin`) — a distinct, already-closed
  surface. This plan does not touch WI-10's work; it closes the parallel gap
  in the **KV values** (`$$vault:fts:`, `$$vault:vec:idx:`,
  `$$vault:extract:`) that WI-10 did not cover.
- **Doc drift found during grounding:** 0_06.md WI-3 states "Vault chunk
  vectors have no KV namespace at all — stored only on the filesystem." This
  is incorrect — `VaultVecWriter.write()` persists quantised SQ8 vectors to
  `$$vault:vec:idx:{sha256}` (the per-chunk vector *index*; the full-precision
  vectors live in `vectors_*.bin` as WI-3 intended, but the SQ8 copy used for
  search is also in the KV store and was missed by the original audit). This
  namespace is added to Gap 1's scope; the 0_06.md and §24 claims are
  corrected as part of this plan's doc updates.

## Open questions

- [x] **Q1 — MetaStore's late encryption-provider binding.** **Resolved
      (user, 2026-07-10): accept the recommendation.** `MetaStore`
      (`engine/kvstore/meta_store.dart`) is constructed at the **engine**
      layer (`const MetaStore(this._engine)`) with no `EncryptionProvider` —
      the provider is derived later, in `KmdbDatabase.open()`, above the
      `KvStore` boundary. Several `$meta` writes (`device_id`, `dirty`,
      `gen:` bumps, namespace registration) are folded into the *same*
      `WriteBatch` as user writes via `appendGenerationCounterBump` /
      `appendNamespaceRegistration` / `appendDirtyFlag`, which execute below
      where the provider currently lives. **Recommendation:** give
      `MetaStore` a late-bound, settable `EncryptionProvider?` that
      `KmdbDatabase.open()` assigns immediately after deriving the provider
      and before the first application-level write is admitted. The
      implementer must trace `KmdbDatabase.open()`'s exact bootstrap sequence
      to confirm no `$meta` write (in particular the very first `device_id`
      write on a brand-new database) happens before that assignment point —
      if one does, either move the assignment earlier or special-case that
      one write. This is the crux of Gap 3 and must be resolved with a code
      read, not assumed, before implementation starts.
- [x] **Q2 — Resolved (reviewer-endorsed, 2026-07-10): exemption stays, no
      change.** Enforced concretely by Phase 2's `enc:blob`-direct-path fix
      (`getEncryptionBlob`/`putEncryptionBlob` call `_engine.get`/`put`
      directly, off the now-encrypting `getRawByName`/`putRawByName`). Does
      `enc:blob` review confirm the exemption stays exactly as
      is?** `getEncryptionBlob`/`putEncryptionBlob` already bypass
      `ValueCodec` via `getRawByName`/`putRawByName` and are the one
      documented, intentional exemption (§31 bootstrap requirement — the
      wrapped DEK cannot be encrypted with itself). Confirm no other code
      path reaches `enc:blob` through the newly-encrypted general `$meta`
      path. **Confirmed during Phase 2 drafting: `getEncryptionBlob`/
      `putEncryptionBlob` currently call `getRawByName`/`putRawByName`
      internally, which Phase 2 is making encrypt by default — this is a
      real conflict, not a hypothetical one.** Resolution (see Phase 2's
      dedicated checklist item): change `getEncryptionBlob`/
      `putEncryptionBlob` to call `_engine.get`/`_engine.put` directly,
      bypassing the named accessors entirely, so `enc:blob` never touches
      the encrypting path regardless of future changes to
      `getRawByName`/`putRawByName`.
- [x] **Q3 — Resolved (reviewer-endorsed, 2026-07-10): leave empty.** Once
      Gap 2 (Phase 4) makes the namespace an HMAC token, the value carries no
      additional information; encrypting a zero-length payload adds ~29 bytes
      of overhead per index entry for no confidentiality benefit. The
      local-only reframing (B1) reinforces this — there is no value-level
      benefit either way. Decided now (not deferred to implementation) so no
      question remains open. Empty `$$index:` value: encrypt anyway or leave
      empty?** (carried over from 0_08.md's own open question.) Secondary index
      entries currently write an empty value (the namespace name is the
      indexed key). Once Gap 2 lands, the namespace itself is an HMAC token,
      so the value carries no additional information either way.
      **Recommendation: leave empty** — encrypting a zero-length payload adds
      29 bytes of GCM overhead across every index entry for no confidentiality
      benefit once Gap 2 ships; only encrypt it if Gap 2 is deferred (in which
      case the plaintext hex value in an unencrypted, un-tokened namespace is
      genuinely still informative and warrants the overhead). Resolve
      concretely once Gap 2's sequencing relative to Gap 3 is locked in during
      implementation.
- [x] **Q4 — Resolved (reviewer-endorsed, 2026-07-10): HKDF sub-key.**
      `info = "kmdb-index-token"`, derived once and cached, via a purpose-built
      method on `EncryptionProvider` (not by widening `AesGcmEncryptionProvider.
      dek` exposure). Sound cryptographic hygiene and reuses the existing HKDF
      machinery at `key_derivation.dart:109`. Gap 2 HMAC key: DEK directly, or
      an HKDF sub-key?** (carried over from 0_08.md.) The architect investigation confirmed
      `key_derivation.dart:109` already uses `Hkdf(hmac: Hmac(Sha256()),
      outputLength: kKekLength)` for the recovery KEK, so the machinery is
      reusable. **Recommendation: HKDF sub-key**, `info = "kmdb-index-token"`,
      derived once and cached — do not let a raw DEK getter be used directly
      for HMAC at call sites. Add a `deriveSubKey(info)` (or a purpose-built
      `indexToken(domain, term)`) method to `EncryptionProvider` rather than
      exposing `AesGcmEncryptionProvider.dek` more broadly than it already is.
- [x] **Q5 — Resolved (reviewer-endorsed, 2026-07-10): rebuild on
      format-version mismatch at `open()`.** Trigger is a code/format-version
      upgrade of an already-encrypted database (persisted `tokenMode`
      discriminator mismatch), mirroring WI-1's model-identity invalidation —
      **not** a runtime encryption toggle (impossible, see Review Pass 1/B5).
      Detection runs after Phase 2's `MetaStore` provider binding, since the
      index state is itself encrypted. Gap 2 migration trigger: what actually
      causes a rebuild?** (carried over from 0_08.md, **reframed per plan
      review** — the original framing was an impossible scenario.) Encryption
      cannot be toggled on an existing database — `KmdbDatabase.open()`
      throws `cannotProvisionNonEmptyDatabase` when user namespaces already
      exist (`kmdb_database.dart:651–658`); a database is either born
      encrypted or never encrypted. So "toggle encryption on an existing DB →
      rebuild" is not a real trigger and must not appear in tests. **The real
      trigger is a software/format-version upgrade of an already-encrypted
      database**: a DB whose `$$fts:`/`$$vec:`/`$$index:` were built by
      pre-Gap-2 code (hex tokens) is reopened under Gap-2 code (HMAC tokens);
      the persisted `tokenMode` discriminator mismatches, and `open()`
      rebuilds — exactly analogous to WI-1's model-identity invalidation
      (`$meta` model version mismatch → automatic `$$vec:` rebuild), which is
      a persisted-format-version mismatch, not a user action.
      **Recommendation: rebuild automatically on this version-mismatch
      detection at `open()`**, consistent with WI-1. Store the discriminator
      (`tokenMode: hex | hmac`) alongside the existing `field`/`status` in
      `FtsIndexState`/`VecIndexState` and the secondary index's `$meta` state
      so `open()` can detect the mismatch the same way WI-1 detects a model
      change. Per the Q1/Gap-3 coupling, this detection can only run *after*
      `MetaStore`'s late-bound `EncryptionProvider` is set, since that index
      state is itself now encrypted (Gap 3) — sequence Phase 4's
      rebuild-detection after Phase 2's provider binding.
- [x] **Q6 — Resolved (user, 2026-07-10): encrypt in place — accept the
      recommendation.** Gap 4: encrypt `originalName` in place, or exclude it from
      `manifest.json` and store it in the encrypted blob payload instead?**
      Encrypting the field in place (a small `ValueCodec`-style envelope
      around just that string, stored in the same JSON) is simpler and keeps
      `manifest.json`'s shape stable; moving it into the blob payload avoids a
      second ciphertext-format decision but complicates every manifest reader
      (including the `vault export` CLI command being planned separately in
      `plan_0_08_vault_file_export.md`, which reads `originalName` for output
      naming). **Recommendation: encrypt in place** — smaller blast radius,
      no cross-plan coordination needed with the vault-export work beyond
      "read the (now possibly-encrypted) field the same way `ValueCodec`
      values are read elsewhere." Confirm this before implementation.
- [x] **Q7 — Resolved (reviewer-recommended out of scope, 2026-07-10; accepted
      per coordinator direction to advance — user may reopen if CLI-credential
      hardening should be pulled in).** These creds live outside the database
      encryption boundary entirely (in `local/`, never synced, never in an
      SSTable), so they do not belong in a plan about database value/namespace
      confidentiality. Documented in §31 as an accepted local-secret-at-rest
      surface; a future CLI-hardening item (OS keychain storage) is the right
      home for a fix. Google Drive OAuth credentials (`kmdb_cli`) — in scope or
      explicitly out of scope?** `remote_config.dart` stores
      `AccessCredentials.toJson()` as plaintext JSON under `local/` (never
      synced, never in an SSTable, outside the DEK's reach by design).
      **Recommendation: explicitly out of scope for this plan** — document it
      in §31 as an accepted local-secret-at-rest surface distinct from the
      database encryption boundary, rather than silently leaving it
      unaddressed. A future CLI-hardening item (OS keychain storage for CLI
      credentials) is the right place to fix it, not this plan.
- [x] **Q8 — Resolved (user, 2026-07-10): keep Gap 2 in this plan.** Raised in
      reviewer feedback: given Gap 1 and Gap 2 are local-disk-at-rest surfaces
      only (the `$$`-prefixed namespaces are local-only and never uploaded —
      confirmed at `namespace_codec.dart:148` and `sync_engine.dart:245`), and
      Gap 2 is the single largest/riskiest change in this plan (new HMAC
      primitive, index-state format change, rebuild-on-version-upgrade
      behaviour), is Gap 2 still in scope for this beta-blocking plan, or does
      it slip post-beta as `docs/roadmap/0_08.md` itself contemplates? The
      reviewer's recommendation was to split Gap 2 into its own follow-up
      plan. **Decision: the user reviewed the corrected local-disk-only threat
      model and chose to keep Gap 2 in this plan** — all four gaps ship
      together, with the larger scope and risk of Phase 4 accepted knowingly
      rather than deferred.

## Investigation

_(Grounded by the `kmdb-architect` agent against `main` as of 2026-07-10 —
all file:line references verified against current code, not the roadmap
text, which predates WI-0/WI-3/WI-10 for some namespace names.)_

### Gap 1 — value encryption

**`FtsManager`** (`packages/kmdb/lib/src/search/lexical/fts_manager.dart`)
already holds `EncryptionProvider? _encryption` and already uses it correctly
to decode *fetched documents* (lines 447, 966, 977) — but never for its own
index values, which go through raw `cbor.encode`/`cbor.decode`:

- Write sites: `_writeBaseEntries`/`_encodeCborInt` (1096, 1292–1293) — TF
  count; `_writeDocInfo` (1113–1121) — `{n, t: [terms]}`, **the core leak: the
  full tokenised term list per document**; `_writeCorpusStats` (1131–1139);
  `_writeOverlayEntry` (1149–1154) — `{term: tf}`, also leaks terms;
  `_writeTombstone` (1163–1167).
- Read sites: `_readCorpusStats` (1182), `_readDocInfoFromBytes` (1227, static
  — called by `_readDocInfo` at 1218 and batch scans), `_decodeOverlayBytes`
  (1260, static), `_decodeCborInt` (1297, static).
- **Implementation wrinkle:** the three static/synchronous decode helpers
  must become async instance methods (or values must be pre-decrypted before
  reaching them), since `ValueCodec.decode` is async and needs the provider.

**`VecManager`** (`packages/kmdb/lib/src/search/semantic/vec_manager.dart`):

- Vectors are raw SQ8 bytes, not even CBOR-wrapped — written via
  `batch.put(...)` and read via `_dequantise` (scan loop ~700–707). This is
  the leak (raw quantised embeddings).
- `_writeCorpusN`/`_readCorpusN` (737–745, 728) — raw CBOR count.
- Document decode is already correct (379, 520, 531).
- **Implementation wrinkle:** encrypting fixed-length SQ8 vectors changes
  their byte length (+ GCM overhead + flag byte). The corruption guard at line
  704 (`entry.value.length != expectedByteLen`) must move to after decryption.

**Vault-search writers** — confirmed wired into KV via
`VaultSearchManager.writeBatchInternal` calls (lines 690/697, 829/836):

- `VaultBm25Writer` (`vault/search/vault_bm25_writer.dart`) — `_encodeCborInt`
  (178–179), `_encodeCorpus` (181–188), `decodeCorpus` (193), `decodeTf`
  (211). Its doc comment (171–177) incorrectly asserts these entries "never
  need compression or encryption at this layer" — must be corrected.
- `VaultVecWriter` (`vault/search/vault_vec_writer.dart`) — `write()`
  (76–87) persists raw SQ8 to `$$vault:vec:idx:{sha256}` (see the doc-drift
  note above).
- `VaultExtractionState.encode()`/decode (`vault/search/
  vault_extraction_state.dart:277`, `283–297`) — raw CBOR, written via
  `VaultSearchManager._writeExtractStatusToBatch` (903–913). This value
  carries `charset`, `script`, `language`, `modelVersion`, `chunkCount`, and
  `error` (which could contain content fragments) — encrypting the value
  closes all of these in one fix.
- **Implementation wrinkle:** `VaultBm25Writer`/`VaultVecWriter` are `static
  const` (`vault_search_manager.dart:149–150`) with synchronous, provider-less
  `write()` methods. `VaultSearchManager` already holds the
  `EncryptionProvider` it uses for WI-10's `writeExtractArtifact`/
  `readExtractArtifact` (fields/methods at 195/232), so the simplest path is
  pre-encrypting each value at the `VaultSearchManager` call site before batch
  assembly, rather than threading the provider into the writer classes
  themselves and making them async.

### Gap 2 — namespace token leakage

Current (post-WI-0) namespace names, corrected against the stale 0_08.md
text:

- Document FTS: `$$fts:{ns}:{field}:{hexTerm}` —
  `fts_manager.dart` `_termNamespace`/`_termToHex` (1033–1044).
- Secondary index: `$$index:{ns}:{path}:{hexValue}` —
  `index_writer.dart` `indexNamespaceForValue` (103–110) +
  `_encodeValueHex` (139–155).
- Vault FTS: `$$vault:fts:{sha256}:{hexTerm}` —
  `vault_bm25_writer.dart` `_termNamespace`/`_termToHex` (127–155) +
  `vault_namespaces.dart` `kVaultFtsPrefix` (42).

HMAC-token design premises (from the 2026-06-21 `kmdb-researcher`
investigation cited in 0_08.md) are all confirmed still valid against current
code:

- Internal key format is opaque/length-prefixed:
  `key_codec.dart:encodeInternalKey` — `[nsLen 1B][ns NB][userKey 16B][hlc
  8B][type 1B]` (147–157). Swapping hex bytes for HMAC bytes is invisible to
  the engine.
- 255-byte namespace cap (`namespace_codec.dart:52`, `kMaxNamespaceBytes`)
  comfortably fits a 16-byte HMAC token (32 hex chars) even appended to a
  64-char sha256 prefix.
- `LsmEngine.scan()` (`lsm_engine.dart:513`, `if (ns != namespace) continue;`)
  does exact-namespace matching only — validates the rejected
  single-namespace-with-key-suffix alternative and confirms the
  namespace-per-term layout must stay as-is.

`EncryptionProvider` (`encryption/encryption_provider.dart`) currently exposes
only `encrypt`/`decrypt` (38, 46); `AesGcmEncryptionProvider.dek` (163) is a
raw getter. Gap 2 needs a new sub-key derivation entry point — see Q4.

HMAC-mode flag home: `FtsIndexState` (`search/lexical/fts_index_state.dart`)
persists `field`+`status` via `toBytes` (97–105) through
`MetaStore.putRawByName` (`fts_manager.dart:1284`) — itself an unencrypted
`$meta` value, so this ties directly into Gap 3. `VecIndexState` and the
secondary index's `$meta` state follow the same shape.

### Gap 3 — MetaStore

`MetaStore` (`engine/kvstore/meta_store.dart`) writes every value via
`_engine.put()` directly, bypassing `ValueCodec`. Confirmed `$meta` entries:

- `namespaces` registry (187–197, 166–177) — **highest priority; leaks every
  user collection name.**
- `gen:{namespace}` generation counters (81–107) — leaks namespace names +
  write activity.
- `device_id` (144–157).
- `dirty` flag (125–139).
- `gc:tombstoneFloor` (297–321).
- `index:{ns}:{path}` index/FTS/Vec state via `getRawByName`/`putRawByName`
  (348–362) — leaks indexed field paths; future home of Gap 2's `tokenMode`
  flag.
- **`enc:blob`** (375, `kEncryptionBlobName`) — must remain unencrypted;
  accessed only via `getEncryptionBlob`/`putEncryptionBlob` (385–400), which
  must keep using the raw path. See Q2.

The architectural blocker is Q1 (late provider binding) — this is the hardest
part of Gap 3 and must be resolved with a bootstrap-sequence read before
coding starts, not assumed.

### Gap 4 — vault manifest

`VaultManifest` (`vault/vault_manifest.dart`) fields (`toJson`, 124–133):
`schemaVersion`, `sha256`, `size`, `crc32c`, `mediaType`, `originalName`,
`createdAt`, optional `encrypted`.

- `originalName` (98) — read/written only through `toJson`/`fromJson`
  (124/148) and set at ingest. Scope is contained to this class + its ingest
  call site + the `vault export` CLI command being planned separately (must
  coordinate — see Q6).
- `sha256` over plaintext bytes is intentional (dedup guarantee) — document,
  do not change.
- `mediaType`/`size` are accepted-but-must-be-acknowledged: sync routing and
  dedup logic depend on them being readable without decryption. Document as
  plaintext surfaces in §31 rather than attempting to close them.

### Additional surfaces reviewed (the "no stone unturned" pass)

**Already covered, no action needed:**

- `$vault:docref:{sha256}` — synced, single-`$`, but **already** encrypted via
  `ValueCodec.encode(encryption:)` (`vault_ref_interceptor.dart:162–168`).
- `$vault:{sha256}` ref counts — encrypted (`vault_ref_count.dart:110`).
- `extract/` filesystem artifacts (`text.txt`, `chunks_v1.json`,
  `vectors_*.bin`) — encrypted by WI-10.

**Accepted, documented limitations (metadata only, no content — matches §31's
existing "gaps" framing, just needs the list kept current):**

- `.consolidation-lease` (`consolidation_coordinator.dart:120–136`) — holder +
  epoch JSON.
- `.hwm` highwater files (`highwater.dart:58–178`) — device ID + timing.
- SSTable filenames, WAL, UUIDv7 key timestamps — already documented in §31.
- Collection schemas (§25) — validated in-memory at `open()` time; no
  persisted plaintext schema namespace found. Not a current gap; worth a
  one-line note if a future change persists schemas to KV.

**Genuinely out of scope for this plan (documented, not fixed here):**

- Google Drive OAuth credentials in `kmdb_cli`'s `local/` config — see Q7.

## Implementation plan

**Ordering axis.** Phases are ordered by *mechanical complexity and dependency
depth*, not by which gap is most severe or which reaches the cloud — those are
different axes and they disagree here. On a content-severity axis, Gap 1 is
worst (it leaks actual document content — tokenised terms, vectors). On a
cloud-confidentiality axis, Gap 1 and Gap 2 are actually the *least* urgent,
since both are local-disk-only (see the threat model above) — Gap 3 and Gap 4
are the only phases that reduce real cloud-provider exposure. The chosen order
(Gap 1, then Gap 3, then Gap 4, then Gap 2) is the mechanical-complexity axis:
Gap 1 is a targeted, no-format-change value-encoding fix; Gap 3 adds one new
architectural seam (late-bound provider on `MetaStore`); Gap 4 is a small,
contained field change; Gap 2 is the largest, least mechanical change (new
crypto primitive, index-state format change, rebuild-on-upgrade behaviour) and
is deliberately sequenced last regardless of its cloud-relevance ranking. Each
phase should land as its own reviewable unit of work (commit/PR-sized), but
this is one tracked plan.

**Branch, commit, and review workflow (given the stakes of this plan —
crash-recovery-critical paths and a breaking, unmigrated format change —
review at a finer grain than usual).** All work happens on one dated
branch/worktree per the standard `kmdb-plan-implement` process. Each of
Phases 1–5 below (Phase 0 is design-only and is already fully resolved — see
its checkboxes — so it has no commit of its own) ends with its own
**checklist-verify → pre-commit → QA sign-off → commit** sequence, spelled
out at the end of that phase's checklist. This mirrors why this plan itself
needed five review passes to reach `Investigated`: a focused reviewer working
on one bounded slice catches things a single end-of-everything pass misses,
because by then the slice is buried under later, larger changes. The same
logic applies at implementation time.

- **One commit per phase.** Each phase's commit should be self-contained and
  buildable/testable on its own (this is also why the phases are already
  ordered by dependency — Phase 4 depends on Phase 2's provider binding, for
  example, so it must come after).
- **Do not commit with unchecked boxes.** Every task/step under a phase must
  be checked off in the plan file (in the worktree copy) *before* that
  phase's commit — the checklist is the source of truth for what shipped in
  that commit, not an after-the-fact summary. Per `docs/plans/README.md`,
  check items off immediately as they're done, not in a batch at the end.
- **Per-phase `kmdb-qa` sign-off**, not deferred to one pass at the end of
  all five phases — catches issues while the diff is still small enough to
  review thoroughly (see the rationale above).
- **One PR, multiple commits, merged (not squashed) to `main`** at the end —
  the commit history should mirror the plan's phase structure for future
  `git bisect`/review, not collapse it.
- **A dedicated `kmdb-architect` spec-alignment pass at the very end**, after
  Phase 5's spec/doc updates land, confirming §31/§24/§99/the roadmap
  accurately describe the *complete* implemented state (all four gaps, not
  just Phase 5's own diff in isolation) — complementary to `kmdb-qa`'s
  code-quality lens, and consistent with `kmdb-architect` being the
  authoritative agent for `docs/spec/` per CLAUDE.md. See the Final step
  section below.

### Phase 0 — Resolve open questions, and the shared encryption primitive (B7)

- [x] Resolve Q1 by reading `KmdbDatabase.open()`'s exact bootstrap sequence
      and confirming (or adjusting) the late-provider-binding design for
      `MetaStore`. (Resolved — user accepted the late-bound-setter design; the
      bootstrap-sequence read is now a Phase 2 implementation step, not an open
      question.)
- [x] Resolve Q2–Q8 per the recommendations above, or record a different
      decision with rationale. (All resolved — Q1/Q6/Q8 by the user; Q2–Q5
      reviewer-endorsed; Q7 reviewer-recommended-out-of-scope. See the Open
      questions section for each recorded decision.)

**B7 — `ValueCodec` is `Map<String, dynamic>`-only (`value_codec.dart:92/140`)
and does not apply mechanically to most of this plan's values.** Verified
directly against the write sites: the only genuinely `Map`-shaped values in
scope are `FtsManager._writeDocInfo` (`{n, t: […]}`), `_writeCorpusStats`
(`{n, totalTokens}`), `_writeOverlayEntry` (`{term: tf}`), `VecManager.
_writeCorpusN` (`{n}`), `VaultBm25Writer._encodeCorpus` (`{n, totalTokens}`,
currently built as a raw `CborMap` — trivially adaptable to a plain
`Map<String, dynamic>` for `ValueCodec`), and `VaultExtractionState.encode()`
(already built from `toMap()`, a `Map<String, dynamic>`). Every other value
this plan touches is a scalar or an opaque byte blob: the FTS/vault TF ints
(`_encodeCborInt` in both `fts_manager.dart` and `vault_bm25_writer.dart`),
the FTS tombstone sentinel string, `VecManager`'s raw fixed-length SQ8
vectors, and — in `MetaStore` — *every single Gap 3 value*: the generation
counter (`uint64`), `device_id` (raw string bytes), the `dirty` flag (`[1]`),
`gc:tombstoneFloor` (an `Hlc`), the `namespaces` registry (a CBOR *list*, not
a map), and the six distinct opaque state blobs that flow through
`getRawByName`/`putRawByName` (`IndexManager._encodeState`,
`FtsIndexState.toBytes`, `VecIndexState`, `SchemaManager`'s two encoders,
`VersionManager`'s encoder — flipping `getRawByName`/`putRawByName` to encrypt
by default touches all six, not just the `index:{ns}:{path}` entry the
Investigation section names).

**Decision: a per-value-shape split**, using two primitives rather than
forcing everything through `ValueCodec` (which would require wrapping every
scalar in a throwaway `{'v': …}` map — legitimate for small values, but
explicitly rejected for `VecManager`'s fixed-length SQ8 vectors, since a CBOR
map wrapper defeats the fixed-byte-length corruption-guard reasoning already
flagged for that write site):

1. **Map-shaped values** → `ValueCodec.encode`/`decode` directly, no
   wrapping: `_writeDocInfo`, `_writeCorpusStats`, `_writeOverlayEntry`,
   `_writeCorpusN`, `_encodeCorpus` (adapt from `CborMap` to
   `Map<String, dynamic>`), `VaultExtractionState.encode()`/`decode()`.
2. **Scalar / opaque-byte-blob values** → a new shared
   `EncryptionEnvelope.wrap(Uint8List, EncryptionProvider?) → Future<Uint8List>`
   / `unwrap(Uint8List, EncryptionProvider?) → Future<Uint8List>` helper,
   added under `lib/src/encryption/` (alongside `encryption_flag.dart`/
   `encryption_provider.dart` — **not** `lib/src/encoding/`, since this
   primitive has nothing to do with `ValueCodec`'s CBOR/compression pipeline
   and belongs with the other encryption-layer primitives). This factors out
   the `[EncryptionFlag byte][nonce‖ciphertext‖tag]` /
   `[EncryptionFlag.none byte][plaintext]` pattern that `VaultSearchManager.
   writeExtractArtifact`/`readExtractArtifact` (WI-10, lines ~195/239)
   currently inlines — **refactor WI-10's methods to call the new shared
   helper** instead of duplicating the pattern, per CLAUDE.md's "prefer
   existing primitives over re-rolling them." Applies to: every scalar/int
   TF value, the FTS tombstone sentinel, `VecManager`'s raw SQ8 vectors, and
   **all** of `MetaStore`'s Gap 3 values (which means `MetaStore` needs no
   `ValueCodec`/`encoding`-layer import at all — it only needs
   `EncryptionEnvelope` from `encryption/`, a package it already effectively
   depends on via `encryption_blob.dart`. **This supersedes and simplifies
   the original B4 answer** — the "does `MetaStore` become the first
   engine→encoding importer?" question dissolves, because `MetaStore` never
   needs `ValueCodec` in the first place).

**`EncryptionEnvelope` wire format (edge cases, specified per review):**

- `wrap(bytes, null)` (no provider) → `[EncryptionFlag.none (0x00)][bytes]` —
  flag-prefixed **plaintext**, mirroring both WI-10's `writeExtractArtifact`
  and `ValueCodec.encode(..., encryption: null)`. Keeping the flag byte even
  when plaintext is what makes the two primitives wire-consistent.
- `wrap(bytes, provider)` → `[EncryptionFlag.aesGcm (0x01)][nonce‖ciphertext‖tag]`.
- `wrap` of a zero-length payload is valid and round-trips (relevant if Q3
  ever encrypts an empty `$$index:` value) — the flag byte alone still makes
  a 1-byte, self-describing frame.
- `unwrap` of a `0x01` (encrypted) value when `encryption == null` throws
  (matching WI-10's existing `StateError` behaviour) — a database opened
  without a key must not silently return ciphertext as if it were plaintext.

### Phase 1 — Gap 1: encrypt FTS/Vec/vault-search values

Per Phase 0's B7 split: `ValueCodec` for map-shaped values, the new
`EncryptionEnvelope` helper for scalars/raw bytes.

- [x] Add `EncryptionEnvelope.wrap`/`unwrap` under `lib/src/encryption/`
      (see Phase 0/B7); refactor `VaultSearchManager.writeExtractArtifact`/
      `readExtractArtifact` (WI-10) to use it instead of their inlined
      copy of the same pattern. Done:
      `packages/kmdb/lib/src/encryption/encryption_envelope.dart` +
      refactor; regression-tested by the pre-existing
      `vault_extract_artifact_codec_test.dart` (unchanged, all 8 pass) plus
      a new dedicated `encryption_envelope_test.dart` (12 tests).
- [x] `FtsManager`: `_writeDocInfo`, `_writeCorpusStats`, `_writeOverlayEntry`
      (and their read counterparts `_readDocInfoFromBytes`,
      `_readCorpusStats`, `_decodeOverlayBytes`) → `ValueCodec.encode/decode
      (encryption: _encryption)` (map-shaped). `_writeBaseEntries`/
      `_encodeCborInt` (TF ints) and `_writeTombstone` (sentinel string) →
      `EncryptionEnvelope.wrap/unwrap` (scalar), with `_decodeCborInt`
      updated to match. Convert the static/sync decode helpers to async
      instance methods as needed either way, since both primitives are async.
      **Implementation note (deviation, recorded per the workflow policy):**
      `_writeOverlayEntry` and `_writeTombstone` share one namespace/key
      slot, and a reader cannot know in advance which shape (map vs.
      tombstone string) a given entry holds — mixing `ValueCodec` (which adds
      an extra `CompressionFlag` byte) and `EncryptionEnvelope` across that
      shared slot makes the plaintext framing ambiguous on read. Resolved by
      keeping both writers' existing raw-CBOR encoding (unchanged,
      self-describing via `CborString`/`CborMap` type-tagging) and applying
      only the outer `EncryptionEnvelope` layer uniformly to the overlay
      namespace — see the doc comment on `_writeOverlayEntry` in
      `fts_manager.dart` for the full rationale. `_writeDocInfo`/
      `_writeCorpusStats` are unaffected (their namespaces are not shared
      with any other shape) and route through `ValueCodec` exactly as
      specified.
- [x] `VecManager`: `_writeCorpusN`/`_readCorpusN` (`{n}`) →
      `ValueCodec.encode/decode` (map-shaped). The raw SQ8 vector bytes →
      `EncryptionEnvelope.wrap/unwrap` (scalar — deliberately **not**
      `ValueCodec`, to avoid a CBOR-map wrapper interfering with the
      fixed-length corruption guard). Move the length-corruption guard
      (`entry.value.length != expectedByteLen`) to run after decryption.
      Done — the guard now runs on the unwrapped bytes in `_scoreField`'s
      both read paths (targeted lookup and full scan).
- [x] `VaultSearchManager`: pre-wrap/unwrap values for `VaultBm25Writer`/
      `VaultVecWriter` at the call site (using the provider it already
      holds) before/after `writeBatchInternal`/scan reads, rather than
      threading the provider into the (currently `const`) writer classes.
      `VaultBm25Writer._encodeCorpus` (`{n, totalTokens}`) → adapt from its
      current `CborMap` construction to a plain `Map<String, dynamic>` and
      route through `ValueCodec` (map-shaped); `_encodeCborInt` (per-chunk
      TF) → `EncryptionEnvelope` (scalar). `VaultVecWriter`'s raw SQ8 bytes
      → `EncryptionEnvelope` (scalar, same reasoning as `VecManager`).
      **Implementation note (deviation, recorded per the workflow policy):**
      implemented via a `_wrapWriterEntries` helper that runs the writer
      against a throwaway `WriteBatch` and re-emits every entry (including
      the corpus sentinel) wrapped uniformly with `EncryptionEnvelope`,
      rather than splitting the corpus sentinel out through `ValueCodec` as
      literally specified — since `VaultBm25Writer`/`VaultVecWriter` never
      construct a `Map<String, dynamic>` in the first place (they build raw
      CBOR directly, by design, per this same checklist item's "keep the
      writers unaware of encryption" constraint), routing just the corpus
      sentinel through `ValueCodec` would mean decoding the writer's raw
      CBOR and re-encoding it as a `Map` purely for wire-format uniformity,
      with no confidentiality benefit (identical AES-GCM strength either
      way). See `_wrapWriterEntries`'s doc comment in
      `vault_search_manager.dart` for the full rationale — this parallels
      the `FtsManager` overlay-namespace deviation above. `VaultSearcher`'s
      read paths (`unwrapIndexValue`, exposed on `VaultSearchManager` since
      Dart privacy is per-file) were updated to match.
- [x] `VaultExtractionState.encode()`/`decode()`: already built from/to a
      `Map<String, dynamic>` (`toMap()`) — route through `ValueCodec`
      directly (map-shaped), called from `VaultSearchManager.
      _writeExtractStatusToBatch` and its read counterpart. Done — `encode`/
      `decode` now take an optional `EncryptionProvider?` and are
      `Future`-returning (`decode` is a `static` method, not a `factory`
      constructor, since Dart forbids async factory constructors); the
      now-unused hand-rolled CBOR helpers (`_mapToCbor`/`_valueToCbor`/
      `_cborToMap`/`_cborToValue`) were deleted rather than left dead.
- [x] Correct the incorrect "never needs encryption at this layer" doc comment
      in `vault_bm25_writer.dart` (171–177), and the equivalent claim in
      `vault_extraction_state.dart`'s `encode()` doc comment. Done, plus an
      added "Encryption layering" doc section on both `VaultBm25Writer` and
      `VaultVecWriter` clarifying the raw-vs-wrapped byte distinction.
- [x] Add `$$vault:vec:idx:` to the set of namespaces §31 lists as
      value-encrypted; correct the WI-3 "no KV namespace" claim in 0_06.md and
      §24. Done: `docs/roadmap/0_06.md`'s false "vault chunk vectors have no
      KV namespace" claim corrected; §31's gap 1 section extended to name
      the vault-search writers/namespaces (including `$$vault:vec:idx:`) and
      records a Phase 1 progress note (full "resolved" rewrite is Phase 5's
      job, once all four gaps have landed). §24 was checked and does not
      contain the false claim (only 0_06.md did) — no change needed there;
      §24's "see §32" pointer to the already-accurate
      `docs/spec/32_vault_search.md` namespace table was verified correct.
- [x] Tests: round-trip encrypted write/read for each modified write site
      (both primitives); confirm a **freshly created** unencrypted database
      round-trips correctly through the new framing and produces identical
      query results (**not** "byte-for-byte unchanged" — under this design
      an unencrypted database's values move from bare `cbor.encode` to
      flag-prefixed framing, which changes the on-disk bytes even with no
      provider; this is the format break B8/B9 own, so the pre-plan-format
      claim is false and must not appear as a test target); confirm the SQ8
      corruption guard still catches genuine corruption post-decryption;
      confirm existing FTS/vector query results are unchanged with
      encryption on (search correctness, not just storage format); confirm
      `writeExtractArtifact`/`readExtractArtifact` behave identically
      before/after the `EncryptionEnvelope` refactor (regression test, not
      just new coverage). Done — `vec_manager_test.dart`'s "384-byte" test
      updated to the new `384 + 1` on-disk length with an explanatory
      comment (the concrete instance of the byte-format-change note above);
      full `test/vault/`, `test/search/`, and `test/encryption/` suites pass
      (2,329 tests across the whole `kmdb` package, 12 e2e skipped).

**Phase 1 close-out (see the workflow policy above):**

- [x] Verify every task/step checkbox above is checked off — do not proceed
      to commit with any left unchecked.
- [x] Run `make pre_commit` (format, analyze, license_check, scoped tests).
      Green: format_check, analyze (zero issues across the whole workspace),
      license_check, and `melos pre_commit_test` (2,329 tests, 12 e2e
      skipped) all passed.
- [x] Hand off to `kmdb-qa` for sign-off on Phase 1's diff specifically
      (`EncryptionEnvelope`, `FtsManager`, `VecManager`,
      `VaultSearchManager`/writers, `VaultExtractionState`, and the
      `writeExtractArtifact`/`readExtractArtifact` refactor). Resolve every
      blocking item before committing.
      **Signed off (2026-07-11), run by the coordinator session (this
      `kmdb-plan-implement` session has no Agent/Task tool — see
      `.claude/agent-memory/kmdb-plan-implement/feedback_no_agent_tool.md`).
      No blocking issues.** Both documented deviations (`FtsManager`'s
      overlay/tombstone uniform `EncryptionEnvelope` wrapping;
      `VaultSearchManager`'s `_wrapWriterEntries` helper) were independently
      judged sound engineering matching the plan's real intent (one
      confidentiality primitive per shared namespace), not deviations
      needing correction. The `VecManager` SQ8 post-decryption corruption
      guard was verified correct in both the targeted-lookup and full-scan
      read paths. All dimensions passed: fidelity, spec alignment, doc
      comments, test coverage/pass status, formatting, analysis, code
      quality. Two **non-blocking** notes for a later phase/follow-up (not
      addressed in Phase 1): (a) no test currently seeds a
      genuinely-corrupted *encrypted* SQ8 vector and asserts it's skipped at
      query time (unit-level `EncryptionEnvelope` coverage is strong, but
      there's no full encrypted-index-search integration test for this
      corruption path); (b) Phase 5's eventual §31 "gap resolved" rewrite
      should route through `kmdb-architect` rather than being authored
      inline — already the plan's stated approach, reconfirmed.
- [x] Commit Phase 1 on the plan's branch.
      **`kmdb-pre-commit`: PASS (2026-07-11, coordinator session).**
      format_check clean (456 files), analyze clean (0 issues across all 7
      packages), license_check clean (both new files' headers verified
      byte-for-byte against `header_template.txt`), `pre_commit_test` 2,329
      passed / 0 failed / 12 skipped (expected e2e skips). One transient
      sandbox note (Dart telemetry config write on first run, unrelated to
      this plan's code) — re-run was clean.

### Phase 2 — Gap 3: encrypt MetaStore values

**Design decisions specified up front (per plan review B3/B4 — these are real
architectural choices, not mechanical edits, and must not be left for the
implementer to improvise):**

- **B3 — async ripple through `WriteBatch` assembly (corrected during
  re-review, B6).** The original version of this decision incorrectly
  asserted that `appendGenerationCounterBump`, `appendNamespaceRegistration`,
  and `appendDirtyFlag` are all synchronous. Verified against
  `meta_store.dart`: **`appendGenerationCounterBump` (line 99) and
  `appendNamespaceRegistration` (line 210) are already `Future`-returning**
  — both do an internal read-modify-write (read the current counter/list,
  compute the next value, `batch.put` it) and the caller never sees the
  value being written, so "pre-encrypt at the call site" is not just
  unnecessary but impossible for these two. Only **`appendDirtyFlag` (line
  233)** and **`appendTombstoneFloorAdvance` (line 334)** are genuinely
  synchronous `void` methods. `appendTombstoneFloorAdvance` has no
  production call site today (`LsmEngine._compactAll` calls
  `setTombstoneFloor` directly per its own doc comment; it's exercised only
  by `meta_store_test.dart:368`).

  **Chosen approach: encrypt in place inside the already-async helpers.**
  `appendGenerationCounterBump` and `appendNamespaceRegistration` gain an
  internal `await EncryptionEnvelope.wrap(..., _encryption)` before
  their existing `batch.put` call (per B7, `EncryptionEnvelope`, not
  `ValueCodec` — these values are scalars/a list, not maps) — no
  `WriteBatch` API change, no ripple,
  since these methods are already `Future`-returning and their sole
  productive call site (`kv_store_impl.dart:371/375/510/515/516`) already
  `await`s them alongside sibling async meta calls in the same batch-build
  function. For the two `void` helpers: **convert `appendDirtyFlag` to
  `Future<void>` and encrypt its value too**, for uniformity with every
  other `$meta` entry (the call site at `kv_store_impl.dart:371`/`510`
  already sits in an `async` function awaiting sibling calls, so adding one
  more `await` is a one-line change, not an API ripple). **Leave
  `appendTombstoneFloorAdvance` synchronous and unencrypted** — it has no
  production caller to update, and wiring encryption into unused code
  violates CLAUDE.md's "do not leave dead or unreachable code behind"
  principle in spirit; if/when it gains a real call site, encrypt it then
  using the same pattern as `appendDirtyFlag`. `getTombstoneFloor`/
  `setTombstoneFloor` (the standalone, actually-used variant) **should**
  encrypt, since Gap 3 explicitly names "HLC timestamps" as in scope — this
  is a separate call path from the unused batch variant and must not be
  skipped.
- **B4 — layer dependency, superseded by B7.** The original version of this
  decision chose `ValueCodec.encode`/`decode` for all `MetaStore` values. That
  is **no longer correct** — Phase 0's B7 finding established that every
  single Gap 3 value in `MetaStore` is scalar or opaque-byte-blob shaped
  (generation counter, `device_id`, `dirty`, `gc:tombstoneFloor`, the
  `namespaces` *list*, and the six blobs behind `getRawByName`/
  `putRawByName`) — none of them are `Map<String, dynamic>`, so `ValueCodec`
  does not mechanically apply. **Chosen approach: `EncryptionEnvelope.wrap`/
  `unwrap` (see Phase 0/B7) for every Gap 3 value.** This has a useful
  side-effect: `MetaStore` never imports `ValueCodec`/`lib/src/encoding/` at
  all, so the original "first engine→encoding importer" question dissolves —
  `EncryptionEnvelope` lives in `lib/src/encryption/`, a layer `MetaStore`
  already depends on via `encryption_blob.dart`.

Implementation:

- [x] Implement the late-bound `EncryptionProvider?` on `MetaStore` per the
      Q1 resolution; wire `KmdbDatabase.open()` to assign it at the correct
      point in the bootstrap sequence (before the first application-level
      write is admitted; verify the very first `device_id` write on a
      brand-new database is not written before this point). Done —
      `MetaStore.encryption` (mutable field, `const` removed from the
      constructor); `KmdbDatabase.open()` assigns it immediately after
      `_runEncryptionBootstrap` returns, before any other collaborator is
      constructed. Traced the bootstrap: the only `$meta` activity before
      that point is `_runEncryptionBootstrap`'s own `enc:blob` read/write,
      which is exempt (raw path, Q2) — so there is no earlier `$meta` write
      this assignment could miss. One additional early-read hazard was found
      and fixed during implementation: `KvStoreImpl.open()` calls
      `meta.getDirtyFlag()` *before* `KmdbDatabase.open()` can assign a
      provider (it runs one layer down, inside `KvStoreImpl.open()` itself);
      `getDirtyFlag()` was changed to a presence-only check (no
      `EncryptionEnvelope.unwrap` needed — `setDirty`/`clearDirty`'s own
      write/delete semantics make presence alone sufficient) so it is safe
      to call at that point regardless of encryption state. Verified via the
      Bootstrap ordering (Q1) test group in
      `test/engine/meta_store_encryption_test.dart` (device_id's *first*
      write confirmed encrypted).
- [x] Route `namespaces` registry (`registerNamespace`/
      `appendNamespaceRegistration`/`getNamespaces`), `gen:{namespace}`
      counters (`incrementGenerationCounter`/`appendGenerationCounterBump`/
      `getGenerationCounter`), `device_id` (`putDeviceId`/`getDeviceId`),
      `dirty` (`setDirty`/`clearDirty`/`appendDirtyFlag`/`getDirtyFlag`),
      `gc:tombstoneFloor` (`setTombstoneFloor`/`getTombstoneFloor` — the
      used standalone path; **not** the currently-uncalled
      `appendTombstoneFloorAdvance`, per the B3 decision above), and
      `index:{ns}:{path}` state (`getRawByName`/`putRawByName` — this also
      covers the five other consumers of these generic accessors:
      `IndexManager`, `FtsIndexState`, `VecIndexState`, `SchemaManager`
      (two encoders), `VersionManager`, per B7's blast-radius note) through
      **`EncryptionEnvelope.wrap`/`unwrap`** (not `ValueCodec` — see B4/B7
      above), encrypting in place inside each helper per the B3 decision
      above. Done exactly as specified — see `meta_store.dart`. All six
      `getRawByName`/`putRawByName` consumers get encryption "for free"
      (verified: their own test suites — `IndexManager`, `FtsManager`,
      `VecManager`, `SchemaManager`, `VersionManager` — all still pass with
      no changes needed on their side).
- [x] **Conflict to resolve (found while drafting this phase, not by the
      reviewer): `getEncryptionBlob`/`putEncryptionBlob` currently call
      `getRawByName`/`putRawByName` internally** (`meta_store.dart:386`,
      `:400`) — the same two generic accessors the bullet above just made
      encrypt by default. Left as-is, encrypting `getRawByName`/
      `putRawByName` would silently break the `enc:blob` exemption Q2
      protects. Fix: change `getEncryptionBlob`/`putEncryptionBlob` to call
      `_engine.get`/`_engine.put` directly (bypassing the now-encrypting
      named accessors) instead of going through `getRawByName`/
      `putRawByName`. This keeps `enc:blob` on a genuinely separate raw path
      rather than depending on a shared method staying unencrypted by
      accident. Done — both now call `_engine.get`/`_engine.put` directly.
- [x] **B8/B9 — migration stance (breaking format change) and its
      database-level enforcement gate.** Routing existing `$meta`/
      index-state/schema/version values through `EncryptionEnvelope` changes
      their on-disk bytes even when encryption is off (the envelope still
      prepends a flag byte). A database created by pre-this-plan code stores
      these as bare CBOR with no leading flag byte; the new read path
      expects one. **Decision: pre-v1-beta breaking format change — existing
      databases are not migrated and must be recreated**, consistent with
      the Phase 12 encryption precedent (no in-place migration path). This
      is acceptable this far before beta and must be written down (a note
      here, in §31, and in the release checklist — see Phase 5) rather than
      left implicit.
      **B9 correction (per review): a per-value flag check is NOT a safe way
      to detect a legacy value and must not be used.** The original design
      relied on `EncryptionFlag.fromByte` throwing on an unrecognised leading
      byte to catch legacy reads. This does not work: `EncryptionFlag` is
      `none(0x00)`/`aesGcm(0x01)`, and CBOR (RFC 8949 §3) encodes unsigned
      integers 0–23 as a single byte equal to the value — so a legacy bare
      generation counter of `0` is exactly the byte `0x00` and `1` is exactly
      `0x01`, both valid flags. `fromByte` will **not** throw for these; it
      will silently misparse the counter as a flag and return corrupt data.
      Generation counters of 0/1 are the most common values in the store
      (every freshly-registered namespace starts there), and the raw `dirty`
      flag byte (`[0x01]`) collides too — only `device_id` (ASCII hex, never
      a valid flag byte) happens to fail safe, which is why a device_id-only
      test would have missed this.
      **Fix: gate the format break at the database level, once, at `open()`
      — not per value.** Add a `$meta` format-version marker (a new,
      previously-nonexistent key, read/written via `_engine.get`/`put`
      directly, analogous to `enc:blob`'s raw-path treatment, so there is no
      chicken-and-egg problem reading the very marker that decides whether
      framing applies) whose **absence** unambiguously means "pre-this-plan
      (legacy) database." `KmdbDatabase.open()` checks this marker **before**
      any `$meta`/index/FTS/Vec/vault value is read through
      `EncryptionEnvelope.unwrap`/`ValueCodec.decode`; if absent, refuse to
      open with a clear, actionable error directing the user to recreate the
      database (matching the "no migration" stance) rather than attempting
      any per-value read. This is a standard version-gate, analogous to the
      Manifest version and WI-1's model-identity check, and is what actually
      makes the "recreate the DB" stance safe and enforceable — a per-value
      heuristic provably misfires on the commonest values, as shown above.
      **New-vs-legacy discrimination (must be specified — "absence ⇒ legacy"
      is not literally correct, because a brand-new database also has no marker
      until `open()` writes it).** The marker is written **exactly once, at
      initial database creation** — detected by the same "brand-new database"
      signal the recovery sequence (§17) already uses: no existing `CURRENT`/
      manifest on disk. The three-way rule `open()` must implement is:
      (a) marker present ⇒ current format, proceed;
      (b) marker absent **and** the database already has persisted state
      (`CURRENT`/manifest/SSTables present) ⇒ legacy ⇒ refuse cleanly;
      (c) marker absent **and** no persisted state (fresh directory) ⇒
      brand-new database ⇒ write the marker (raw path) as part of creation,
      then proceed. Implementing (b)'s refuse without the (c) carve-out would
      break new-database creation; conversely writing the marker
      unconditionally whenever it is missing would silently re-admit legacy
      databases and defeat this entire gate (reintroducing the B9 silent-
      corruption risk). This empty-vs-non-empty check mirrors the existing
      `cannotProvisionNonEmptyDatabase` logic (`kmdb_database.dart:651–658`),
      which already distinguishes a fresh database from a populated one.
      (The marker lives in syncable `$meta`; a mixed-version device fleet is
      out of scope under the same pre-v1-beta breaking-change stance — all
      devices upgrade together.)
      Tests: opening a legacy-format (pre-marker) database that has persisted
      state fails cleanly at `open()` with a clear error — include a case where
      a legacy `$meta` generation counter is `0` or `1` specifically (the
      collision case), not just `device_id` (which fails safe on its own and
      would have passed a weaker test); and a complementary test that a
      brand-new (empty) database opens successfully and writes the marker (so
      the (c) path is not misclassified as legacy).

      **Implementation notes (found during implementation, not anticipated by
      the plan text — recorded per the workflow policy):**
      1. **The `isNewDatabase` signal did not exist and had to be added.**
         `CrashRecovery.open()` never exposed "was `CURRENT` absent this
         open" outward. Added `OpenResult.isNewDatabase` (threaded from a new
         local in `CrashRecovery.open()`, set exactly when the `CURRENT`-read
         `StorageException` branch runs) and implemented the gate in
         `KvStoreImpl.open()`, immediately after `MetaStore` construction —
         not in `KmdbDatabase.open()` as the marker's `$meta` home might
         suggest — because the gate must run before *any* caller of
         `KvStoreImpl.open()` (not just `KmdbDatabase`) can read a framed
         value, and `isNewDatabase` is only naturally available at that
         layer.
      2. **A latent, pre-existing engine fragility — not independently
         regression-tested; the claim that it was has been corrected
         (`kmdb-qa`, 2026-07-13).** `WalWriter.append` only calls
         `StorageAdapter.syncFile` (content), never `syncDir` (the file's
         own directory entry), so in principle the *first* write to a
         brand-new `wal-00001.log` — the marker's WAL append, in this
         case — is not durable until *some* later `syncDir(dbDir)` call
         commits the file's own directory entry. An explicit
         `syncDir(dbDir)` was added right after `putFormatVersionMarker()`
         in the brand-new-database branch as a defensive measure. **This
         was originally (incorrectly) claimed to be
         regression-covered by `manifest_fsync_recovery_test.dart`'s "fresh
         database create is durable" test.** `kmdb-qa` reverted the fix and
         reran that test (and their own targeted 50-write-then-crash probe)
         — both **passed without the fix**, and reverting-and-rerunning
         locally reproduced the same result. Root cause: **the fix's own
         Phase 2/B8-B9 "looks fresh" widening (item 3 below) already
         self-heals this exact failure mode** — on the very next open, a
         database whose marker was lost to this gap has `isNewDatabase`
         false but `$meta` completely empty (since nothing else survived
         the same uncommitted WAL file either), so the widened condition
         re-classifies it as case (c) and silently re-stamps the marker.
         The two fixes structurally overlap for the single-session,
         first-write-is-the-marker scenario this item addresses, so no
         test can currently distinguish "fix present" from "fix absent" —
         `kmdb-qa` was unable to construct one either. The `syncDir` call is
         kept as defense-in-depth (it makes the marker durable by
         construction rather than by relying on a later self-heal being
         reachable in every future code path), but it is **not** an
         independently-verified fix and must not be described as one. The
         underlying `WalWriter.append`-never-`syncDir`'s gap is a
         pre-existing engine fragility outside this plan's scope;
         `kmdb-architect` is recording it as a documented invariant in the
         spec separately (not this plan's job to fix).
      3. **The "new" signal needed widening beyond `isNewDatabase` alone —
         found via `encryption_crash_test.dart`'s existing
         `KvStoreConfig.forTesting()`/`fsyncOnWrite: false` crash scenarios.**
         With `fsyncOnWrite: false` (a real, if lower-durability, config —
         not test-only in principle), `CURRENT`/Manifest still survive a
         crash unconditionally, but ordinary `$meta` puts (the marker,
         `enc:blob`, anything) do not — so a crash immediately after a
         brand-new database's provisioning session left `CURRENT` present
         but the marker absent, misclassifying an empty, content-free
         database as legacy. This exactly mirrors `enc:blob`'s own
         pre-existing, already-accepted crash story (an unsynced
         provisioning write is lost with the rest of that session; the
         database just falls back to "looks unencrypted"). Fixed by widening
         the "looks fresh" condition to
         `isNewDatabase || await engine.scan(MetaStore.kNamespace).isEmpty`
         — a direct, comprehensive "is `$meta` itself completely empty" scan
         (not an enumeration of specific known keys, which was tried first
         and found to miss realistic cases — e.g. a bare `device_id` with no
         namespace ever registered, since `ensureDeviceId()` is independently
         callable before any document write). This scan only ever runs on
         the rare marker-absent path (never on the common already-marked
         path), and only reads raw bytes (`Stream.isEmpty`, no
         `EncryptionEnvelope`/`ValueCodec` decode), so it cannot itself
         misparse a legacy value. Regression-covered by
         `encryption_crash_test.dart`'s two provisioning-crash-safety tests
         (both failed before this fix and pass after) and by four new,
         targeted tests in `test/engine/meta_store_encryption_test.dart`
         (legacy DB with real content refuses; legacy DB with gen counter
         `0` refuses; legacy DB with gen counter `1` refuses; legacy DB with
         only a bare `device_id` refuses — the last one specifically
         exercises the "no namespace ever registered" gap the first,
         narrower attempt at this fix missed).
      4. **Two unrelated pre-existing tests needed updating, not because
         they were wrong, but because the marker's existence is a real,
         permanent behavioural change to every `open()`:**
         `writebatch_atomicity_test.dart`'s "single put folds document + meta
         writes into one batch frame" assumed the user's batch frame starts
         at WAL offset 0 (now offset > 0, since the marker's own WAL record
         precedes it on a fresh database) — changed to scan for the batch
         frame, mirroring the sibling test's own approach.
         `sync_engine_test.dart`'s HWM test asserted an absolute upper bound
         on the high-water mark that assumed a freshly-opened, never-written
         store's memtable is empty at `push()`-time flush — no longer true,
         since `$meta` (single-`$`, syncable) legitimately contributes the
         marker's real-wall-clock HLC now. Narrowed the assertion to the
         specific invariant the test actually verifies (the `.local.sst`
         file's HLC must not leak in), per its own doc comment.
- [x] Explicitly verify `enc:blob` (`getEncryptionBlob`/`putEncryptionBlob`)
      is untouched and still uses the raw path (Q2) — this guard is now more
      load-bearing than before, since the general `$meta` path encrypts by
      default and must provably never touch `enc:blob`. Verified by a
      dedicated test (`MetaStore — enc:blob exemption (Q2)` group in
      `test/engine/meta_store_encryption_test.dart`) that sets
      `MetaStore.encryption` to a real provider and confirms
      `getEncryptionBlob`/`putEncryptionBlob` still round-trip via the raw
      path (byte-level check: the stored bytes are not
      `EncryptionFlag.aesGcm`-prefixed).
- [x] Tests: MetaStore round-trip with encryption on/off; bootstrap-ordering
      regression test that opens a brand-new database with encryption enabled
      from the very first write and confirms no `$meta` entry (including the
      first `device_id` write) ends up unencrypted; confirm crash-recovery
      (`docs/spec/17_crash_recovery.md`) still replays correctly with
      encrypted `$meta` entries in the WAL — this touches the durability-
      critical path called out in CLAUDE.md, so exercise it against the
      `FaultyStorageAdapter` fault-injection harness, not just the in-memory
      test adapter. Done — new file `test/engine/meta_store_encryption_test.dart`
      (16 tests): encryption round-trip group (gen counter, device ID,
      namespace registry, tombstone floor, `getRawByName`/`putRawByName`,
      dirty flag, wrong-DEK failure), `enc:blob` exemption group, format-
      version marker group (5 tests, including the two byte-collision cases),
      bootstrap-ordering group, and a `FaultyStorageAdapter` crash-recovery
      group (WAL replay of encrypted `$meta` + document data after a
      crash-before-flush). Full package: 2,345 tests pass (2,329 + 16 new),
      12 e2e skipped.

**Phase 2 close-out (see the workflow policy above):**

- [x] Verify every task/step checkbox above is checked off — do not proceed
      to commit with any left unchecked.
- [x] Run `make pre_commit` (format, analyze, license_check, scoped tests).
      Green: format_check, analyze (zero issues across the whole workspace),
      license_check, and `melos pre_commit_test` (2,345 tests, 12 e2e
      skipped) all passed.
- [x] Hand off to `kmdb-qa` for sign-off on Phase 2's diff specifically —
      this is the phase with the most architectural risk (the late-bound
      provider, the `enc:blob` carve-out, and the format-version gate), so
      give the QA pass particular attention to the B8/B9 marker logic and
      the crash-recovery fault-injection results, not just test coverage
      numbers. Resolve every blocking item before committing.
      **Signed off (2026-07-13), run by the coordinator session** (this
      `kmdb-plan-implement` session has no Agent/Task tool — see
      `.claude/agent-memory/kmdb-plan-implement/feedback_no_agent_tool.md`).
      All three flagged items were independently verified as correct and
      sound, with detailed reasoning: the B8/B9 three-way discrimination,
      the widened freshness-gate condition, and the `getDirtyFlag`
      presence-only change. **One blocking issue, since fixed:**
      `LegacyDatabaseFormatException` was not exported from
      `packages/kmdb/lib/kmdb.dart` — every peer open-time exception
      (`LockException`, `StorageException`, `EncryptionError`) was, this one
      wasn't. Added to the `show` clause. **One correction to this plan's own
      notes, since made:** the `syncDir(dbDir)` fix's item 2 note above
      originally claimed `manifest_fsync_recovery_test.dart` regression-covers
      it — `kmdb-qa` reverted the fix, reran that test and their own targeted
      probe, and both passed without the fix (confirmed independently by
      reverting and rerunning locally). The fix itself is sound
      defense-in-depth and is kept; the false regression-coverage claim in
      item 2 above has been corrected to explain why no test can currently
      isolate it (structural overlap with item 3's self-heal). `kmdb-architect`
      is separately recording the underlying `WalWriter.append`-never-`syncDir`'s
      gap as a documented spec invariant (pre-existing engine fragility,
      out of this plan's scope). **Non-blocking, addressed:** a one-line doc
      comment was added to `appendTombstoneFloorAdvance` warning about the
      write/read encryption asymmetry with `getTombstoneFloor` should it ever
      be wired up for real; the comment-drift nit in
      `meta_store_encryption_test.dart` (claimed to seed a namespaces registry
      entry it didn't) was fixed in the two affected tests.
- [x] Commit Phase 2 on the plan's branch.
      **`kmdb-pre-commit`: re-run after the above fixes — PASS.** See below.

### Phase 3 — Gap 4: vault manifest `originalName`

- [x] Implement the Q6-resolved fix (encrypt `originalName` in place,
      recommended) in `VaultManifest`. Done — `originalName` is not encoded
      inside `VaultManifest` itself (which stays a pure, synchronous JSON
      DTO, no `EncryptionProvider` knowledge, consistent with keeping
      `toJson`/`fromJson` simple); instead `VaultStore.ingest` (the sole
      construction site for a locally-authored manifest) wraps it with
      `EncryptionEnvelope` and base64-encodes the result before constructing
      the `VaultManifest`, reusing the existing `encrypted` flag to signal
      both blob-and-name ciphertext together (a database is either born
      encrypted or never encrypted, so the two are always set in lockstep —
      no new field needed).
- [x] Update every `originalName` read site (ingest, manifest readers, and
      coordinate with `plan_0_08_vault_file_export.md`'s `vault export`
      command if that work is implemented concurrently or after this phase —
      check its status before starting this phase). Checked:
      `plan_0_08_vault_file_export.md` status is `Open` (not implemented,
      not concurrently in progress) — no coordination needed. `originalName`
      read sites audited: `VaultStore.getManifest` is the sole decryption
      point (fixed); `VaultPackage`'s `uploadManifest.originalName` and
      `kmdb_cli`'s `vault_import_helper.dart` both read from a *different*
      object — the upload-time hint manifest bundled inside a `.kvlt`
      *import* archive, which is by design always portable plaintext (§31
      "KVLT and Encryption") — out of scope, left untouched.
      `vault_indexing_isolate.dart`'s `VaultManifest(...)` is a throwaway,
      never-persisted manifest built only to pass `mediaType` to a text
      extractor (`originalName: ''`) — no encryption concern, left
      untouched. `local_directory_vault_adapter.dart`'s
      `syncVaultMetadata`/`createStub` path reads a peer device's already
      (identically) encrypted `manifest.json` verbatim and writes it through
      unchanged — correct as-is, no decryption needed at that layer.
- [x] Update §31 to explicitly acknowledge `mediaType`/`size`/`sha256`/
      `createdAt` as plaintext `manifest.json` surfaces, with the existing
      rationale (dedup, sync routing) stated plainly rather than left
      implicit. Done — §31 gap 5 rewritten: a progress note records the
      `originalName` fix, and each of `sha256`/`mediaType`+`size`/
      `crc32c`+`createdAt` gets its own explicit, stated rationale for
      staying plaintext (previously only implied). Also corrected a stale
      field name (`hlcTimestamp` → `createdAt`, matching the actual
      `VaultManifest.toJson()` field).
- [x] Tests: manifest round-trip with encryption on/off; confirm dedup
      (`sha256`-keyed) and sync-routing logic (which reads `mediaType`/`size`
      without decrypting) are unaffected. Done — new "VaultStore.originalName
      encryption (Gap 4)" group in `test/encryption/vault_encryption_test.dart`
      (8 tests): plaintext round-trip unchanged; encrypted `originalName` not
      visible on disk; `getManifest()` transparent decrypt; `StateError` with
      no provider; `EncryptionError` with the wrong DEK;
      `mediaType`/`size`/`sha256`/`createdAt` readable as bare JSON without
      any decryption even when `originalName` is encrypted (the sync-routing/
      dedup invariant, asserted directly against the raw on-disk bytes, not
      just behaviourally); and a dedup test confirming a second ingest with a
      different `originalName` does not overwrite the first (encrypted)
      manifest. Full `test/vault/` + `test/encryption/` suites: 585 tests
      pass.

**Phase 3 close-out (see the workflow policy above):**

- [x] Verify every task/step checkbox above is checked off — do not proceed
      to commit with any left unchecked.
- [x] Run `make pre_commit` (format, analyze, license_check, scoped tests).
- [x] Hand off to `kmdb-qa` for sign-off on Phase 3's diff specifically
      (`VaultManifest`, its read sites, and the §31 acknowledgment). Resolve
      every blocking item before committing.
      **Signed off (2026-07-13), run by the coordinator session** (this
      session has no Agent/Task tool — see
      `.claude/agent-memory/kmdb-plan-implement/feedback_no_agent_tool.md`).
      Ready to commit on its own merits: the encrypt-in-place design, base64
      handling, `encrypted`-flag lockstep, and `getManifest`-as-sole-
      decryption-point were all verified correct. `kmdb-qa` independently
      checked the KVLT-archives-are-intentionally-plaintext reasoning
      against `docs/spec/24_vault.md` and the live `export_command.dart`/
      `dump_command.dart` code paths (not just this plan's summary) —
      confirmed correct, not a rationalised gap. Test coverage and the
      not-yet-implemented `vault export` plan's coordination status were
      both confirmed fine. Two unrelated items surfaced and were resolved
      alongside this phase, not part of Phase 3's own diff: (a) a flaky
      probabilistic single-byte assertion in Phase 2's (already-committed)
      `meta_store_encryption_test.dart` device-ID test, fixed by `kmdb-qa`
      and landed as its own standalone commit `6c05590` before this phase's
      commit; (b) a second, earlier instance of the `mimeType`/
      `hlcTimestamp`/numeric-`crc32c` field-name drift in §31's manifest
      JSON example (~line 247) — the same class of staleness this phase's
      own gap-5 prose fix corrected, but a spot this phase's edit didn't
      reach — fixed by `kmdb-architect` in the same file. A separate,
      pre-existing, unrelated `sync_engine_test.dart:1170` flake (wall-clock
      HLC placement under parallel full-suite load, not a production bug)
      was logged to `docs/roadmap/0_09.md` on `main` by `kmdb-architect` —
      out of this plan's scope, not touched here.
- [x] Commit Phase 3 on the plan's branch.
      **`kmdb-pre-commit`: PASS** (format/analyze/license clean, 2,352/2,352
      tests; one transient native-assets-bundling flake on the first run
      cleared on rerun, unrelated to this plan's code).

### Phase 4 — Gap 2: HMAC-keyed namespace tokens

- [x] Add sub-key derivation to `EncryptionProvider` (`deriveSubKey(info)` or
      a purpose-built `indexToken(domain, term)`), using the existing HKDF
      machinery in `key_derivation.dart`, `info = "kmdb-index-token"` (Q4).
      **Done as `Future<String> indexToken(String message)`** on the
      `EncryptionProvider` interface (a single domain-separated message
      string, not a split `domain`/`term` pair — simpler call sites, same
      effect). `AesGcmEncryptionProvider` derives the sub-key lazily on first
      call via the existing `cryptography` package's async `Hkdf`/`Hmac`
      machinery (bit-for-bit the same approach as `key_derivation.dart`'s
      recovery-KEK derivation), caches it as a memoized `Future<SecretKey>`
      (concurrent first-callers await the same in-flight derivation — see the
      "concurrent first calls" test), then computes HMAC-SHA256 over the
      message and truncates to 16 bytes (32 hex chars) — verified this
      requires no new dependency: `calculateMac` is part of the same
      `cryptography` package already used throughout this file, so
      `indexToken` is `async` end-to-end (no synchronous fast path was
      needed — every production call site is already inside an `async`
      function; verified by grep before converting). Tested in
      `test/encryption/encryption_provider_test.dart`'s `indexToken` group:
      determinism, cross-instance reproducibility (same DEK), 32-hex-char
      format, domain separation (field and collection), different-DEK
      produces a different token, concurrent-call safety, and a
      raw-DEK-non-leakage guard.
- [x] Replace `FtsManager._termToHex`, `index_writer._encodeValueHex`/
      `indexNamespaceForValue`, and `VaultBm25Writer._termToHex` with
      HMAC-SHA256 token generation when a provider is active; domain-separate
      per 0_08.md (`"{ns}:{field}:" + term` for FTS, `"{ns}:{path}:" + value`
      for index). Fall back to today's plaintext hex when encryption is off.
      **Done exactly as specified**, plus `VaultBm25Writer._termNamespace`
      domain-separated as `"{sha256}:" + term` (the vault-FTS equivalent of
      `ns:field`, since vault indexing is scoped per blob, not per
      collection field). Secondary-index domain separation clarified in code
      comments: the HMAC message uses the *hex-encoded* value
      (`_encodeValueHex(value)`) as the value component, not a re-derived
      "natural" string form — this reuses the existing canonical string
      representation `IndexWriter` already produces for every value type
      (int/double/bool/string) rather than inventing a second one, and is
      the literal reading of "`{value}`" in the plan's formula. Making the
      namespace-computation chain `async` required converting
      `IndexWriter.addEntries`/`removeEntries`/`indexNamespaceForValue` and
      `IndexReader.lookupByValue` from sync to async (all call sites were
      already inside `async` functions — verified by grep, zero production
      code needed restructuring beyond adding `await`); `VaultBm25Writer`
      keeps its "static const, values stay raw/unwrapped" character for Gap
      1 but necessarily gains an `EncryptionProvider?` *parameter* (not
      field) on `write`/`deleteTermEntry` for Gap 2's namespace computation,
      since — unlike Gap 1's values — the namespace name cannot be
      wrapped/computed after the fact by `VaultSearchManager`; documented
      this split explicitly in the class doc comment.
- [x] Add a `tokenMode: hex | hmac` discriminator to `FtsIndexState`,
      `VecIndexState`, and the secondary index's `$meta` state (Q5); on
      `open()`, detect a mismatch between the stored mode and what the
      current code version would produce (a **format-version mismatch**, not
      a runtime toggle — encryption itself cannot be enabled/disabled on an
      existing database, see Q5) and trigger a full rebuild of the affected
      index, mirroring WI-1's model-identity invalidation pattern. This
      detection must run only after Phase 2's `MetaStore` provider binding is
      in place, since the index state being read is itself now encrypted.
      **Deviation found during implementation, documented here rather than
      silently applied: `VecIndexState` does NOT get a `tokenMode` field.**
      Verified against the actual code (`vec_manager.dart`, all
      `VecIndexState.*Namespace` helpers): `$$vec:{ns}:{field}`,
      `$$vec:corpus:{ns}:{field}`, and `$$vec:truncated:{ns}:{field}` are
      all keyed by document ID, never by an embedded term or value the way
      `$$fts:{ns}:{field}:{token}` and `$$index:{ns}:{path}:{token}` are —
      there is no hex-tokenised namespace scheme for Vec to migrate away
      from in the first place (confirmed by grepping `vec_manager.dart` for
      any hex/`toRadixString` encoding: none exists). The same is true of
      `VaultVecWriter`'s `$$vault:vec:idx:{sha256}` (keyed by chunk index,
      not by term). Adding an always-inert `tokenMode` field to
      `VecIndexState` would be exactly the kind of dead-weight/no-op state
      CLAUDE.md warns against. Implemented instead: `tokenMode` on
      `FtsIndexState` (checked in `FtsManager.checkAndTransitionOnOpen`,
      which purges stale-mode base-term namespaces via a new
      `_purgeBaseNamespaces` helper before resetting to `undefined`) and a
      new `IndexTokenMode` enum + `tokenMode` field on the secondary index's
      `IndexState` (checked in a new `IndexManager.checkTokenModeOnOpen`,
      called from `KmdbDatabase.open()` right after `IndexManager`
      construction and before `checkInterruptedBuilds` so a purge-triggered
      index is never also misreported as an interrupted build — it reuses
      the existing `removeIndex()` method, which already purges every
      sub-namespace and the `$meta` state entry). Vault FTS gets an
      analogous per-blob `ftsTokenMode` field on `VaultExtractionState`
      (reusing the `FtsTokenMode` enum), checked in a new
      `VaultSearchManager._checkTokenMode`, called from `recover()`
      alongside the existing `_checkModelVersion` check (mutually exclusive
      with it — `_checkModelVersion` now returns `bool` so `recover()` can
      skip the redundant second reset-and-enqueue when a model-version
      change already triggered one; `_enqueue` has no dedup).
- [x] Resolve and implement Q3 (empty `$$index:` value). **Confirmed
      unchanged**: `IndexWriter.addEntries` still writes `Uint8List(0)` —
      the namespace token alone carries the (now-opaque) value, so an empty
      value remains correct and adds no GCM overhead, exactly as Q3
      concluded during investigation.
- [x] Document the residual statistical side-channel limitations (term
      frequency, search-pattern leakage, co-occurrence, per-term document
      count) in §31's "Threat Model & Confidentiality Boundaries" section as
      an accepted limitation, per 0_08.md's own framing. Added as a
      "Progress note" under gaps 2 and 3 (not yet marked "resolved" —
      that bookkeeping is Phase 5's job per the existing convention gap 1's
      note already established).
- [x] Document the DEK-rotation interaction: passphrase rotation re-wraps but
      does not change the DEK, so HMAC tokens survive rotation; a future
      "change the DEK" feature would require a full index rebuild. Added
      alongside the residual-leakage note in §31, plus in
      `EncryptionProvider.indexToken`'s doc comment.
- [x] Tests: token generation is deterministic and reproducible from the same
      DEK across process restarts; different fields/namespaces with the same
      term produce different tokens (domain separation); an encrypted
      database whose index state predates Gap 2 (`tokenMode: hex`) rebuilds
      to `hmac` on next `open()` under Gap-2 code and queries correctly
      against the new namespace scheme (this is the real migration
      scenario — see Q5, **not** a runtime encryption toggle, which cannot
      occur); a database provisioned unencrypted continues to use hex
      indefinitely (a distinct database, not a toggled state); query-time
      namespace reconstruction matches write-time for every mode. **Done**:
      `test/encryption/encryption_provider_test.dart` (`indexToken` group,
      9 tests — determinism, domain separation ×2, format, different-DEK,
      concurrency, non-leakage); new `test/search/lexical/
      fts_token_mode_test.dart` (3 tests) and new `test/query/
      index_token_mode_test.dart` (3 tests), each covering: real
      hex→hmac migration with a purge assertion (stale namespaces gone,
      new namespaces disjoint from the old set, search/lookup still
      correct after rebuild), the "unencrypted stays on hex, no spurious
      rebuild" regression guard, and write-time/query-time namespace-match
      across two manager instances sharing one DEK. The vault-FTS migration
      is exercised end-to-end (not just unit-tested) by rewriting
      `test/vault/search/vault_extract_encryption_test.dart`'s existing
      "toggle-on / mixed-state" integration test — see that file's doc
      comment for why it needed rewriting: it previously modelled a
      "mixed-state, both directly searchable" scenario for Gap 1 (value
      encryption, which genuinely does coexist indefinitely since each
      artifact is self-describing) that is **not** true the same way for
      Gap 2 (namespace tokens, which are not self-describing — an
      HMAC-mode manager cannot find hex-mode entries without recover()'s
      migration step). The rewritten test adds the `attach()`/`recover()`
      calls the original test omitted (mirroring `KmdbDatabase.open()`'s
      real sequence exactly) and asserts the blob is migrated *before* any
      search runs against it, which is the actual production guarantee.
      All two-manager-instance tests here and in the two new unit-test
      files follow the same "construct a second manager over the same
      KvStoreImpl" technique the plan's own investigation established as
      the valid way to test this mechanism, given a literal
      "toggle encryption on an existing KmdbDatabase" is architecturally
      impossible (B5) — confirmed this reasoning extends soundly to
      `FtsManager`/`IndexManager` directly (not just `VaultSearchManager`),
      since none of the three collaborators enforce single-instance-per-
      store at the type level.

**Phase 4 close-out (see the workflow policy above):**

- [x] Verify every task/step checkbox above is checked off — do not proceed
      to commit with any left unchecked.
- [x] Run `make pre_commit` (format, analyze, license_check, scoped tests).
      Format check initially failed (8 files needed reformatting — new test
      files plus a few edited lib files); fixed with `make format` and
      reran. All four sub-gates now pass independently verified:
      `dart format --output=none --set-exit-if-changed packages` (exit 0),
      `melos run analyze` (exit 0, "No issues found!" across all 7
      packages), `make license_check` (exit 0), and the full `kmdb` test
      suite (2367 passed, 12 skipped E2E, 0 failed).
- [x] Hand off to `kmdb-qa` for sign-off on Phase 4's diff specifically —
      this is the largest, least mechanical phase (new HMAC/HKDF primitive,
      `tokenMode` rebuild-on-upgrade behaviour), so give it particular
      attention: token determinism, domain separation, and the rebuild path
      actually exercised end-to-end, not just unit-tested in isolation.
      Resolve every blocking item before committing.

**`kmdb-qa` review, round 1 (2026-07-13):** thorough pass — confirmed correct:
the `indexToken` HKDF/HMAC crypto (genuinely tested, not just claimed), the
sequencing after Phase 2's provider binding, the `VecIndexState`-has-no-`
tokenMode` deviation (independently re-verified: vector namespaces key by
`(ns, field)` with no embedded term/value, so there is nothing to migrate),
the fallback-to-hex-when-unencrypted behaviour, and the
`vault_extract_encryption_test.dart` rewrite (a legitimate strengthening, not
a weakened test). One **blocking bug found (B1)**, two trivial non-blocking
nits.

- [x] **B1 (blocking, fixed) — `VaultSearchManager.recover()` skipped the
      Gap-2 hex-namespace purge entirely whenever a model-version reset also
      fired for the same blob.** The original `recover()` call site gated
      the *whole* `_checkTokenMode` call behind `if (!resetForModel)`, so a
      blob needing **both** a model-version bump **and** a hex→hmac token
      migration in the same `open()` — a real, reachable scenario: an
      encrypted pre-Gap-2 database that also picks up a model swap (exactly
      what the multilingual-embedding-model roadmap item would trigger) —
      had its stale `$$vault:fts:{sha256}:*` hex namespaces silently
      orphaned on disk indefinitely, still leaking the search vocabulary in
      plaintext hex terms — precisely the confidentiality property this
      phase exists to close. Root cause: the purge (must always run on a
      mode mismatch) and the reset+re-enqueue (must be deduplicated between
      the two checks, since `_enqueue` has no dedup) were coupled behind one
      shared boolean instead of being independently gated. **Fix:**
      `_checkTokenMode` now takes a required `alreadyReset` parameter — the
      purge loop runs unconditionally whenever `state.ftsTokenMode` doesn't
      match `_currentTokenMode`, and only the trailing reset-to-`pending`+
      `_enqueue` step is skipped when `alreadyReset` is `true`.
      `_checkModelVersion`'s `bool` return (added in the original
      implementation for the old, now-removed gating) is threaded straight
      into `_checkTokenMode`'s `alreadyReset` argument at the single
      `recover()` call site. **Verified the fix is load-bearing, not just
      claimed:** temporarily reverted the call site to the old
      `if (!resetForModel)` gating, reran the new stacked-upgrade test below
      — it failed exactly as expected (stale hex namespace found in the
      post-`recover()` namespace set) — then restored the fix and confirmed
      it passes again.
- [x] Add a test that stacks both conditions (encrypted pre-Gap-2 index
      state **and** a model-version mismatch on the same blob) and confirms
      no hex namespace survives `recover()`. Added a new group in
      `test/vault/search/vault_search_manager_test.dart`,
      `'recover() — stacked model-version + token-mode upgrade (B1)'`, with
      two tests: (1) the stacked scenario itself — seeds hex-tokenised BM25
      namespaces plus an `indexed` extract state with an old model version
      and an absent `tokenMode` (defaults to hex), reopens with both a new
      `EncryptionProvider` and a different embedding model, and asserts
      every pre-existing hex namespace is gone from
      `allStoredNamespaces()` after `recover()`, the model version updated,
      and the blob reached `indexed` again; (2) a model-version-only
      regression guard (no token-mode mismatch) confirming the fix did not
      turn `_checkTokenMode` into an unconditional purge.
- [x] Nit: license headers on the two new test files
      (`test/search/lexical/fts_token_mode_test.dart`,
      `test/query/index_token_mode_test.dart`) — fixed the missing period
      after "The Authors" and `http://` → `https://` to match
      `header_template.txt` exactly (was passing `license_check`'s
      mechanical `addlicense` diff, just visually inconsistent with every
      other file).
- [x] Nit (optional, documented since the code was already being touched):
      the domain-separator `:`-join scheme is a plain concatenation, not a
      length-prefixed encoding — documented in
      `EncryptionProvider.indexToken`'s doc comment: the vault-FTS domain
      (`sha256:term`) is immune (sha256 is always exactly 64 hex chars, a
      fixed split point), the secondary-index domain's value component is
      immune (always hex-encoded, never contains `:`), but the FTS domain's
      `ns`/`field` (and the secondary-index domain's `ns`/`path`) are not
      escaped against an embedded literal `:` — a theoretical concatenation
      ambiguity, not exploitable via untrusted input in this threat model
      (collection/field names are application-chosen, not attacker
      data), left undocumented-but-unfixed no longer — now documented,
      deliberately left unfixed as out of scope.
- [x] Re-ran `make pre_commit` after the B1 fix + nits: all four sub-gates
      pass independently verified (format_check exit 0 — one file needed
      reformatting, fixed via `make format`; `melos run analyze` exit 0
      clean across all 7 packages; `make license_check` exit 0; full `kmdb`
      test suite 2369 passed — up from 2367 by the two new B1 tests — 12
      skipped E2E, 0 failed). The known pre-existing
      `sync_engine_test.dart` H4-FU3 flake (logged to
      `docs/roadmap/0_09.md`, unrelated to this plan) did not reappear on
      this run.
- [x] Hand off to `kmdb-qa` for a **second** round of sign-off on the B1 fix
      specifically, given the severity of what round 1 found — re-verify
      the purge-vs-reset decoupling is correct in all four
      purge/reset-mismatch combinations (neither mismatched, only
      token-mode mismatched, only model-version mismatched, both
      mismatched) and that the new stacked-upgrade test actually exercises
      the fix (not just superficially passes). Resolve every blocking item
      before committing.

**`kmdb-qa` review, round 2 (2026-07-13):** did not just trust the round-1
revert-and-confirm claim — independently reverted the fix themselves, re-ran
the stacked test, watched it fail with the actual plaintext hex tokens
(`"mountains"`, `"rivers"`) visibly surviving in the failure output, then
restored the fix and confirmed it passes. The purge-vs-reset separation was
verified by direct code read (purge unconditional on a `tokenMode` mismatch;
only the trailing reset/re-enqueue gated by `alreadyReset`). The
required-parameter change (`_checkTokenMode(..., {required bool
alreadyReset})`) was confirmed to have exactly one call site, with no
missed/wrong updates. Both nits (license headers, domain-separator doc note)
confirmed fixed. `make pre_commit` re-run independently: 2357 passed, 12
skipped E2E, green. **Phase 4 signed off — genuinely clean.**
- [x] Commit Phase 4 on the plan's branch.

### Phase 5 — Spec, roadmap, and glossary updates

**Note:** §31 already contains an honest "Threat Model & Confidentiality
Boundaries" section (lines 437–639) documenting gaps 1–5, including a
"Provider Threading" over-claim flag at lines 474–478 and this plan's gaps 4/5
at lines 539–564. This phase is **updating those existing entries to
"resolved" and correcting stale detail**, not writing the acknowledgments
from scratch.

- [ ] §31: mark gaps 1–4 (in §31's own numbering) resolved once their phases
      land; correct the "Provider Threading" over-claim at lines 474–478 now
      that `MetaStore`/vault writers are wired; update the protected/
      unprotected surface lists to match Phases 1–4; add the Gap 2
      residual-leakage and DEK-rotation notes; add the Q7 CLI-credentials
      accepted-limitation note (new, not currently in §31).
- [ ] §24: correct the "vault chunk vectors have no KV namespace" claim.
- [ ] Record B8's breaking-format-change decision: a note in §31 (existing
      databases created before this plan lands must be recreated — no
      migration path, consistent with the Phase 12 precedent) and an entry
      in `docs/spec/28_release_checklist.md` calling this out explicitly for
      anyone upgrading a pre-existing dev/test database.
- [ ] §99 glossary: add "index token" / HMAC token terminology if Gap 2 ships.
- [ ] `docs/roadmap/0_08.md`: mark Gaps 1–4 complete with links to this plan
      and the merged PR(s); update the stale `$fts:`/`$vfts:` namespace names
      in the gap text to their current `$$`-prefixed forms for future
      readers.
- [ ] Run `make site` after spec edits.

**Phase 5 close-out (see the workflow policy above):**

- [ ] Verify every task/step checkbox above is checked off — do not proceed
      to commit with any left unchecked.
- [ ] Run `make pre_commit` (format, analyze, license_check, scoped tests;
      also run `make doc_site`/`make site` since this phase touches spec
      files — see CLAUDE.md's note that `make site` itself is not a real
      target).
- [ ] Hand off to `kmdb-qa` for sign-off on Phase 5's diff specifically (doc
      accuracy against what Phases 1–4 actually shipped, not just prose
      quality). Resolve every blocking item before committing.
- [ ] Commit Phase 5 on the plan's branch.

**Final step — whole-PR checks, spec alignment, and pre-commit.** Everything
above is per-phase. These checks need the complete picture (all five phases
landed) and run once, after Phase 5's commit, before opening the PR:

- [ ] Run `make coverage` — confirm >95% on all new/changed files across all
      five phases, and that the overall project minimum (CLAUDE.md: 90%,
      current baseline: 95%) is maintained.
- [ ] Run the §18 performance benchmarks (`packages/kmdb/benchmark/main.dart`)
      before/after — value encryption on every FTS/Vec write adds AES-GCM
      overhead to a hot path; confirm no P99 regression outside acceptable
      bounds, or document the regression and get sign-off on it explicitly.
- [ ] Run the multi-device `kmdb_harness` package — **only Gap 3's `$meta`
      and Gap 4's manifest touch synced state** (Gap 1/2 namespaces are
      local-only per the corrected threat model, so cross-device sync
      behaviour is unaffected by them); confirm cross-device sync still
      converges correctly with Gap 3/4's now-encrypted synced values. Only
      encrypted databases pay the AES-GCM cost on any of these paths —
      encryption remains opt-in throughout.
- [ ] Hand off to the **`kmdb-architect` agent** for a dedicated
      spec-alignment pass: confirm §31, §24, §99, and `docs/roadmap/0_08.md`
      now accurately describe the *complete* implemented state across all
      four gaps — not just that Phase 5's own diff reads well in isolation.
      This is a different, complementary check to `kmdb-qa`'s per-phase
      code-quality sign-offs above; `kmdb-architect` is the authoritative
      agent for `docs/spec/` per CLAUDE.md, and this plan's whole premise is
      a spec/code divergence, so an explicit final alignment check matters
      more here than on a typical plan. Resolve every discrepancy it finds
      before proceeding.
- [ ] Hand off to the **`kmdb-qa` agent** for a final whole-PR sign-off —
      this pass is about aggregate/cross-phase concerns (does the PR as a
      whole make sense, is overall coverage adequate, do the five commits
      tell a coherent story) rather than re-reviewing each phase's code in
      detail, since that already happened per-phase above. Do not open a PR
      until sign-off is received.
- [ ] Run `make pre_commit` one final time on the complete branch — format,
      analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).
- [ ] Open the PR from the branch with its five phase commits intact; merge
      (do not squash) once approved, per the workflow policy above.

## Review

This plan went through five review passes with the `kmdb-plan-reviewer`
agent before reaching `Investigated`. Each pass is recorded below in full —
what the reviewer found, and how the plan (Overview, Problem statement, Open
questions, and Implementation plan above) was changed in response. Every pass
surfaced a genuine, code-grounded defect; none were bikeshedding.

### Pass 1 (kmdb-plan-reviewer, 2026-07-10)

Overall: the Investigation is genuinely strong — the file:line grounding is
accurate against `main`, the four gaps are real, and the Q1/Q6 resolutions are
sound. But the **problem statement's threat model is wrong**, and that error
propagates into the phase priority, the migration story, and several test
bullets. This is not ready for `Investigated`. The specific blockers:

**B1 (blocking) — The problem statement mischaracterises the threat; §31 is
already honest.** The problem statement opens by quoting §31 as promising
that "cloud storage never sees plaintext document content in any form,
including system-namespace values," and calls this "false as implemented."
**That quote does not exist in the current §31.** The current spec
(`docs/spec/31_encryption.md:279`) says "*disk* storage never sees
plaintext," and §31 already contains a full, honest "Threat Model &
Confidentiality Boundaries" section (lines 437–639) that enumerates all four
of this plan's gaps as *known, documented* gaps 1–5 with the correct threat
framing. The plan is arguing against a stale spec.

More importantly, the framing throughout Gap 1/Gap 2 ("leaking … to cloud
storage in plaintext", "uploaded to cloud storage as plaintext SSTable
content") is **factually incorrect**. Every namespace in Gap 1 and Gap 2 is
`$$`-prefixed and therefore **local-only** — `isLocalOnly(ns) =>
ns.startsWith(r'$$')` (`namespace_codec.dart:148`), and `SyncEngine` skips
`.local.sst` files (`sync_engine.dart:245`). `$$fts:`, `$$vec:`, `$$index:`,
`$$vault:fts:`, `$$vault:vec:idx:`, and `$$vault:extract:` are **never
uploaded**. The WI-0 `$`→`$$` rename that the plan itself documents is exactly
what moved these off the cloud surface. §31 gap 2 already states this plainly:
"These SSTables are local-only and never uploaded; the threat is a compromised
local filesystem."

The correct threat model, which the plan must adopt:

- **Gap 1 & Gap 2** — *local-disk-at-rest only.* The threat is physical theft
  of (or a backup of) an encrypted database's directory by an adversary who
  does **not** hold the passphrase. Not a cloud-provider surface.
- **Gap 3 (`$meta`, single-`$`) & Gap 4 (`manifest.json`)** — *genuine
  cloud-provider exposure.* `$meta` rides syncable SSTables; `manifest.json`
  is synced. These are the only two gaps in this plan that leak to the cloud.

Action: rewrite the problem statement to (a) stop claiming §31 is "false" — it
is currently accurate and honest — and frame the work as *closing the gaps §31
already documents*; (b) state the per-gap threat model above.

**B2 (blocking) — Phase priority is asserted without stating the axis, and is
questionable for cloud confidentiality.** "Gap 1 highest priority" is
defensible only on a *content-severity* axis (Gap 1 leaks tokenised terms —
actual content — per §31's own summary). On a *cloud-confidentiality* axis it
is the **lowest** priority, because it never reaches the cloud. The plan
states a priority without stating which axis it is optimising, and the two
axes disagree. Make the axis explicit. If the driving concern is the cloud
provider (the headline motivation of §31 encryption), then **Gaps 3 and 4
should lead**, not Gap 1. See Q8.

**B3 (blocking) — Gap 3's async ripple through `MetaStore` is unspecified.**
The plan correctly flags the "static helper must become async" wrinkle for
`FtsManager`, but says nothing about the same problem in `MetaStore`, which is
worse. `ValueCodec.encode`/`decode` are `Future`-returning
(`encoding/value_codec.dart`), but the `$meta` writes folded into a user
`WriteBatch` — `appendGenerationCounterBump`, `appendNamespaceRegistration`,
`appendDirtyFlag` — are synchronous helpers invoked during batch assembly. The
implementer is left to choose between (a) making those helpers `async` and
rippling `await` up through the WriteBatch-build path at/above the KvStore
boundary, or (b) pre-encrypting the values in the callers before batch
assembly. That is a real design decision, not a mechanical edit, and it blocks
`Investigated`. Phase 2 must specify the chosen approach.

**B4 (should-fix) — Gap 3 introduces the first engine→encoding-layer
dependency; specify the mechanism.** `MetaStore` lives at the engine layer and
currently imports only `encryption_blob.dart` (for the raw `enc:blob`). No
file under `lib/src/engine/` imports `ValueCodec`
(`lib/src/encoding/value_codec.dart`) — encryption is threaded *above* the
KvStore boundary everywhere else (`KmdbCollection`, `IndexManager`,
`VersionManager`, `VaultRefInterceptor`). Routing `MetaStore` through
`ValueCodec` makes it the first engine→encoding importer. That may be
acceptable (MetaStore is already a boundary-bypassing special case), but the
plan should decide deliberately between calling `ValueCodec.encode` vs. calling
`EncryptionProvider.encrypt` directly with a hand-rolled flag envelope — the
former keeps wire-format consistency (preferred; do not hand-roll per
CLAUDE.md), the latter avoids the layer dependency. State the choice.

**B5 (blocking) — Q5's migration trigger is an impossible scenario; reframe
it.** Encryption **cannot be retrofitted onto a non-empty database** —
`KmdbDatabase.open()` throws `cannotProvisionNonEmptyDatabase` when user
namespaces already exist (`kmdb_database.dart:651–658`). A database is either
born encrypted or never encrypted; there is no runtime toggle. Therefore:

- Q5's "toggle encryption on an existing database → rebuild" and Phase 4's test
  bullet "toggling encryption on an existing database triggers rebuild and
  queries correctly" describe a scenario that **cannot occur** and is
  **untestable as written**.
- Phase 1's "toggling encryption off falls back to hex correctly" is likewise
  not a toggle — it is "an unencrypted DB uses hex; a separately-provisioned
  encrypted DB uses HMAC," two distinct databases, one code path.

The *real* rebuild trigger for Q5 is a **software/format-version upgrade** of an
*already-encrypted* database: a DB whose `$$fts:`/`$$vec:`/`$$index:` were built
by pre-Gap-2 code (hex tokens) is reopened under Gap-2 code (HMAC tokens), the
persisted `tokenMode` discriminator mismatches, and `open()` rebuilds. The
WI-1 model-identity precedent the plan cites is exactly right for *that* — it is
a persisted-format-version mismatch, not a user action. Reframe Q5 and every
"toggle" test bullet accordingly.

**Coupling check (as requested): does resolving Q1/Q6 disturb the rest?**

- **Q1 → Q5 (sequencing):** with Gap 3 landed, the `index:{ns}:{path}` state
  that houses Q5's `tokenMode` discriminator is now itself encrypted. `open()`
  must therefore bind the `EncryptionProvider` to `MetaStore` (the Q1
  late-bound setter) **before** it reads index state for rebuild-detection. Add
  this ordering constraint to Phase 2/Phase 4. Not a reopen of Q1 — just a
  cross-phase note.
- **Q1 ↔ Q2 (reinforces, doesn't disturb):** Q1 makes Q2's `enc:blob` guard
  *more* load-bearing, not less — the newly-encrypting general `$meta` path must
  provably never touch `enc:blob`. Keep Q2 exactly as scoped; it is the right
  question.
- **Q6:** independent of Q2–Q5/Q7. No knock-on. Correctly resolved.
- **Q3:** unaffected by Q1/Q6. "Leave empty" is fine and is additionally
  reinforced by the local-only reframing (there is no value-level confidentiality
  benefit either way). Resolvable now; does not need to wait on Q5.

**Are the remaining open questions the right ones?** Mostly yes. Q2 and Q4 are
well-posed and their recommendations are sound (Q4's HKDF sub-key via the
existing `key_derivation.dart:109` machinery is the right call — do not widen
`AesGcmEncryptionProvider.dek` exposure). Q7 is correctly scoped out. The gap
in the question set is **Q8** (added above): the plan never asks whether the
largest, riskiest, beta-blocking change (Gap 2) is warranted for a threat that
turns out to be local-disk-only. That decision was made under an incorrect
(cloud) threat model and should be re-confirmed.

**Smaller notes:**

- Phase 5 largely proposes to *add* acknowledgments (manifest fields, `$meta`,
  threat model) that §31 **already contains** (gaps 4/5 at lines 539–564, the
  full threat-model section at 437–639). Reframe Phase 5 as *updating the
  existing gap entries to "resolved"* and correcting the Provider-Threading
  over-claim (§31:474–478 already flags it), not writing them from scratch.
- The doc-drift correction (`$$vault:vec:idx:` exists; the 0_06.md/§24 "no KV
  namespace" claim is wrong) is a good catch and worth keeping regardless of
  the reframing.
- The benchmark/harness steps in the final section are appropriate. Note that
  because Gap 1/2 namespaces are local-only and encryption is opt-in, only
  encrypted databases pay the AES-GCM cost and cross-device sync is unaffected
  by Gap 1/2 (only Gap 3's `$meta` and Gap 4's manifest touch synced state) —
  worth stating so the harness expectations are scoped correctly.

**Status call:** Staying at **Questions**. Q1/Q6 are resolved, but B1/B3/B5
are design/framing gaps a Sonnet implementer could not resolve without making
significant decisions, and Q8 is a genuine user decision opened by the
corrected threat model. Address B1–B5, resolve Q2–Q5 + Q8, then this is a
strong candidate for `Investigated` — the underlying investigation work is
already most of the way there.

**Response (coordinator, 2026-07-10):**

- **Q8 resolved by the user**: Gap 2 stays in this plan — the local-disk-only
  threat model was reviewed and the risk accepted explicitly.
- **B1**: problem statement rewritten — no longer claims §31 is false; states
  the per-gap threat model (Gap 1/2 local-disk-only, Gap 3/4 cloud-facing)
  up front.
- **B2**: implementation-plan ordering section now states the axis explicitly
  (mechanical complexity, not severity or cloud-exposure) and names the
  disagreement between axes.
- **B3**: Phase 2 now specifies the chosen design — pre-encrypt at call sites
  before `WriteBatch` assembly, keeping the batch-append helpers synchronous.
  (Later shown to be factually wrong and corrected in Pass 2/B6.)
- **B4**: Phase 2 now specifies `ValueCodec.encode`/`decode` (not a
  hand-rolled envelope) as the chosen mechanism, with rationale. (Later
  superseded in Pass 3/B7.)
- **B5**: Q5 reframed around the real trigger (format-version mismatch on an
  already-encrypted database, not a runtime toggle); Phase 4's and Phase 1's
  test bullets rewritten to remove the impossible "toggle encryption on an
  existing database" scenario.
- Coupling note (Q1→Q5 ordering) folded into both Q5 and Phase 4.
- Phase 5 reframed as updating §31's existing gap entries to "resolved"
  rather than writing acknowledgments from scratch.
- Final-step harness/benchmark bullets updated to scope expectations to
  Gap 3/4 only (the only phases touching synced state), per the corrected
  threat model.

### Pass 2 (kmdb-plan-reviewer, 2026-07-10)

B1, B2, B4, B5, and Q8 are resolved cleanly — verified against the actual plan
text, not just the coordinator's response summary. The problem statement now
carries the correct per-gap threat model, the ordering axis is stated and its
disagreement acknowledged, Q5 is reframed around the real (version-mismatch)
trigger with the toggle language purged from the test bullets, and Q8's
Gap-2-stays decision is recorded with the risk accepted knowingly. Good.

**B4 stands** — `ValueCodec` is the right mechanism, and it interacts well with
the B6 correction below (in-helper encryption is a natural fit since the helpers
are already async).

**B6 (new, blocking) — Phase 2's chosen B3 design rests on a factual error
about `MetaStore` and is unimplementable as written.** Phase 2's "Design
decisions specified up front" block asserts that `appendGenerationCounterBump`,
`appendNamespaceRegistration`, and `appendDirtyFlag` "are synchronous helpers
invoked during batch assembly" and prescribes "pre-encrypt values in the
callers before batch assembly … the batch-append helpers stay synchronous and
simply accept already-encrypted bytes." That is not what the code does:

- `appendGenerationCounterBump` (`meta_store.dart:99`) is **already
  `Future<int>`** and computes its value **internally**: it does
  `await getGenerationCounter(...)`, increments, and puts `_encodeUint64(next)`
  into the batch. The caller never sees `next`, so it **cannot** pre-encrypt it
  at the call site. The read-modify-write (and the H2/D2 atomicity guarantee it
  encapsulates) lives inside the helper.
- `appendNamespaceRegistration` (`meta_store.dart:210`) is **already
  `Future<bool>`** and likewise computes the value internally
  (`await getNamespaces()`, append, `cbor.encode`). Same problem — the caller
  can't pre-encrypt a value it doesn't compute.
- Only `appendDirtyFlag` (`meta_store.dart:233`, `void`, writes the constant
  `[1]`) and `appendTombstoneFloorAdvance` (`void`, value passed in as an
  `Hlc` parameter) are genuinely synchronous.

Two consequences:

1. **The async-ripple concern (B3) was largely a false alarm.** The two
   confidentiality-relevant helpers — the generation counter and namespace
   registry, which are exactly the entries that leak collection names — are
   *already* async because they already `await _engine.get`. Adding
   `await ValueCodec.encode(...)` inside them is a mechanical, contained edit.
   Their read counterparts (`getGenerationCounter:65`, `getNamespaces:166`,
   which already `cbor.decode`) are async too — decrypt-in-place is mechanical.
   There is **no `WriteBatch`-API async ripple** for these, contrary to the
   block's framing.
2. **The prescribed design is the wrong one and is unimplementable for the two
   helpers that matter.** Correct approach: **encrypt/decrypt inside the
   existing async helpers** (`appendGenerationCounterBump`,
   `appendNamespaceRegistration`, and the read paths `getGenerationCounter`/
   `getNamespaces`; plus `putDeviceId:153`/`getDeviceId:144`, already async).
   For the two genuinely-synchronous `void` helpers, make a small, explicit
   choice: `appendDirtyFlag` writes a constant, so either encrypt a precomputed
   constant or make it `async` (it has few callers — `KvStoreImpl` first-write
   path); `appendTombstoneFloorAdvance` receives its `Hlc` as a parameter, so
   the caller *can* pre-encrypt, or make it `async`. This is the only place the
   "pre-encrypt at call site vs. make async" question is real, and it is a
   two-void-method decision, not a WriteBatch-wide one.

Action: rewrite Phase 2's B3 design block to (a) drop the incorrect
"all synchronous / pre-encrypt at call site" premise; (b) specify
encrypt-in-place inside the already-async helpers for the counter, namespace
registry, and device ID; (c) make the explicit small choice for the two `void`
helpers. Until this is corrected, an implementer would hit the contradiction at
the first helper and have to redesign on the fly — which is exactly the bar
`Investigated` is meant to clear.

**Status call:** Still **Questions**, but the gap is now narrow and fully
specified: fix B6 (a factual correction to one design block, with the
corrected approach spelled out above) and formally check off the remaining
recommendation-accept questions (Q2, Q3, Q4, Q5, Q7 — all have sound
recommendations and no unresolved sub-decisions once B6 lands). No further
investigation is needed; this is an editing pass, not a research pass. Once
B6 is corrected in Phase 2, this plan clears the implementation-readiness bar
and can move to `Investigated`.

**Response (coordinator, 2026-07-10):** Verified B6 directly against
`meta_store.dart` before writing the fix — confirmed
`appendGenerationCounterBump` (line 99) and `appendNamespaceRegistration`
(line 210) are already `Future`-returning with internal read-modify-write,
and `appendDirtyFlag` (line 233)/`appendTombstoneFloorAdvance` (line 334) are
the only genuinely-sync `void` methods, with the latter having zero
production callers. Rewrote Phase 2's B3 block: encrypt-in-place inside the
already-async helpers; converted `appendDirtyFlag` to `Future<void>` and
encrypted it too; left `appendTombstoneFloorAdvance` synchronous/unencrypted
as dead code. While rewriting, independently found and fixed a second bug:
the plan's blanket "route `getRawByName`/`putRawByName` through encryption"
instruction would have silently broken the `enc:blob` exemption (Q2), since
`getEncryptionBlob`/`putEncryptionBlob` call those same two methods
internally — fixed by routing them to `_engine.get`/`_engine.put` directly
instead.

### Pass 3 (kmdb-plan-reviewer, 2026-07-10)

B6 is resolved correctly (verified: `appendTombstoneFloorAdvance` has zero
production callers — only `meta_store_test.dart:368`; the live path is
`setTombstoneFloor` at `lsm_engine.dart:1128`/`kv_store_impl.dart:288`, and the
plan now encrypts that one while leaving the dead batch variant alone). The
`enc:blob` self-fix is also sound: `getEncryptionBlob`/`putEncryptionBlob` do
call `getRawByName`/`putRawByName` (`meta_store.dart:386`/`400`), so the
blanket-encrypt-those-accessors change *would* have broken the exemption;
switching them to `_engine.get`/`_engine.put` directly produces byte-identical
on-disk state (same key encoding) with no new gap. Good catch by the
coordinator.

But enumerating the `getRawByName`/`putRawByName` callers to check the
`enc:blob` fix surfaced a larger, still-unresolved problem that revises B4.

**B7 (new, blocking) — `ValueCodec` is `Map`-only; most values in Gaps 1 and 3
are not maps, so "route through `ValueCodec`" is not mechanically applicable
and B4's dichotomy is false.** `ValueCodec.encode` accepts only
`Map<String, dynamic>` (`value_codec.dart:92`) and `decode` returns only
`Map<String, dynamic>` (`:140`). There is **no raw-bytes entry point.** But
the majority of the values this plan puts in scope are scalars or opaque byte
blobs, not maps:

- **Gap 3 / `$meta`:** generation counter (`_encodeUint64`, a `uint64`),
  `device_id` (raw `codeUnits`), `dirty` (`[1]`), `gc:tombstoneFloor` (an
  `Hlc`), the `namespaces` registry (a CBOR *list*, not a map), and — via
  `getRawByName`/`putRawByName` — the opaque state blobs written by
  `IndexManager` (`_encodeState`, `index_manager.dart:473`), `FtsManager`
  (`FtsIndexState.toBytes`, `fts_manager.dart:1284`), `VecManager`
  (`VecIndexState`, `vec_manager.dart:796`), `SchemaManager`
  (`schema_manager.dart:152/247`), and `VersionManager`
  (`version_manager.dart:94`). **Note the blast radius:** flipping
  `getRawByName`/`putRawByName` to encrypt-by-default silently changes the
  on-disk encoding for *all six* of these consumers, not just the
  `index:{ns}:{path}` state the Phase 2 bullet names.
- **Gap 1 / FTS+Vec:** TF counts and corpus stats (ints), `VecManager`'s SQ8
  vectors (raw fixed-length `Uint8List`), corpus N (int). Only
  `_writeDocInfo` (`{n, t:[…]}`) and `_writeOverlayEntry` (`{term: tf}`) are
  genuinely map-shaped.

You cannot pass a `uint64`, an `Hlc`, a `FtsIndexState.toBytes()` blob, or a
raw SQ8 `Uint8List` to a `Map<String, dynamic>`-typed `ValueCodec.encode`. So
B4's chosen mechanism ("use `ValueCodec`, not a hand-rolled
`EncryptionProvider.encrypt` envelope") does not actually apply to most of the
plan's write sites, and B4's framing is a **false dichotomy**: the alternative
to `ValueCodec` is *not* "hand-roll a bespoke envelope." The codebase already
has a second, established encryption primitive for exactly this case —
**WI-10's `EncryptionFlag`-byte scheme** (`vault_search_manager.dart`
`writeExtractArtifact`/`readExtractArtifact`, lines ~195/239):
`[EncryptionFlag byte][nonce‖AES-GCM ciphertext‖tag]`, self-describing so
plaintext (`0x00`) and ciphertext (`0x01`) coexist. Its own doc comment notes
it is "consistent with the `ValueCodec` wire format, applied here to whole
files." That is an existing tested primitive, not re-rolling.

**What the plan must decide (currently unspecified):** a per-value-shape split.

1. **Map-shaped values** (`_writeDocInfo`, `_writeOverlayEntry`, and anything
   you're willing to wrap the way `VaultRefInterceptor` wraps its field path as
   `{'p': …}`) → `ValueCodec.encode/decode`. Wrapping a scalar in a throwaway
   `{'v': …}` map is a legitimate option but adds a CBOR-map layer per entry —
   call it out explicitly if chosen, and do **not** wrap the fixed-length SQ8
   vectors this way (it defeats the length-guard reasoning the plan already
   flags for `VecManager`).
2. **Scalar / raw-byte values** (SQ8 vectors, the int counters, the opaque
   `$meta`/index-state/schema/version blobs) → the `EncryptionFlag`-byte
   primitive. Since WI-10 currently inlines that logic in
   `writeExtractArtifact`/`readExtractArtifact`, **factor it into a shared
   helper** (e.g. `EncryptionEnvelope.wrap/unwrap(Uint8List, EncryptionProvider?)`)
   and have both WI-10 and this plan's byte-blob sites use it — otherwise the
   plan duplicates an encryption envelope, which cuts against CLAUDE.md's
   "prefer existing primitives / don't re-roll" guidance just as much as a
   from-scratch envelope would.

Until Phase 1's and Phase 2's bullets specify which values go through
`ValueCodec` vs. the `EncryptionFlag`-byte helper, an implementer hits a type
error at the first `ValueCodec.encode(counter)` and has to invent the mechanism
— a significant design decision, which is exactly the bar `Investigated` must
clear. Revise B4 accordingly (it is no longer a simple "yes, ValueCodec").

**B8 (should-address before implementation) — breaking on-disk format change
for existing databases has no stated migration stance.** Routing existing
`$meta`, index-state, schema, and version-config values through *any* framed
encoding (encrypted or the `EncryptionFlag.none`/`ValueCodec` unencrypted
framing, which still prepends flag/compression bytes) changes their on-disk
bytes. A database created by today's code stores these as bare CBOR with no
leading flag byte; after this change the read path expects a frame. This
affects **every existing database, not just encrypted ones**, and several of
these values are authoritative and *not* rebuildable — `device_id` in
particular (a changed device identity breaks sync continuity), plus the
`namespaces` registry and generation counters.

The self-describing `EncryptionFlag`-byte scheme does not save you here: a
legacy bare-CBOR value has no flag byte, so its first CBOR byte would be
misparsed as a flag (WI-10's `EncryptionFlag.fromByte` throws `ArgumentError`
on an unrecognised leading byte). State the stance explicitly:

- **Recommended, and consistent with precedent:** treat this as a pre-v1-beta
  breaking format change — pre-existing databases are not migrated and must be
  recreated. This matches the Phase 12 encryption precedent (no in-place
  migration path) and is acceptable this far before the beta. But it must be
  *written down* (a note in the plan and in §31/the release checklist), and the
  read path must fail **cleanly** (clear error) rather than silently misparse a
  legacy value as encrypted garbage — especially for `device_id`.
- If instead in-place read-compat is required, that is a materially larger
  design (version-gated dual-format reads for every `$meta` entry) and needs
  its own investigation — flag it to the user before proceeding.

This is "should-address" rather than hard-blocking only because the recommended
answer is a one-paragraph policy statement plus a clean-failure test; but it
must not be left implicit.

**Status call:** Still **Questions**. B6 and the `enc:blob` fix are correct.
B7 is a genuine blocker — the plan's core encryption mechanism ("route
through `ValueCodec`") is not applicable to most of its own write sites, and
the correct split (plus factoring WI-10's envelope into a shared helper) is
an unmade design decision. B8 needs a one-paragraph migration stance and a
clean-failure guarantee. Once B7 is specified into Phase 1/Phase 2 (revising
B4) and B8's stance is recorded, and Q2–Q5/Q7 are checked off, this reaches
`Investigated`. The investigation remains strong; these are
mechanism-specification gaps, not research gaps.

**Response (coordinator, 2026-07-10):**

- **B7**: read the actual write sites (`fts_manager.dart`, `vec_manager.dart`,
  `vault_bm25_writer.dart`, `vault_extraction_state.dart`) before writing the
  fix, to categorise each value's real shape rather than guess. Added a new
  "Phase 0 — B7" design block specifying the per-value-shape split
  (map-shaped → `ValueCodec`; scalar/opaque-byte-blob → a new shared
  `EncryptionEnvelope.wrap`/`unwrap` helper factored out of WI-10's inlined
  pattern in `writeExtractArtifact`/`readExtractArtifact`, which are
  refactored to use it). Phase 1 and Phase 2's bullets rewritten to name the
  mechanism per value. Phase 2's B4 block is marked superseded: since every
  Gap 3 `$meta` value turned out to be scalar/list/blob-shaped, `MetaStore`
  ends up needing `EncryptionEnvelope` only, not `ValueCodec` — so it never
  becomes an engine→encoding-layer importer, dissolving the original B4
  question rather than answering it as first framed.
- **B8**: added an explicit "B8 — migration stance" checklist item to Phase
  2 — pre-v1-beta breaking format change, no migration path (matches the
  Phase 12 precedent), existing databases must be recreated, with a required
  clean-failure test for legacy unframed values (`device_id` specifically
  called out as the highest-risk silent-misparse case). Added a Phase 5
  bullet to record this in §31 and the release checklist. (Later shown to be
  unsound and corrected in Pass 4/B9.)

### Pass 4 (kmdb-plan-reviewer, 2026-07-10)

B7 is resolved well — the per-value-shape categorisation was done against the
actual write sites, the `ValueCodec`-vs-`EncryptionEnvelope` split is correct,
placing `EncryptionEnvelope` in `lib/src/encryption/` (not `encoding/`) is the
right call, and factoring WI-10's inlined pattern into the shared helper (with a
before/after regression test) is exactly right. The B4-dissolves-via-B7
reasoning is sound: since every Gap 3 value is scalar/list/blob-shaped,
`MetaStore` needs only `EncryptionEnvelope` and never becomes an
engine→encoding importer. Good work, and good instinct verifying shapes in the
code rather than trusting the reviewer's summary.

Two things remain — one a real blocker, one a small consistency fix.

**`EncryptionEnvelope` `encryption == null` case — the coordinator's instinct
is correct.** `wrap(bytes, null)` should emit `[EncryptionFlag.none (0x00)]
[bytes]` — a flag-prefixed *plaintext* value — mirroring both WI-10's
`writeExtractArtifact` and `ValueCodec.encode(..., encryption: null)` (which
always writes `[encFlag=0x00][compressionFlag][cbor]`). Keeping the flag byte
even when plaintext is what makes the two primitives wire-consistent and is the
posture `EncryptionFlag.fromByte`'s throw-on-unknown already assumes. Spell this
out explicitly in the Phase 0/B7 block (the wire format for both the `null` and
the provider-present cases), plus the empty-plaintext edge (`wrap` of a
zero-length payload — relevant if Q3 ever encrypts an empty `$$index:` value),
and the "encrypted value read with no provider" case (unwrap of a `0x01` value
when `_encryption == null` → throw, matching WI-10's `StateError`). These are
edge-case specifications, not design decisions, so they don't block — but name
them so the implementer doesn't have to infer them.

**B9 (new, blocking) — B8's clean-failure guarantee does not hold; a legacy
CBOR byte *can* collide with a valid `EncryptionFlag`.** B8 says the read path
will "fail cleanly on a legacy unframed value rather than misparse its first
CBOR byte as a flag — confirm `EncryptionFlag.fromByte` throws." **It won't
throw for the most common case.** Verified: `EncryptionFlag` is `none(0x00)` /
`aesGcm(0x01)`, and `fromByte` throws only for bytes *other than* `0x00`/`0x01`
(`encryption_flag.dart:61–64`). But by CBOR (RFC 8949 §3), an unsigned integer
0–23 encodes as a **single byte equal to the value** — so a legacy bare-CBOR
generation counter of value `0` is exactly the byte `0x00`, and value `1` is
exactly `0x01`. Those are precisely the two valid flag bytes. `fromByte` will
**not** throw; it will happily parse the counter as an `EncryptionFlag.none`
(value 0) or `aesGcm` (value 1) frame and silently return the wrong bytes.
Generation counters of 0 and 1 are the *most common values in the store*
(every freshly-registered namespace starts there), and the `dirty` flag (raw
`[0x01]`) collides too.

The device_id case the plan singles out actually fails *safe* — device IDs are
ASCII hex, first byte `0x30`–`0x66`, never a valid flag, so `fromByte` throws as
hoped. The plan picked the one value that self-protects and missed the ones that
don't. Per-value flag validation is structurally incapable of distinguishing a
legacy CBOR `0x00`/`0x01` from a real flag byte, so B8's guarantee as written is
unsound and the device_id-only test would pass while a counter=0 silently
corrupts.

**Fix: gate the format break at the database level, at `open()`, not per
value.** Detect a pre-this-plan database once at open — e.g. a `$meta`
format-version marker whose *absence* means "legacy, pre-envelope format" — and
refuse to open (clear, actionable error directing the user to recreate, per the
B8 "no migration" stance) **before** any individual `$meta`/index value is read
through `EncryptionEnvelope.unwrap`. This is a standard version-gate (cf. the
Manifest version and WI-1's model-identity check) and makes the "recreate the
DB" stance actually enforceable and safe, instead of relying on a per-value
heuristic that provably misfires on the commonest values. Update B8's checklist
item and its test accordingly: the regression test should assert that opening a
legacy-format database fails cleanly *at open*, and should include a
counter-valued-0/1 case, not just device_id.

**Minor — the "byte-for-byte unchanged" test in Phase 1 now contradicts B8.**
Phase 1's test bullet still says "confirm unencrypted-database behavior is
byte-for-byte unchanged (encryption is opt-in)." Under the chosen design that is
false: for the modified write sites, an unencrypted database's values move from
bare `cbor.encode` to either `ValueCodec` framing or `EncryptionEnvelope`'s
`[0x00]`-prefixed framing — both change the on-disk bytes even with no provider
(this is exactly the format break B8 owns). Reword to what is actually true and
testable: *a freshly created unencrypted database round-trips correctly through
the new framing and produces identical query results* — not that its bytes match
the pre-plan format. (Leaving the old wording would send the implementer chasing
a test that cannot pass.)

**Status call:** Still **Questions**. Genuinely close. B1–B8 are resolved and
the design is now coherent and well-specified. The remaining blocker is
narrow and concrete:

- **B9 (blocking):** replace B8's per-value flag-validation clean-failure
  mechanism with a database-level format-version gate at `open()`; a
  legacy CBOR `0x00`/`0x01` (counter values 0/1, the `dirty` flag) collides
  with a valid `EncryptionFlag` and is silently misparsed by the current
  approach. Update the B8 item, its stance text, and its test (add a
  counter=0/1 case; assert clean failure at open).
- **Minor (non-blocking):** correct Phase 1's "byte-for-byte unchanged" test
  bullet, and spell out `EncryptionEnvelope`'s `null` / empty / no-provider
  edge cases in the Phase 0/B7 block.

Fix B9 (a ~one-item rewrite with the mechanism spelled out above) and this
clears `Investigated` — no further review round should be needed. The minor item
can ride along in the same edit. The investigation and design are otherwise
implementation-ready.

**Response (coordinator, 2026-07-10):**

- **`EncryptionEnvelope` edge cases**: spelled out explicitly in the Phase
  0/B7 block — `wrap(bytes, null)` → `[0x00][bytes]` (flag-prefixed
  plaintext), `wrap(bytes, provider)` → `[0x01][nonce‖ciphertext‖tag]`,
  zero-length payload round-trips, and `unwrap` of an encrypted value with
  no provider throws (matching WI-10's `StateError`).
- **B9**: replaced the per-value `EncryptionFlag.fromByte`-throws guarantee
  (shown to silently misparse legacy counter values 0/1, which collide with
  the two valid flag bytes under CBOR's small-int encoding) with a
  database-level format-version marker in `$meta`, checked once at `open()`
  before any framed value is read anywhere (not just `$meta` — this also
  covers Gap 1's `$$fts:`/`$$vec:`/`$$vault:*` namespaces). Absence of the
  marker means a legacy database; `open()` refuses cleanly rather than
  attempting any per-value read. Test requirement updated to include a
  counter=0/1 case specifically, not just `device_id`. (The marker's
  new-vs-legacy discrimination itself had one more gap, closed in Pass 5.)
- **Minor**: Phase 1's "byte-for-byte unchanged" test bullet reworded to
  what's actually true — a freshly created unencrypted database round-trips
  correctly through the new framing and produces identical query results;
  the old bytes-match-pre-plan-format claim is false under this design and
  removed.

### Pass 5 (kmdb-plan-reviewer, 2026-07-10): promoting to Investigated

B9's fix is sound: the `$meta` format-version marker on a raw path (no
chicken-and-egg), checked at `open()` before any framed read across `$meta`
*and* Gap 1's `$$fts:`/`$$vec:`/`$$vault:*` namespaces, is the right,
enforceable mechanism, and the counter=0/1 test requirement targets the exact
collision case. The `EncryptionEnvelope` edge cases and the Phase 1 test
rewording are both correct.

One remaining soundness gap was found and closed **in the B9 marker mechanism
itself**: the rule was stated as "absence of marker ⇒ legacy ⇒ refuse," but a
brand-new database also has no marker until `open()` writes it. Taken
literally that breaks new-database creation; the natural "fix" (write the
marker whenever missing) would silently re-admit legacy databases and defeat
the entire gate — reintroducing the very silent-corruption risk B9 exists to
prevent. The explicit three-way discrimination was added to the Phase 2
B8/B9 item: marker written once at creation (detected by the §17 "no
`CURRENT`/manifest" brand-new signal); absent-with-persisted-state ⇒ legacy ⇒
refuse; absent-and-empty ⇒ new ⇒ write and proceed — mirroring the existing
`cannotProvisionNonEmptyDatabase` empty-vs-populated check. Plus a
complementary test that an empty database opens and writes the marker.

The five remaining open questions (Q2–Q5, Q7) are resolved and recorded: Q2
(enc:blob unchanged, enforced by the direct-path fix), Q3 (leave `$$index:`
empty), Q4 (HKDF sub-key), and Q5 (rebuild on format-version mismatch) are
reviewer-endorsed technical calls; Q7 (Drive CLI creds out of scope) is
reviewer-recommended and accepted per the coordinator's direction to advance,
with a note that the user may reopen it. Q1/Q6/Q8 were the user's.

**Assessment against the Investigated bar:** the problem statement and threat
model are correct; the design names every file/class/method, the two-primitive
per-value split, the `EncryptionEnvelope` wire format and edge cases, the
`MetaStore` encrypt-in-place approach, the `enc:blob` raw-path carve-out, the
format-version gate with full new/legacy/empty discrimination, Gap 2's HMAC
tokens + `tokenMode` rebuild, and Gap 4's in-place `originalName` fix; the
checklist is ordered and discrete; and the testing strategy covers the failure
and durability paths (bootstrap ordering, crash recovery via
`FaultyStorageAdapter`, legacy-open clean failure incl. the counter=0/1
collision, post-decryption corruption guard, benchmark P99, and multi-device
harness convergence), with the non-automatable items routed to §31 and the
release checklist. No open questions remain and no design decision is left for
the implementer to improvise.

**Status → Investigated.** This took five passes because each pass surfaced a
real defect — a wrong threat model, an unspecified async ripple, an impossible
migration scenario, a `ValueCodec`-can't-take-bytes mismatch, a CBOR/flag
collision, and finally the marker's new-vs-legacy discrimination — but every one
is now closed with a concrete, code-grounded resolution. The plan is ready for
the `kmdb-plan-implement` agent.

## Summary

{Dot points highlighting the work undertaken — fill in once implementation is
complete.}
