# KMDB Release-Readiness Review — 2026-07-18

**Reviewer:** Claude (Opus 4.8), full-codebase review
**Status:** 🔴 **Executed — `0.1.0` NO-GO.** Security and durability workstreams
complete; spec conformance (W1) **partially executed 2026-07-20** — tiers 1–3
audited, tiers 4–6 surveyed only (see §9 coverage and §11)
**Target:** `0.1.0` — the first non-prerelease tag
**Baseline:** `main` @ `a933dc4` ("Review and reconcile the spec, retire the
primer, and prep the workspace for a real release")

**Focus per request:**

1. The features described in `docs/spec` are **implemented correctly**.
2. Encryption provides a **reliable model for securing user data**, at rest and
   in transit.
3. FFI implementations are **memory-safe and race-free**.

Plus: likely bugs and improvement opportunities generally, and anything that
should block a `0.1.0` tag.

---

## 0. Executive summary

**Recommendation: do not tag `0.1.0` yet.** Six critical findings, five of them
sharing a single root cause.

KMDB is a well-built system. The analyzer is clean across all nine packages,
2,373 core tests pass, the CLI works correctly end-to-end with accurate exit
codes, the FFI layer is free of memory-safety and race defects, and the
cryptographic primitives — nonce management, Argon2id parameters, HKDF usage,
passphrase intake, the POSIX credential store — are, on inspection, **right**.
Several areas I expected to yield findings yielded none, and those are recorded
as explicit passes (E-3, C-3, F-2, L-2) rather than silence.

**The problem is not primitive quality. It is a boundary assumption.**

Everything inside the sync folder is treated as trustworthy *because it is in
the sync folder*. SSTables, vault blobs, vault manifests, and consolidation
leases are all parsed, obeyed, and acted upon as though this codebase wrote
them. That assumption is entirely coherent under the threat model §31 actually
documents — a provider who **reads** your data — and it is indefensible under
the model specified for this release, in which the provider and peer devices can
also **write**.

That single assumption produces five of the six criticals:

- **S-1** — crafted SSTable fields crash `pull()` permanently (confirmed,
  reproduced end-to-end)
- **S-2** — a Zstd frame declares its own decompressed size; ~32,000×
  amplification measured, no cap anywhere (confirmed)
- **S-4** — the content-addressable vault never checks content against its
  address, and the flag gating decryption is attacker-supplied
- **S-6** — `commit()` deletes every path named in an unauthenticated lease,
  using the victim's own credentials
- **E-2** — AES-GCM without AAD, so ciphertext is not bound to where it lives

and **E-1** is the assumption itself: the spec's threat model is passive-only
and never claims the synced data is authentic.

The reason the test suite could not catch any of this is structural, and it is
the same reason the 2026-05-22 review gave: **every parser test feeds the parser
well-formed output this codebase produced**, and the in-memory adapter
bounds-checks where the native adapter does not, hiding the worst failures.
The one negative test uploads 64 bytes of `0xAB` — exercising the single path
that *is* handled correctly.

The most telling detail: `ManifestReader` and the WAL reader validate lengths
before slicing and checksum before parsing. They are **local-only** formats. The
SSTable — the *only* format that crosses between devices — is the unvalidated
one. This is validation written against disk corruption and never revisited when
sync made the same parser adversary-facing.

**What this means for the release.** S-1, S-2, S-6 and S-7 should be fixed
regardless of threat model — corruption, buggy peers, and Windows exist without
any attacker. But E-1 is a **product decision, not an engineering task**:
authenticating synced data needs a MAC or signature over SSTables, blobs, leases
and high-water marks, plus key distribution and device revocation. That is a
design cycle. §7.3 lays out three honest options; my recommendation is to ship
with a **narrowed, prominently-stated claim** and commit publicly to closing the
gap in a named later release — the one thing that must not happen is prose
implying protection against a hostile provider while the implementation assumes
a polite one.

**Also blocking, unrelated to security:** the `0.1.0` dependency gate (O-1) is
not met — all 12 packages in the `betto_*` closure are still `-dev`, one of them
(`betto_abnf`) is undocumented, and 11 of 12 have unpublished local work ahead
of what KMDB currently builds against.

> **Coverage caveat:** the security workstreams (W2, W3), concurrency/durability
> (W4), and the CLI smoke test are complete. **Spec conformance (W1) is
> partially executed** (2026-07-20): tiers 1–3 audited to depth, tiers 4–6
> surveyed only — roughly 40% of the spec surface. See §9 and §11.

> **W1 addendum (2026-07-20).** Eight conformance findings (SC-1…SC-8), three
> of them 🟠 High. The one that matters most is **SC-1**: §31 documents a
> verification of the cached DEK against `enc:blob` that **does not exist**, so
> a wrong passphrase opens an encrypted database whenever a `DekCache` is warm
> — reproduced. The other two Highs are documentation defects with real
> consequences: **SC-2** (§31 still specifies the vault blob format PR #61
> replaced, and still describes the S-4-vulnerable read as current) and
> **SC-3** (§15's materialised view cache, marked *Required* on mobile and web,
> is not implemented anywhere). Encouragingly, **PR #61's own spec edits are
> accurate** (SC-9) — the drift is concentrated in sections nobody has had
> reason to re-read.

---

## 1. Why this review exists

`0.1.0` is a threshold release. Everything shipped so far has been `-dev.N`,
where the implicit contract with users is "expect breakage." A `0.1.0` tag
changes that contract in three ways that matter for the review:

1. **The on-disk format becomes a promise.** Up to now, format changes have
   been made freely — the encryption reconciliation work (0.08) shipped a
   breaking format change with no migration path, which was correct at the time.
   After `0.1.0`, a format change that silently misreads old data is a
   data-loss bug, not a version bump.
2. **The security claims become load-bearing.** A user who reads
   [§31](../spec/31_encryption.md) and concludes their data is safe on an
   untrusted cloud provider is making a decision based on our documentation. If
   the implementation is weaker than the spec, the gap is a vulnerability, not
   a TODO.
3. **The spec becomes the contract.** `docs/spec` is 10,728 lines across 34
   sections. Anything in it that isn't true is a defect against `0.1.0`.

The last full review (`code-review-2026-05-22.md`) asked "can users trust KMDB
not to destroy their data?" and answered **no**, on the strength of a confirmed
silent data-loss bug plus a test suite structurally unable to detect that class
of problem. That track (`docs/roadmap/0_02_01.md`) is now closed. This review
asks the next question:

> **Can users trust KMDB to keep their data private, correct, and complete —
> and does it do what the spec says it does?**

---

## 2. Scope

### 2.1 In scope

| Area | Packages / paths |
| :--- | :--- |
| Core library | `packages/kmdb` (38,136 LOC lib) |
| CLI | `packages/kmdb_cli` (12,939 LOC lib+bin) |
| Test harness | `packages/kmdb_harness` |
| Specification | `docs/spec/*.md` (34 files, 10,728 lines) |
| Release process | `docs/releasing/`, `docs/spec/28_release_checklist.md` |

### 2.2 Also in scope — **resolved 2026-07-18: the whole workspace ships in `0.1.0`**

| Area | Packages | Note |
| :--- | :--- | :--- |
| Cloud adapters | `kmdb_google_drive`, `kmdb_icloud` | The in-transit half of the security question lives here |
| Extractors | `kmdb_extractor_{pdf,html,markdown}` | Parse untrusted blobs; `pdf` wraps native code |
| Flutter add-on | `kmdb_flutter` | Holds the DEK session cache — security-relevant |

Consequence: nine packages ship under the `0.1.0` promise, including two that
were previously described as "optional, opt-in." Opt-in is a packaging fact, not
a quality exemption — a shipped adapter that mishandles credentials is a
`0.1.0` defect. O-2 (`kmdb_flutter` absent from the workspace list, so in no
described CI lane) is upgraded from a curiosity to something that needs an
answer before release.

### 2.3 FFI reality check — **resolved 2026-07-18: option (b)**

**There is no `dart:ffi` in this repository.** A survey of all nine `packages/`
found only two files touching native/isolate concepts, both in the vault search
isolate:

- `packages/kmdb/lib/src/vault/search/vault_search_manager.dart`
- `packages/kmdb/lib/src/vault/search/vault_indexing_isolate.dart`

All actual FFI lives in external `betto_*` packages, published to pub.dev and
pinned via `dependency_overrides`. Each is a separate repository (all checked
out locally under `/Users/gonk/development/bettongia/`):

| Package | FFI files | Reached from KMDB via | Risk profile |
| :--- | :--- | :--- | :--- |
| `betto_zstd` | 3 | **Core write path** — every compressed value | 🔴 Highest. On the hot path for all data. A memory bug here corrupts the database. |
| `betto_icu` | 2 | `betto_lexical` → BM25 tokenizer → FTS | 🟠 Every indexed document's text passes through it |
| `betto_pdfium` | (workspace) | `kmdb_extractor_pdf` | 🟠 Parses **untrusted** PDF bytes natively |
| `betto_onnxrt` | (workspace) | `betto_inferencing` → semantic search | 🟡 Model inference; large native surface |

So "review the FFI" means reviewing **other repositories**. That is a defensible
thing to do — a memory-corruption bug in `betto_zstd` is a KMDB data-integrity
bug regardless of which git repo it lives in.

**Resolved:** review the internals of **`betto_zstd` and `betto_icu`** (the two
on KMDB's hot paths), plus **`betto_pdfium`'s input-validation boundary** —
where untrusted PDF bytes cross into native code — without auditing PDFium's
internals. `betto_onnxrt` is treated as trusted: it processes model files and
already-extracted text rather than adversary-controlled input, and its native
surface is far too large to audit meaningfully within this review. That
exclusion is a **recorded risk acceptance**, not a clean bill of health.

### 2.4 Explicitly out of scope

- `kmdb_ui` (separate repository, separate release).
- The consumer iOS companion plugins (`betto_onnxrt_ios`, `betto_pdfium_ios`).
- The `0.10` Integration Guide work in flight
  (`docs/plans/plan_0_10_integration_guide.md`) — reviewed only where it makes a
  claim about current behaviour.

---

## 3. Preliminary observations

These surfaced while scoping, before the review proper. Each is marked
**verified** or **unverified**; unverified items are leads recorded so they are
not lost, and will be confirmed or dismissed during the workstream that owns
them.

### O-1 — the `betto_*` prerelease closure 🟠 → **release gate (confirmed 2026-07-19)**

Originally raised as an open question; the maintainer (who owns all `betto_*`
packages, published under
[pub.dev/publishers/bettongia.com](https://pub.dev/publishers/bettongia.com/packages))
has confirmed it as a **hard release gate**:

> A `0.1.0` release of KMDB requires that all direct **and indirect** `betto_*`
> dependencies have a `0.1.0` release with no dev-snapshot suffix.

**The closure is 12 packages.** Verified against every `pubspec.yaml` in the
workspace, then transitively through each `betto_*` package's own manifest, and
cross-checked against `pubspec.lock` and the pub.dev API on 2026-07-19:

| Package | Reached via | Resolved & published | Local HEAD | Δ |
| :--- | :--- | :--- | :--- | :-: |
| `betto_common` | direct (`kmdb`) | `0.1.0-dev.2` | `0.1.0-dev.3` | ⬆ |
| `betto_schema` | direct (`kmdb`) | `0.1.0-dev.2` | `0.1.0-dev.3` | ⬆ |
| `betto_abnf` | **indirect** — via `betto_schema` | `0.1.0-dev.2` | `0.1.0-dev.3` | ⬆ |
| `betto_zstd` | direct (`kmdb`) | `0.1.0-dev.3` | `0.1.0-dev.4` | ⬆ |
| `betto_icu` | **indirect** — via `betto_lexical` | `0.1.0-dev.2` | `0.1.0-dev.3` | ⬆ |
| `betto_lexical` | direct (`kmdb`) | `0.1.0-dev.2` | `0.1.0-dev.3` | ⬆ |
| `betto_inferencing` | direct (`kmdb`, `kmdb_cli`) | `0.1.0-dev.3` | `0.1.0-dev.3` | — |
| `betto_onnxrt` | **indirect** — via `betto_inferencing` | `0.1.0-dev.1` | `0.1.0-dev.2` | ⬆ |
| `betto_pdfium` | direct (`kmdb_extractor_pdf`) | `0.1.0-dev.3` | `0.1.0-dev.4` | ⬆ |
| `betto_mediatype_detector` | direct (`kmdb`) | `0.1.0-dev.1` | `0.1.0-dev.2` | ⬆ |
| `betto_charset_detector` | direct (`kmdb`) | `0.1.0-dev.2` | `0.1.0-dev.3` | ⬆ |
| `betto_lang_detector` | direct (`kmdb`) | `0.1.0-dev.1` | `0.1.0-dev.2` | ⬆ |

Three consequences, in ascending order of importance:

**(a) `betto_builder_tools` is *not* in the gate.** It appears in `betto_lexical`,
`betto_mediatype_detector`, and `betto_lang_detector` — but in all three it sits
under `dev_dependencies:`, so it never reaches a consumer's resolution. It does
not need a `0.1.0` release. Worth stating explicitly so no effort is spent
publishing it.

**(b) `betto_abnf` is missing from the project's own documentation.** It is a
transitive dependency of the **core `kmdb` package** (via `betto_schema`), yet it
does not appear in `CLAUDE.md`'s "External Bettongia packages" list, nor in the
workspace `dependency_overrides`. It is in the release gate by the rule as
stated. An undocumented package in the core dependency path is exactly the kind
of thing that gets missed when someone works down a checklist of *documented*
dependencies.

**(c) 🔴 The review will validate a combination that does not ship.** This is the
significant one. Published latest == resolved version for all 12 — but **11 of
12 have unpublished local work ahead of what KMDB builds against today.** The
`0.1.0` releases will presumably be cut from local HEAD or later, and KMDB's
pins must then move to `^0.1.0`. So:

> The KMDB code this review examines is compiled against `betto_zstd 0.1.0-dev.3`,
> but will *ship* against `betto_zstd 0.1.0`, which does not exist yet and will
> be cut from a tree that is already one version ahead.

Reviewing the FFI in `betto_zstd` `dev.3` would therefore audit code that never
reaches users; reviewing local HEAD audits code KMDB has never been tested
against. Neither alone is sufficient. **Mitigation (added to W3 and W6):** review
local HEAD as the release candidate, diff `dev.3 → HEAD` (and equivalently for
`betto_icu`) to see whether the delta touches FFI or format code, and treat
"re-run KMDB's full suite against the promoted `^0.1.0` pins" as a mandatory
release-gate step rather than a formality. If that re-resolution is left to the
end, a dependency bump lands *after* the last green test run — which is how
release regressions happen.

### O-1b — dependency pins are inconsistent across the workspace 🟡 *(verified)*

`kmdb_flutter` and `kmdb_icloud` pin `betto_common`, `betto_schema`,
`betto_lexical`, and `betto_inferencing` at `^0.1.0-dev.1`, while `kmdb` pins
`dev.2`/`dev.3`. Caret ranges make these compatible when co-resolved — but
neither package is in the Dart workspace (see O-2), so they resolve
*independently* and can pick different versions than the core. Now that both
ship under `0.1.0` (§2.2), the pins should be reconciled.

### O-2 — `kmdb_flutter` is absent from the workspace with no explanation 🟢 *(verified)*

The root `pubspec.yaml` `workspace:` list omits both `kmdb_icloud` and
`kmdb_flutter`. There is a detailed comment explaining *why* `kmdb_icloud` is
excluded (Flutter SDK unavailable on Dart-only CI runners) — but it never
mentions `kmdb_flutter`, which is excluded for presumably the same reason. Minor
drift, but it means `kmdb_flutter` is in no CI lane described by that comment.
Worth confirming it is tested somewhere.

### O-3 — `make pre_commit` does not test the CLI *(verified — documented in CLAUDE.md)*

Already documented in `CLAUDE.md`: `pre_commit_test` is `scope: [kmdb]`. For a
release where "the CLI should be fully functional," the gate that developers
actually run validates none of the CLI's 12,939 lines. This is a known-and-
documented limitation rather than a bug, but it shapes where I expect to find
CLI defects.

### O-4 — The vault indexing isolate postdates the last review *(unverified)*

`vault_indexing_isolate.dart` is the only genuine parallelism in a system whose
spec (§18) describes a **synchronous, single-threaded** concurrency model with
compaction on the write path. A new concurrency surface introduced after the
durability-hardening track closed deserves specific scrutiny — see W4.

---

## 4. Review approach

The codebase is too large to review linearly with useful depth (38k lines of
library, 47k lines of test, 10.7k lines of spec). The review is therefore
organised into **six workstreams**, ordered so that findings which could block
the release surface earliest.

Each workstream produces findings in the §6 register. Workstreams W1–W3 address
the three focus areas named in the request; W4–W6 cover the "likely bugs and
improvements" remit.

### W1 — Spec conformance audit 🎯 *focus area 1*

**Question:** does the implementation do what `docs/spec` says?

**Method.** Extract every *normative* claim from the spec — MUST/always/never
statements, byte-layout tables, state machines, ordering guarantees, numeric
thresholds — and trace each to (a) the implementing code and (b) a test that
would fail if it were violated. A claim with code but no test is a finding; a
claim with neither is a bigger one.

**Priority order** (highest-consequence-if-wrong first):

1. §31 encryption, §24 vault, §12 sync — data confidentiality and multi-device
   correctness
2. §05 value encoding, §07 WAL, §08 SSTable, §10 manifest — on-disk formats
   that `0.1.0` freezes
3. §11 KvStore, §17 crash recovery, §18 concurrency — the durability contract
4. §13 query API, §16 secondary indexes, §25 schemas, §26 versioning
5. §20–23 text search, §32 vault search
6. §29/§30 cloud adapters, §33 CLI credential store, §19 platform

**Output.** A conformance matrix: spec section → claim → code site → test site →
verdict (`conformant` / `untested` / `divergent` / `unimplemented`).

**Special attention:** the spec was reviewed and reconciled in `0.09` (the
commit this review baselines on). That reduces the chance of *stale* spec, but
it raises a different risk — a reconciliation pass can resolve drift by editing
the spec to match the code, including where the *code* was wrong. I will spot-
check the `0.09` reconciliation diffs for claims that were weakened rather than
fixed.

### W2 — Security and cryptography 🎯 *focus area 2*

**Question:** is the security model sound, and does the implementation deliver
it?

#### The threat model I am auditing against (resolved 2026-07-18)

All four candidate adversaries are in scope. Their union is the strongest of the
options offered, and it is worth being explicit about what that commits us to:

| # | Adversary | Capability | Drives |
| :-- | :--- | :--- | :--- |
| T1 | Untrusted cloud provider | **Read and write** the sync folder | W2c untrusted-input parsing; W2b metadata leakage; ciphertext-tampering resistance |
| T2 | Honest-but-curious provider | Read stored data and metadata; no tampering | W2b metadata leakage (filenames, sizes, timing, topology) |
| T3 | Malicious peer device | Push crafted SSTables that other devices parse and trust | W2c — the highest-yield area in the review |
| T4 | Device theft | Physical possession of a powered-off device | W2a at-rest key hierarchy, KDF cost, DEK cache exposure |

T1 and T3 are **active** adversaries: they can write bytes this device will
parse. That is a materially stronger claim than at-rest encryption, and it makes
parser hardening (W2c) a first-class security property rather than a robustness
nicety. Under T1+T3, every `.sst` file, vault blob, `.hwm` file, and lease file
arriving from the sync folder is **adversary-controlled input**, and the SSTable
reader — written on the assumption it parses files this codebase produced — is
the primary attack surface.

> **Expected finding, stated up front so it isn't mistaken for a discovery
> later:** §31's documented threat model may well be narrower than T1+T3. The
> spec has an honest "Known gaps and unprotected surfaces" section, which
> suggests the authors scoped it deliberately. If the documented model is
> weaker than the model you have just told me you intend, **that gap is itself a
> finding** — and probably a `0.1.0` blocker, because the spec is what users
> will base their trust decision on. I will report the delta between intended
> and documented model separately from the delta between documented model and
> code.

Split into five sub-areas:

**W2a — Cryptographic construction.** The failure modes that matter for
AES-256-GCM and the surrounding key hierarchy:

- **Nonce management.** Nonce reuse under GCM is catastrophic — it leaks
  plaintext XOR *and* enables forgery via authentication-key recovery. Determine
  the nonce strategy (random-96 vs. counter) and prove uniqueness holds across:
  re-encryption of the same record, compaction rewriting values, multi-device
  writes under the same DEK, crash-and-resume, and DEK reuse after restore.
- **AAD binding.** Is ciphertext bound to its context (namespace, key, sequence)?
  If not, a party with write access to the sync folder can relocate a valid
  ciphertext to a different key — a cut-and-paste attack that passes
  authentication.
- **Flag-byte integrity.** §05 puts a 1-byte flag prefix on every value and §31
  adds an encryption flag. If that byte is outside the authenticated envelope,
  can an attacker clear it to force plaintext interpretation, or flip
  compression bits to induce a decompression fault?
- **KDF parameters.** Argon2id memory/time/parallelism against current guidance;
  salt uniqueness and storage; behaviour on memory-constrained mobile.
- **Key lifecycle.** DEK wrap/unwrap; whether key material is zeroised after use
  (and whether that is even achievable in Dart — if not, say so in the spec);
  the DEK session cache's exposure (§31 "DEK Cache", and `kmdb_flutter`'s
  `FlutterSecureDekCache`).
- **Recovery code.** Entropy, encoding, and whether it is a second path to the
  same KEK — i.e. does it weaken the passphrase path to its own strength?
- **Downgrade and rollback.** The §31 "Database Format-Version Gate" and
  "Provisioning Guard" exist to stop an attacker presenting an unencrypted or
  older-format database. Verify they cannot be bypassed.

**W2b — Confidentiality boundary honesty.** §31 has a "Threat Model &
Confidentiality Boundaries" section with an explicit "Known gaps and unprotected
surfaces" subsection — good practice, and the 0.08 reconciliation work exists
precisely because an earlier claim ("every namespace encrypted") was false. I
will re-derive the boundary from the code rather than the prose, and check for
**metadata leakage the spec does not currently admit**: SSTable filenames encode
device ID and HLC timestamps (leaking write timing and device topology to
anyone who can list the sync folder); Bloom filter blocks and index blocks;
value lengths; the manifest; `$meta` generation counters; the HMAC namespace
tokens' resistance to offline dictionary attack over a small namespace space.

**W2c — Untrusted input parsing.** This is the attack surface most likely to
yield real findings. Via sync, **a peer device or anyone with write access to
the cloud folder can place arbitrary bytes into a `.sst` file that this device
will parse.** Same for vault blobs and extractor inputs. For every parser
(SSTable reader, WAL reader, manifest/`VersionEdit` CBOR, KVLT vault packages,
highwater JSON, lease JSON):

- Length fields used to allocate or slice **before** validation → OOM or
  out-of-bounds
- Checksum verified **after** structural parsing rather than before
- Decompression bombs — is there a decompressed-size cap on the Zstd path?
- CBOR nesting/size bombs
- Path traversal from any remote-supplied name (blob IDs, SSTable filenames,
  vault paths)
- Hash confusion in the content-addressable vault

**W2d — In-transit security.** TLS enforcement and certificate handling in the
cloud adapters; OAuth token acquisition, storage, refresh, and revocation;
credential file permissions (§33, and the recent hardening commit `3b87940`);
whether secrets can reach `argv`, environment, logs, or error messages.

**W2e — CLI secret hygiene.** Passphrase entry (terminal echo suppression),
passphrase-via-flag or env, secret material in shell history, temp files,
crash dumps, and error output.

### W3 — FFI and native safety 🎯 *focus area 3*

**Question:** can the native layer corrupt memory or race?

**Which version to review (per O-1c).** `betto_zstd` and `betto_icu` are both
one dev-release ahead locally of what KMDB resolves. I will review **local
HEAD** — that is the tree a `0.1.0` will be cut from — and separately diff
`dev.3 → HEAD` (`betto_zstd`) and `dev.2 → HEAD` (`betto_icu`) to determine
whether the delta touches FFI, buffer handling, or wire format. If it does, the
diff itself becomes a finding: KMDB has never run its test suite against that
code. All findings will name the commit reviewed, not just the package.

Checklist per package:

- **Pointer lifetime vs. GC.** `Uint8List` passed as a pointer must be pinned or
  copied — a view the Dart GC can relocate mid-call is a use-after-move.
- **Allocation discipline.** `calloc`/`Arena` freed on **every** path including
  exceptions and early returns; no double-free on `dispose()`; `NativeFinalizer`
  attached where handles outlive a call.
- **Buffer sizing.** Output buffers respect the native API's bound function
  (e.g. `ZSTD_compressBound`); no assumption that decompressed ≤ some constant.
- **Error handling.** Every native return code checked (`ZSTD_isError` and
  friends) before the result is used as a length.
- **Isolate safety.** Native contexts/handles shared across isolates — KMDB now
  has a real isolate (O-4). A `ZSTD_CCtx` or ICU handle touched from two
  isolates without synchronisation is a memory-corruption bug.
- **Web/WASM divergence.** The WASM path is a separate implementation with
  separate bounds behaviour; parity is not free.
- **Dispose-after-use.** Use of a freed context returning garbage rather than
  failing.

I will also verify the **native-asset build hook** story holds for a released
package — `CLAUDE.md` documents that a cold cache silently produces "No
available native assets," which for a consumer of a published `0.1.0` would be a
confusing first-run failure rather than a clear error.

### W4 — Concurrency, durability, and crash safety

**Question:** did the 0.02.01 hardening hold, and does the new isolate break it?

- Regression-check the closed C1/C2/H1–H5/M1–M3 items against current code.
- Confirm `FaultyStorageAdapter` fault-injection coverage still exercises the
  paths it was built for, and has not been quietly bypassed by newer code.
- **The vault indexing isolate (O-4)** against §18's synchronous model: what
  state crosses the isolate boundary, whether the LOCK/single-writer invariant
  still holds, whether the isolate can observe a torn view, and what happens if
  it dies mid-index.
- Encryption interaction with crash safety (§31 "Crash Safety") — a crash
  between DEK provisioning and first write, or mid-re-encryption.

### W5 — CLI functional completeness

**Question:** "fully functional within the scope of its specification" — is it?

Enumerate every documented command and flag, exercise each end-to-end against a
real on-disk database, and check: correct behaviour, exit codes, error messages
that name the actual problem, `--help` correctness, argument validation, and
graceful failure on missing/corrupt state. Given O-3 (the CLI is outside the
pre-commit gate) I expect this to be the highest-yield workstream for ordinary
bugs.

### W6 — Code health and release hygiene

- **The O-1 dependency gate.** Confirm the 12-package closure is complete (no
  further indirect `betto_*` edge has been missed), that `betto_abnf` is added
  to `CLAUDE.md` and the `dependency_overrides`, and that O-1b's pin
  inconsistency is reconciled. Then verify the release process actually
  *sequences* the promotion: all 12 published at `0.1.0` → KMDB pins moved to
  `^0.1.0` → **full suite re-run against the promoted pins** → tag. A green run
  against `-dev` pins is not evidence about the shipped artefact.
- Public API surface: nothing leaked from `src/` that shouldn't be exported;
  nothing missing that consumers need.
- Version consistency across the workspace; CHANGELOGs present and accurate.
- Dead code, unreachable branches, `TODO`/`FIXME`, and re-rolled primitives
  (the 2026-05-22 review had to remove hand-rolled CBOR parsers — check none
  have crept back).
- Doc comments on all public API (project standard).
- Analyzer clean; formatting clean; licence headers present.
- Coverage ≥ 90% (baseline is 95% per the coverage remediation work) — and,
  more usefully, whether coverage is *meaningful* on the security and format
  paths specifically, rather than merely high overall.
- §18 performance benchmarks against their P99 targets.
- `docs/spec/28_release_checklist.md` — confirm every applicable RC entry is
  either runnable or has an accepted waiver, especially **RC-4** (Linux
  power-loss) and **RC-6** (multi-device tombstone non-resurrection), which are
  flagged as un-automatable.

---

## 5. Method and conventions

**Evidence standard.** Every finding must cite a specific file and line, and
state a concrete failure scenario — inputs/state → wrong outcome. Where a bug is
reproducible, I will write a throwaway probe test to confirm it before recording
it, and note in the finding that it was confirmed rather than reasoned about.
The 2026-05-22 review did this for C1 and it is why that finding was actionable.
Findings I could not confirm will be labelled as such rather than dressed up.

**Severity taxonomy.**

| Severity | Meaning for `0.1.0` |
| :--- | :--- |
| 🔴 **Critical** | Data loss, data corruption, or a break in a stated security guarantee. **Blocks the release.** |
| 🟠 **High** | Spec divergence users would rely on, an exploitable-with-effort weakness, or a bug with no workaround. **Blocks unless explicitly waived.** |
| 🟡 **Medium** | Real defect with a workaround, or a gap between documented and actual behaviour that misleads. Ship-with-known-issue. |
| 🟢 **Low** | Code health, docs, ergonomics. Post-release. |

**A note on my own bias.** A review like this is prone to two failures: finding
nothing because the code is well-organised and reads convincingly, and finding
everything because every unusual choice looks suspicious. The guard against the
first is the untrusted-input and nonce-uniqueness work in W2, where I am hunting
specific, known-catastrophic failure modes rather than reading for smells. The
guard against the second is the evidence standard above. If a workstream returns
no findings I will say so plainly rather than manufacturing severity.

**Process failure worth recording (2026-07-19).** I wrote C-1 as a defect
without first checking `docs/plans/completed/` for design rationale — and there
was some: `plan_0_09_cli_keychain_credentials.md` documents the Windows
no-`chmod` decision as deliberate, with an `OpenSSH`/`gcloud` precedent and a
surveyed-and-deferred keychain alternative. The maintainer corrected it and the
finding was downgraded 🟡 → 🟢 and reframed.

**A deliberate, documented decision is not the same as a defect**, and this
codebase records its decisions unusually well — a reviewer who ignores that
history will manufacture findings. On being corrected I re-checked the other
findings against the completed plans for the same mistake: **S-5** (hand-rolled
SHA-256), **S-6** (lease validation), and **S-7** (`/tmp` staging) have **no**
documented rationale, so they stand. S-5 is in fact *reinforced* —
`plan_vault_gc_failsafe.md` argues explicitly against re-introducing hand-rolled
primitives, so the hand-written SHA-256 runs against the project's own stated
position rather than being justified by it.

---

## 6. Findings register

**Baseline (2026-07-19), all measured on this machine:**

| Check | Result |
| :--- | :--- |
| `packages/kmdb` tests | **2373 pass, 12 skipped**, exit 0 |
| `packages/kmdb_cli` tests | **1176 pass, 3 skipped**, exit 0 |
| `make analyze` (all 9 packages) | **No issues found**, exit 0 |
| Coverage | **94.8%** (11,181/11,800 lines, 205 files) — measured 2026-07-20 on merged `main`, post-PR #61 |
| §18 benchmarks | **10/10 PASS** — run 2026-07-20 on merged `main`, post-PR #61 |

> The analyzer and both test suites fail inside the review sandbox — Dart's
> telemetry initialiser cannot create `~/.dart-tool/dart-flutter-telemetry.config`
> and aborts before running anything. All figures above were obtained outside
> the sandbox. Worth knowing for anyone running these in a restricted CI
> container: the failure looks like a Dart CLI crash, not a permissions problem.

| # | Severity | Workstream | Issue | Blocks 0.1.0? |
| :-- | :-- | :-- | :-- | :-- |
| S-1 | 🔴 Critical | W2c | Unvalidated length/offset fields in the SSTable reader — a crafted peer SSTable aborts `SyncEngine.pull()` and can exhaust memory (**confirmed, reproduced**) | **Yes** |
| S-2 | 🔴 Critical | W2c / W3 | Zstd decompression bomb — decompressed size is taken from the attacker-controlled frame header and `malloc`'d uncapped; ~32,000× amplification measured (**confirmed**) | **Yes** |
| S-3 | 🟢 Low | W2c | `_ByteReader.readUint64` can return a negative length, yielding `RangeError` instead of `FormatException` | No |
| S-4 | 🔴 Critical | W2c / W2a | Vault blobs are never verified against their content address on read or hydration; the `encrypted` flag gating decryption is itself attacker-controlled (**confirmed by inspection**) | **Yes** |
| S-5 | 🟡 Medium | W6 | Hand-rolled SHA-256 and CRC32C in `VaultStore` — **correct on all NIST vectors**, but a re-rolled primitive against project policy, with misleading comments and no web verification | No |
| S-6 | 🔴 Critical | W2c | Consolidation `commit()` deletes every path named in the attacker-writable lease file — a confused-deputy primitive for destroying arbitrary sync-folder data (**confirmed by inspection**) | **Yes** |
| S-7 | 🟠 High | W2c / W5 | Consolidation stages downloads at a hardcoded, predictable `/tmp/kmdb-consolidation-{filename}` — breaks on Windows and invites symlink/collision attacks | **Yes** |
| S-8 | 🟡 Medium | W2c | Extractors (PDF/HTML/Markdown) parse untrusted blobs with no size, depth, or time bounds | No |
| E-1 | 🔴 Critical | W2b | **The spec's documented threat model is passive-only.** It never claims resistance to an adversary who can *write* the sync folder — which is the model requested for `0.1.0`. S-1/S-4/S-6 are all downstream of this gap | **Yes** |
| E-2 | 🟠 High | W2a | AES-GCM is used with **no associated data**, so ciphertext is not bound to its key, namespace, or version — enabling relocation/rollback of authenticated records | **Yes** |
| E-3 | 🟢 Pass | W2a | Nonce management, Argon2id parameters, and HKDF usage reviewed — **no findings**; see notes | — |
| C-1 | 🟢 Low | W2d | Windows profile-ACL inheritance is assumed, but the credential path is a user-supplied `dbDir`, not a fixed profile location (**revised down from 🟡 — the Windows no-chmod decision is deliberate and documented**) | No |
| C-2 | 🟢 Low | W2e | REPL history is written with default permissions and records every line unfiltered | No |
| C-3 | 🟢 Pass | W2d/W2e | POSIX credential store, passphrase intake, and transport reviewed — **no findings**; see notes | — |
| F-1 | 🟢 Low | W3 | Native buffers allocated *before* the `try` in `betto_zstd.compress` and `betto_icu` — a throwing second allocation leaks the first | No |
| F-2 | 🟢 Pass | W3 | FFI memory safety, lifetimes, disposal, and isolate safety reviewed — **no memory-corruption or race findings**; see notes | — |
| L-1 | 🟡 Medium | W5 | `kmdb help <unknown-command>` dies with an unhandled Dart exception and exit 255 instead of a clean error | No |
| L-2 | 🟢 Pass | W5 | Core CLI lifecycle (`init`/`create-collection`/`insert`/`count`/`scan`/`verify`/`stats`) exercised end-to-end on a real on-disk database — **works correctly, exit codes accurate** | — |
| D-1 | 🟠 High | W4 | A dead vault-indexing isolate hangs `close()` **before** the memtable flush — no `onError`/`onExit` handler and no timeout (**confirmed by inspection**) | **Yes** |
| D-2 | 🟢 Pass | W4 | The v0.02.01 durability hardening (C1, C2, H1–H5, M1–M3) is **still in place** — regression-checked, no reversions | — |
| D-3 | 🟡 Medium | W4 | `FaultyStorageAdapter` fault injection covers local durability paths but **no sync test uses it** — the trust boundary has no fault injection | No |
| O-4 | 🟢 Pass | W4 | The vault indexing isolate does **not** violate §18's single-writer model — only pure data crosses the boundary; see notes | — |
| SC-1 | 🟠 High | W1 | §31 claims a cached DEK is verified against `enc:blob`; **no verification exists** — a wrong passphrase opens an encrypted database on any cache hit (**confirmed, reproduced**) | **Yes** |
| SC-2 | 🟠 High | W1 | §31's *Vault Encryption* documents the **pre-PR-#61** blob byte layout and the S-4-vulnerable manifest-flag read; §24 documents the current one. Two specs contradict on a format `0.1.0` freezes | **Yes** |
| SC-3 | 🟠 High | W1 | §15's Materialised View Cache (`$cache`) is **unimplemented**, yet §15's tier table marks it *Required* on mobile/web. `KvStoreConfig.sessionCacheMaxObjects` does not exist either | **Yes** |
| SC-4 | 🟡 Medium | W1 | §31's *Algorithms* table misstates the recovery-KEK derivation (salt and `info` both wrong) and names two API symbols that do not exist | No |
| SC-5 | 🟡 Medium | W1 | §08 states the device ID lives in platform secure storage and "must not be stored inside the database"; it is stored in `$meta` — inside the database. Contradicts §31 gap 4 | No |
| SC-6 | 🟡 Medium | W1 | §31's *Provisioning Guard* describes a `$meta` emptiness scan; the code checks only non-`$` namespaces, weakening §31's "born encrypted or never encrypted" claim | No |
| SC-7 | 🟢 Low | W1 | §05 presents vault blobs as size-bounded by `VaultSearchConfig.maxBlobBytes`; that bound is search-extraction-only and is applied *after* the blob is fully in memory | No |
| SC-8 | 🟢 Low | W1 | Minor spec/code drift: the encrypted branch of `kMaxDecodedValueBytes` is untested; §31 and `kmdb_database.dart` both say "4-state matrix" over a 5-state table | No |
| SC-9 | 🟢 Pass | W1 | PR #61's §05/§08/§12/§18/§24 spec edits were traced claim-by-claim to code and tests — **accurate**, including the S-1/S-6/S-7/D-1 hardening and the quarantine semantics; see notes | — |

---

### S-1 — SSTable parsing trusts adversary-controlled length fields 🔴 (CONFIRMED)

**A device with write access to the sync folder — a malicious peer, or the
cloud provider itself under T1/T3 — can craft an SSTable that aborts
`SyncEngine.pull()` on every device that syncs, permanently.** On the native
adapter the same defect yields an `OutOfMemoryError`, which is an `Error`, not
an `Exception`, and kills the isolate.

#### Why the checksum is not a defence

`SstableReader.open()` verifies an **XXH64** digest over the file before
parsing the filter and index blocks
([sstable_reader.dart:159](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L159)).
That ordering is correct, and against *accidental* corruption the check works.
But XXH64 is a **non-cryptographic** hash: an attacker who rewrites the body
simply recomputes the digest and writes it into the footer. Every probe below
carries a valid checksum. The integrity check therefore establishes nothing
about authenticity, and all parsing below it is fully attacker-reachable.

#### The defect

Four length/offset fields are read from the file and used without any bounds
validation:

| Field | Read at | Used at | Consequence |
| :--- | :--- | :--- | :--- |
| `footer.filterSize` / `indexSize` | [:277–282](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L277) `getInt64`, **signed** | [:171](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L171), [:179](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L179) → `readFileRange` | `Uint8List(length)` allocated **before** reading → OOM |
| `footer.filterOffset` / `indexOffset` | same | same | Negative offset reaches `RandomAccessFile.setPosition` |
| index `keyLen`, `blockOffset`, `blockSize` | [:290–297](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L290) `Varint.decode` | [:292](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L292) `sublistView`, [:262](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L262) `readFileRange` | `RangeError`; unbounded read |
| block `shared` | [:353](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L353) | [:366](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L366) `Uint8List(shared + unsharedLen)` | Allocation sized **before** `setRange` validates it against `currentKey.length` |

The native adapter compounds this: `readFileRange` allocates the requested
length up front and only errors *after* the read
([storage_adapter_native.dart:52](packages/kmdb/lib/src/engine/platform/storage_adapter_native.dart#L52)).

Two contributing factors are worth separating out, because they are independent
bugs:

1. **`Varint.decode` can return negative values.** At `shift == 63`,
   `(byte & 0x7F) << 63` sets the sign bit
   ([varint.dart:110](packages/kmdb/lib/src/engine/util/varint.dart#L110)). The
   guard is `shift >= 64`, so a 10-byte varint decodes to a negative `int`. No
   caller expects a negative length.
2. **The exception types escape every caller's catch.** `pull()` catches
   `CorruptedSstableException`, `FormatException`, and
   `StaleSstableIngestException`
   ([sync_engine.dart:547–553](packages/kmdb/lib/src/sync/sync_engine.dart#L547)).
   The parser actually throws `RangeError`, `StorageException`, and
   `OutOfMemoryError` — none of which are caught. The same mistake appears at
   [lsm_engine.dart `ingestAt0`](packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart),
   where the `firstKey()` diagnostic is wrapped in `on Exception` with a comment
   stating a failure "must never abort an ingest" — but `RangeError` is an
   `Error`, so it aborts the ingest anyway.

#### Reproduction (confirmed 2026-07-19)

Direct against `SstableReader.open` with the **native** adapter — build a valid
SSTable, patch one footer field, recompute the XXH64:

```
PROBE1 (filterSize = 1<<40)  → OutOfMemoryError: Out of Memory
PROBE2 (filterOffset = -4096) → StorageException: setPosition failed
PROBE3 (index keyLen = 127)   → RangeError (end): Not in inclusive range 1..20: 128
```

End-to-end through `SyncEngine.pull()`, peer file uploaded to the sync folder
(memory adapter, i.e. the *safer* of the two):

```
PEER-A (crafted index keyLen)   → pull() threw RangeError (end): ... 1..31: 128
PEER-B (crafted footer filterSize) → pull() threw StorageException:
                                     Range [120, 1099511627896) out of bounds
```

Both escape `pull()`. Probes were throwaway and have been removed; they should
become permanent regression tests.

#### Impact

Because the exception propagates out of `pull()`, the peer's high-water mark is
never advanced — so **the poisoned file is re-downloaded and re-parsed on every
subsequent pull.** This is not a transient crash but a **persistent
denial-of-sync**: the affected device cannot complete a sync cycle again until
the file is manually removed from the cloud folder. `ingestSstable` also writes
the attacker's bytes to the local `sst/` directory *before* validation
([kv_store_impl.dart:306](packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L306)),
giving an unauthenticated disk-fill primitive on the same path.

Dart's memory safety means this is **not** a memory-corruption or
code-execution bug — it is denial of service and availability loss. That
distinction matters for severity, but under a threat model that admits an
active adversary (T1/T3) it still breaks a stated guarantee.

#### Why the tests miss it

The same structural blind spot the 2026-05-22 review identified, in a new place.
Every SSTable parser test feeds the parser **well-formed output this codebase
produced**. The one negative test —
`test/sync/sync_engine_test.dart` "pull skips corrupted remote SSTable" — uploads
64 bytes of `0xAB`, which fails the *footer checksum* and so exercises only the
one path that is correctly handled. No test constructs a **checksum-valid,
structurally hostile** file.

`MemoryStorageAdapter` hides the worst of it: unlike the native adapter it
bounds-checks `readFileRange`
([storage_adapter_memory.dart](packages/kmdb/lib/src/engine/platform/storage_adapter_memory.dart)),
converting the OOM into a `StorageException`. Since the sync tests run on the
memory adapter, the most severe form of this bug is invisible to the suite —
precisely the in-memory-adapter blindness the last review called out.

#### Contrast: the codebase already knows the right pattern

`ManifestReader` validates the declared record length against the remaining
buffer **before** slicing, and verifies the checksum **before** CBOR-decoding
([manifest_reader.dart:69–85](packages/kmdb/lib/src/engine/manifest/manifest_reader.dart#L69)).
The WAL reader guards its header read the same way. Both are **local-only**
formats that never cross a trust boundary — yet they are the validated ones,
while the SSTable, the *only* format that is replicated between devices, is not.
This looks like validation written against truncation and disk corruption, then
never revisited when sync made the same parser adversary-facing.

#### Recommended fix

1. Validate every footer field on parse: offsets and sizes non-negative, and
   `offset + size <= fileSize`. Reject with `CorruptedSstableException`.
2. Bounds-check `keyLen`, `blockOffset`, `blockSize`, `shared`, `unsharedLen`,
   and `valueLen` against the enclosing buffer *before* use, and cap `shared` at
   `currentKey.length` before sizing the allocation.
3. Make `Varint.decode` reject values that do not fit a non-negative 64-bit int
   (guard `shift > 56` for the final byte, or reject a set sign bit).
4. Wrap the whole parse so that any structural failure surfaces as
   `CorruptedSstableException` — callers already handle that type correctly.
5. Broaden the `pull()` and `ingestAt0` catches to match what can actually be
   thrown, and treat an un-parseable peer file as a *skip-and-quarantine* rather
   than letting it re-poison every subsequent pull.
6. Bound the whole-file read at [:159](packages/kmdb/lib/src/engine/sstable/sstable_reader.dart#L159)
   and `readFileRange` allocations by the actual file size.
7. Add a fault-injection corpus of checksum-valid hostile SSTables, and run the
   sync tests against the **native** adapter as well as the memory one.

**Note (open design question, not part of the fix above):** points 1–7 restore
robustness, but they do not make a peer SSTable *authentic*. If T1/T3 are really
in the threat model, an attacker can still inject well-formed SSTables
containing arbitrary documents at arbitrary HLCs. That is an authentication
gap, not a parsing gap, and is tracked separately once W2a/W2b complete.

---

### S-2 — Zstd decompression bomb: uncapped allocation from an attacker-declared size 🔴 (CONFIRMED)

**A few kilobytes inside a peer SSTable or vault blob can force a
multi-gigabyte allocation on every device that decodes that value.** There is no
decompressed-size limit anywhere in the stack.

#### The defect

`ZstdSimple.decompress` asks the frame for its declared content size and passes
that number straight to `malloc`
([zstd/lib/src/zstd_native.dart:147–161](/Users/gonk/development/bettongia/zstd/lib/src/zstd_native.dart#L147)):

```dart
final decompressedSize = _getFrameContentSize(srcPtr.cast(), compressedSize);
if (decompressedSize == -1) { /* unknown */ }
if (decompressedSize == -2) { /* invalid header */ }
final dstPtr = malloc<Uint8>(decompressedSize);   // ← no upper bound
```

`ZSTD_getFrameContentSize` returns the size **declared in the frame header** —
data the attacker writes. Only the two sentinel values are rejected; any other
magnitude is accepted. A ~20-byte frame can declare a 1 TiB content size and
reach `malloc` before a single byte is decompressed.

Two secondary issues in the same function:

- The C API returns `unsigned long long`, bound in Dart as a signed `int`. The
  sentinels map correctly (`-1`, `-2`), but a frame declaring a size ≥ 2^63
  arrives as a **negative** number and is passed to `malloc<Uint8>()` unchecked.
- On Linux with memory overcommit, a large `malloc` **succeeds**; the process
  then faults pages in during decompression and is killed by the OOM killer.
  So the failure mode is platform-dependent: a catchable `ArgumentError` from
  `package:ffi` on some platforms, an uncatchable process kill on others.

#### No cap anywhere upstream

A search of `packages/kmdb/lib` for any value/document/blob size limit
(`maxValueSize`, `maxDocumentSize`, `sizeLimit`, `maxBlobSize`, …) returns
**nothing**. `ValueCodec.decode` calls `decompress` on the payload with no
inspection
([value_codec.dart:175](packages/kmdb/lib/src/encoding/value_codec.dart#L175),
[:194](packages/kmdb/lib/src/encoding/value_codec.dart#L194)), on both the
encrypted and unencrypted branches.

#### Measured amplification (confirmed 2026-07-19)

No header forgery is even required — ordinary Zstd on compressible input is
enough. Measured against `betto_zstd` at its default level:

```
 16 MiB of zeros ->    531 bytes  (amplification  31,596x)
 64 MiB of zeros ->  2,067 bytes  (amplification  32,467x)
256 MiB of zeros ->  8,211 bytes  (amplification  32,692x)
```

At ~32,000×, an 8 KB value expands to 256 MB and a 320 KB value to ~10 GB — well
inside the size of an SSTable a peer would upload without suspicion. The
declared-size path is cheaper still, since the allocation happens before any
decompression work.

#### Reachability

Value payloads in ingested peer SSTables flow through `ValueCodec.decode`, as do
vault blobs. Under T1/T3 the attacker controls those bytes. Unlike S-1 the
*ingest itself* succeeds — the bomb fires later, when the value is decoded.

#### Detonation point — resolved 2026-07-19 ✅

This was left open above and has now been run down. **The bomb detonates on
read, not on ingest — the database does not become unopenable.**

- **Ingest does not detonate it.** `ingestAt0` opens the reader, reads the
  index/filter and `entryCount`, and calls `firstKey()` — all of which decode
  *keys*. `_decodeBlock` returns values as `sublistView` **views**, never
  decompressing them.
- **Compaction does not detonate it.** `CompactionJob` touches values only as
  opaque bytes; every decode call in it is a *key* decode
  (`KeyCodec.decodeHlc` / `decodeRecordType` / `decodeNamespace`). No
  `ValueCodec` or `decompress` call exists in the file.
- **Ingest does not trigger indexing.** The only subscriber to
  `KvStore.writeEvents` is `CacheLayer`, and it early-returns on system
  namespaces — `if (namespace.startsWith(r'$')) return;`
  ([cache_layer.dart:263](packages/kmdb/lib/src/cache/cache_layer.dart#L263)) —
  which is exactly what `ingestAt0` emits (`$sync`). No FTS or Vec indexing
  fires on ingested peer data.

So the poisoned value sits inert in an L0 SSTable until something decodes it:
a `get` of that document, or any operation that scans the collection —
`scan`, `dump`, `export`, and notably `verify`, whose entire job is to decode
every stored document.

**Revised impact.** The affected document is *permanently* unreadable (the
SSTable is manifest-registered, so every attempt re-detonates), and any
full-collection operation over that collection fails for as long as it is
present. But the database opens normally and unaffected collections keep
working.

**Consequence for remediation — a genuine scope reduction.** The fix does
**not** need a quarantine-and-repair path for unopenable databases. A
decompressed-size cap in `betto_zstd`, a max decoded-value size in
`ValueCodec`, and graceful per-document error handling on the read path are
sufficient. Severity stays 🔴 (unauthenticated remote input causes permanent,
unrecoverable-without-manual-intervention data unavailability), but the
blast radius is one collection, not the database.

#### Recommended fix

1. Add a `maxDecompressedSize` parameter to `ZstdSimple.decompress` and reject
   frames whose declared size exceeds it *before* allocating. Reject negative
   declared sizes explicitly rather than relying on `malloc` to fail.
2. Give KMDB an explicit maximum decoded-value size, enforced in `ValueCodec`,
   and treat a violation as `CorruptedSstableException` on the ingest path.
3. Prefer the streaming decompression API with a hard output budget for any
   value that crosses a trust boundary; the one-shot API cannot bound output by
   construction.
4. Apply the same bound to vault blob extraction and to the extractor packages.

---

### S-3 — `readUint64` sign overflow yields the wrong exception 🟢

`_ByteReader.readUint64` composes `(hi << 32) | lo`
([vault_package.dart:503–510](packages/kmdb/lib/src/vault/vault_package.dart#L503)).
When `hi ≥ 2^31` the shift sets bit 63 and the result is **negative**.
`_checkAvailable(negative)` then passes trivially (`_pos + negative` is smaller
than the buffer length), so the guard is bypassed and `sublist` throws
`RangeError` instead of the intended `FormatException`.

Impact is limited — KVLT parsing is otherwise correctly bounds-checked via
`_checkAvailable` before every read, which is the right pattern and worth
preserving. But callers that catch `FormatException` to reject a malformed
package will miss this case. Fix: reject a negative or absurd length explicitly
in `readUint64`.

> The same signed-shift bug class appears in `Varint.decode` (see S-1
> contributing factor 1). Worth a sweep for other hand-rolled integer decoders
> that can produce negative lengths.

---

### S-4 — The content-addressable vault never verifies content against its address 🔴

**A content-addressable store derives its entire integrity guarantee from the
claim that the bytes at address *H* hash to *H*. KMDB never checks this on the
read or hydration path.** `_computeSha256` is called in exactly one place — the
*write* path, to derive an address from local content
([vault_store.dart:215](packages/kmdb/lib/src/vault/vault_store.dart#L215)).
Nothing recomputes it for data arriving from the sync folder.

#### The chain

1. **Hydration writes unverified remote bytes.** `hydrateVaultBlob(sha256)`
   reads the remote blob and renames it into `blobPath(sha256)`
   ([local_directory_vault_adapter.dart:210–242](packages/kmdb/lib/src/vault/local_directory_vault_adapter.dart#L210)).
   The bytes are never hashed. Whatever the sync folder holds becomes the local
   blob for that address.
2. **Reads do not verify either.** `getBytes` does
   `readFile(blobPath(sha256))` and returns it
   ([vault_store.dart:354](packages/kmdb/lib/src/vault/vault_store.dart#L354)).
   No comparison against the requested address.
3. **The metadata that could catch it is attacker-supplied.**
   `syncVaultMetadata` reads `manifest.json` **from the sync folder** and writes
   it into the local store
   ([local_directory_vault_adapter.dart:168–200](packages/kmdb/lib/src/vault/local_directory_vault_adapter.dart#L168)).
   `VaultManifest` carries `sha256`, `size`, `crc32c`, and `encrypted` — all of
   it under the attacker's control, and `crc32c` is non-cryptographic anyway.
4. **Decryption is gated on that attacker-controlled flag.** `getBytes`
   decrypts only `if (manifest.encrypted)`
   ([vault_store.dart:357](packages/kmdb/lib/src/vault/vault_store.dart#L357)).

#### Consequence: substitution, and an encryption downgrade

Under T1 (untrusted provider with write access) or T3 (malicious peer):

- **Content substitution.** Replace the bytes at any `vault/ab/cdef…/blob`. Every
  device that hydrates that blob stores and serves the attacker's content under
  the legitimate hash. A user opening what they believe is their own attachment
  gets attacker-chosen bytes, with no error.
- **Encryption downgrade.** For an *encrypted* vault, AES-GCM authentication
  would normally catch substituted ciphertext. But the attacker also controls
  `manifest.json`, so they set `encrypted: false` and supply plaintext. The
  device skips decryption entirely and returns it. **The one mechanism that
  would have detected the substitution is switched off by the attacker.**

This is the difference between S-1/S-2 (availability) and S-4: this one breaks
**integrity and authenticity**, which is the guarantee a content-addressable
store exists to provide.

#### Recommended fix

1. Hash the bytes on hydration and reject the object if the digest does not
   equal the requested address. This is cheap, requires no key material, and
   defeats substitution outright — a CAS that verifies its own addressing needs
   no trust in the transport.
2. Verify on read as well, at least for blobs that arrived via sync.
3. Do not let a synced manifest decide whether authentication happens. The
   `encrypted` flag must come from a trusted local record (or, better, be
   inferred from the ciphertext envelope), never from the sync folder.
4. Treat `crc32c` as a corruption check only; it must never be presented as an
   integrity control.

> **Verified by inspection** — the absent verification, the single `_computeSha256`
> call site, and the flag-gated decryption are all unambiguous in the code.
> I have **not** built a working end-to-end substitution exploit; that would be
> the natural regression test for the fix.

---

### S-5 — Hand-rolled SHA-256 and CRC32C 🟡

`VaultStore` contains a full hand-written FIPS 180-4 SHA-256
([vault_store.dart:736+](packages/kmdb/lib/src/vault/vault_store.dart#L736))
plus a hand-written CRC32C, rather than using `package:crypto`.

**It is correct.** I verified `computeSha256ForTest` against the standard NIST
vectors, including the 1,000,000-byte case that stresses multi-block padding and
the 64-bit length field:

```
OK  empty · OK  abc · OK  448-bit · OK  896-bit · OK  million-a
ALL VECTORS PASS
```

So this is not a correctness finding today. It is flagged because:

- **It contradicts an explicit project rule.** `CLAUDE.md` says to prefer
  existing primitives over re-rolling them, citing the hand-rolled CBOR parsers
  the 2026-05-22 review had to remove. This is the same class of problem, in the
  security-critical position of *the vault's addressing function*.
- **The comments show the decision was never actually made.**
  [`_sha256Digest`](packages/kmdb/lib/src/vault/vault_store.dart#L723) contains
  five mutually contradictory statements ("Use the dart:crypto digest",
  "dart:convert does not expose it", "use package:crypto if available, or a
  built-in equivalent", "the Dart SDK includes SHA-256 via dart:convert from SDK
  3.x") before falling through to the hand-written version. `dart:crypto` is not
  a Dart SDK library; `package:crypto` is the real, maintained answer.
- **Web is unverified.** My vectors ran on the native VM. Under dart2js an `int`
  is a double and bitwise operations are 32-bit; the `_add32` helpers suggest
  the author was aware, but nothing proves the implementation is correct on web,
  where a wrong digest would mean wrong vault addresses.

Fix: replace both with `package:crypto`, or — if there is a real reason to avoid
the dependency — keep the implementation but add the NIST vectors as permanent
tests and run them on web as well as native.

---

### S-6 — A malicious lease turns any consolidating device into a deletion weapon 🔴

**The consolidation lease is an unauthenticated JSON file in the sync folder.
`commit()` deletes every path it names, relative to `sstables/`, using the
victim device's own credentials.**

```dart
for (final filename in lease.inputFiles) {
  try {
    await cloudAdapter.delete('$_sstablesDir/$filename', ctx: _ctx);
  } catch (_) { /* non-fatal */ }
}
```
([consolidation_coordinator.dart:531–538](packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L531))

`inputFiles` is deserialised with `(map['inputFiles'] as List).cast<String>()`
([:137](packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L137)) — **no
validation whatsoever**. No `SstableInfo.parse` gate, no rejection of `..`, no
check that the entry is even an SSTable name. The one place `SstableInfo.parse`
is applied ([:425](packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L425))
is inside a sort comparator whose `catch (_)` falls back to a string compare —
so an unparseable name is *reordered*, never rejected.

#### Why this is worse than it first looks

A lease of the form:

```json
{ "inputFiles": ["../highwater/victim-device.hwm",
                 "../vault/ab/cdef…/blob",
                 "../sstables/other-device-legit.sst"] }
```

causes the consolidating device to delete other devices' high-water marks,
vault blobs, and legitimate SSTables. Because the sync folder **is** the
replication substrate, deleting SSTables that peers have not yet pulled is
**permanent data loss**, not a recoverable outage.

Three properties make this a serious finding rather than a theoretical one:

1. **It is a confused deputy.** The attacker never deletes anything. A fully
   authorised device does it, with its own credentials. Per-device ACLs on the
   cloud side — the natural mitigation — do not help, because the deputy is
   authorised.
2. **It needs only the weakest attacker in the model.** Writing the lease file
   is the *normal, intended* behaviour of any peer device (T3); it is how
   consolidation coordination works. No provider compromise (T1) is required.
3. **The failures are silent.** `catch (_)` swallows every deletion error, so a
   lease naming a hundred victim paths produces no diagnostic at all.

#### Recommended fix

1. Validate every `inputFiles` entry with `SstableInfo.parse` **before use**, and
   reject the whole lease if any entry fails. A lease is not a place for
   best-effort tolerance.
2. Reject any entry containing a path separator or `..`; these are filenames,
   not paths. Join them with a helper that refuses to escape `sstablesDir`.
3. Cross-check that each named input was actually observed in the device's own
   listing of `sstables/` before deleting it — never take the lease's word for
   what exists.
4. Log deletion failures rather than discarding them.
5. Longer term, this is the same authenticity gap as S-1 and S-4: sync-folder
   control data is trusted because it is *in* the sync folder. If T1/T3 are in
   scope, leases need authentication, not just validation.

---

### S-7 — Hardcoded, predictable `/tmp` staging path 🟠

`consolidate()` stages every downloaded SSTable at:

```dart
final tmpPath = '/tmp/kmdb-consolidation-$filename';
```
([consolidation_coordinator.dart:441](packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L441))

Three separate problems:

- **It is not cross-platform.** `/tmp` does not exist on Windows. `0.1.0` ships
  a Windows-targeting library (RC-3 in the release checklist explicitly covers
  Windows), so consolidation is broken there. The rest of the engine reaches the
  filesystem through `StorageAdapter`; this line bypasses it and hardcodes a
  POSIX path.
- **It is predictable and non-unique.** No PID, no randomness, no per-run
  directory. Two processes consolidating concurrently collide, and on a
  multi-user host an attacker who pre-creates `/tmp/kmdb-consolidation-<name>`
  as a symlink redirects the write. Compare `hydrateVaultBlob`, which correctly
  uses `stagingPath(microsecondsSinceEpoch)`.
- **`filename` is lease-controlled** (see S-6), so it is attacker-influenced
  input being interpolated into a filesystem path. Directory traversal is
  *incidentally* blocked here because `StorageAdapterNative.writeFile` does not
  create parent directories, so POSIX resolution fails on the non-existent
  intermediate component — but that is a lucky implementation detail, not a
  control. Validating the filename (S-6 fix 2) is what actually closes it.

Fix: derive the staging directory from the adapter/config as the vault path
already does, make it unique per run, and clean it up in a `finally`.

> Note: `consolidate()` also opens these downloaded files with
> `SstableReader.open` under `on CorruptedSstableException`
> ([:447](packages/kmdb/lib/src/sync/consolidation_coordinator.dart#L447)) —
> the same too-narrow catch as S-1, so this is a **second** call site affected by
> that finding, not just `SyncEngine.pull()`.

---

### S-8 — Extractors parse untrusted blobs with no bounds 🟡

`kmdb_extractor_pdf`, `kmdb_extractor_html`, and `kmdb_extractor_markdown` exist
specifically to parse **user- and peer-supplied file content**, and a search
across all three for any size, depth, recursion, or time limit returns nothing.

- **PDF** delegates to PDFium via `betto_pdfium` — a large native parser with a
  long CVE history, handed adversary-controlled bytes with no size cap and no
  timeout. This is the boundary flagged in §2.3 as in-scope.
- **HTML/Markdown** are pure Dart, so memory-safe, but deeply nested input can
  still drive parser recursion into a stack overflow, and pathological documents
  can consume unbounded time and memory.

Combined with S-2 (no decompressed-size cap anywhere), a vault blob can be both
a decompression bomb *and* a parser bomb.

Fix: impose a maximum extractable blob size, run extraction with a timeout, and
— for the PDF path especially — consider isolating extraction so a native crash
or hang cannot take the host process down with it.

---

### E-1 — The documented threat model is passive-only; the intended one is not 🔴

**This is the most important finding in the review, and it reframes several
others.** It is not a bug in the code. It is a gap between the security model
`docs/spec/31_encryption.md` commits to and the one you specified for `0.1.0`.

§31 states that encryption protects document content against exactly two
adversaries
([31_encryption.md:504–520](docs/spec/31_encryption.md)):

1. **The cloud storage provider** — but the property claimed is strictly
   confidentiality: *"the provider cannot **read** document values."*
2. **Physical access to a device** without the passphrase.

Searching §31 for `AAD`, `associated data`, `tamper`, `integrity`, `authentic`,
`relocate`, or `replay` returns nothing relevant — the only hits are about
wrong-passphrase detection during DEK unwrap. **The spec never claims the synced
data is authentic, only that it is unreadable.** Its adversary is
honest-but-curious (T2) plus device theft (T4).

The model you specified for this review is **T1 (untrusted provider, read *and*
write) + T2 + T3 (malicious peer) + T4**. T1-active and T3 are absent from the
spec entirely.

#### Why this matters more than a documentation fix

Nearly every critical finding above is a *consequence* of this gap rather than
an independent defect:

| Finding | Under the spec's passive model | Under the intended active model |
| :--- | :--- | :--- |
| S-1 SSTable parsing | Robustness bug — bad input is corruption, not attack | Remote DoS, persistent sync denial |
| S-4 vault verification | Acceptable — a passive provider won't substitute blobs | Content substitution + encryption downgrade |
| S-6 lease deletion | Acceptable — peers are trusted by construction | Confused-deputy data destruction |
| E-2 no AAD | Acceptable — a reader gains nothing from relocation | Records can be moved and rolled back |

Read that way, the implementation is largely **faithful to the model it
documents**. The codebase consistently treats everything inside the sync folder
as trusted-because-it-is-in-the-sync-folder, which is coherent for T2/T4 and
indefensible for T1/T3. That is why the fixes for S-1, S-4 and S-6 cluster
around the same idea: *sync-folder content is input, not truth.*

#### The decision this forces

Closing the gap for real is **architectural, not a patch**. Authenticating
synced data means a MAC or signature over SSTables, vault blobs, leases, and
high-water marks, keyed by something peers share and the provider does not —
plus a story for key distribution and revocation when a device is lost. That is
a design cycle, not a release fix.

So `0.1.0` has three honest options, and this is a product decision rather than
a technical one:

- **(a) Narrow the claim.** Ship with the spec's passive model, stated
  prominently and unambiguously in the README and §31 — "encryption protects
  confidentiality against a provider who reads your data; it does not protect
  integrity against one who modifies it, and all devices with sync access are
  fully trusted." Still fix S-1/S-2/S-6/S-7 as robustness and correctness bugs,
  because corruption and buggy peers are real without any attacker. This is the
  only option that ships on a normal timescale.
- **(b) Delay and close the gap.** Design and implement authenticated sync
  before `0.1.0`.
- **(c) Ship (a) now, commit to (b) publicly** on a named later version, so
  users can judge whether the current boundary suits them.

My recommendation is **(c)**. (a) alone risks the same problem the 0.08
reconciliation had to fix — documentation that overstates protection — while (b)
converts a release into a research project. What must **not** happen is shipping
`0.1.0` with prose implying protection against a hostile provider while the
implementation assumes a polite one.

---

### E-2 — AES-GCM is used with no associated data 🟠

`AesGcmEncryptionProvider` encrypts with a fresh random 96-bit nonce and no
**associated data**. A search across `packages/kmdb/lib/src/encryption` for
`aad`, `associatedData`, or `additionalAuthenticatedData` returns **nothing**.

The consequence: a ciphertext authenticates only *itself*, never *where it
belongs*. Nothing cryptographically binds an encrypted value to its document
key, namespace, collection, or version. An adversary who can write SSTables
(S-1 shows crafting them is practical) can therefore:

- **Relocate** a valid encrypted value from document A to document B. It
  decrypts cleanly and the GCM tag verifies, because the tag never covered the
  key.
- **Roll back** a document by re-placing an older ciphertext at the same key
  with a newer HLC — a replay that authentication cannot detect.
- **Transplant** values across namespaces or collections.

In each case the victim sees correctly-decrypting, apparently-authentic data
that the owner never wrote there.

The fix is cheap and standard: pass a context string as AAD — namespace,
document key, and record type at minimum — so a relocated ciphertext fails
authentication. `package:cryptography`'s `AesGcm.encrypt` already accepts `aad`,
so this is a small change to `encrypt`/`decrypt` plus a format-version bump.
Note it is a **breaking format change**, which is a strong argument for doing it
*before* `0.1.0` freezes the on-disk format rather than after.

Severity is 🟠 rather than 🔴 only because exploitation presupposes the
active-writer adversary that §31 does not currently admit (E-1). If E-1 is
resolved as option (a) — narrowing the claim — this drops to a documented
limitation. If the intended model stands, it is a genuine 🔴.

---

### E-3 — Nonce, KDF, and HKDF review: no findings ✅

Reported explicitly because these were the specific catastrophic failure modes
the review went looking for, and they are handled correctly.

- **Nonce management is sound.** `AesGcm.with256bits(nonceLength: 12)` with a
  fresh `_algorithm.newNonce()` per call
  ([encryption_provider.dart:140–147](packages/kmdb/lib/src/encryption/encryption_provider.dart#L140)),
  backed by `package:cryptography`'s CSPRNG. There is no counter, no derived
  nonce, and no reuse across re-encryption, compaction, or multi-device writes —
  the failure mode that would have been catastrophic simply is not present.
  *Residual note:* random 96-bit nonces carry a birthday bound; NIST SP 800-38D
  advises ≤2^32 invocations per key. Each value write is one invocation, so a
  long-lived database under a single DEK could approach that. Worth documenting
  the limit and confirming a DEK-rotation story exists — but it is not a defect.
- **Argon2id parameters are defensible.** 64 MiB memory, 3 iterations,
  parallelism 1, 256-bit output, 32-byte random salt
  ([key_derivation.dart:50–60](packages/kmdb/lib/src/encryption/key_derivation.dart#L50)).
  That matches RFC 9106's second recommended profile (`m=64 MiB, t=3`), with
  `p=1` a reasonable choice for single-threaded Dart, and comfortably exceeds
  the OWASP floor.
- **The empty HKDF salt is fine.** `nonce: const <int>[]` at
  [encryption_provider.dart:248](packages/kmdb/lib/src/encryption/encryption_provider.dart#L248)
  reads alarmingly like an empty GCM nonce, but `Hkdf.deriveKey`'s `nonce`
  parameter *is* the HKDF salt, which RFC 5869 makes optional — and the input
  keying material is an already-uniform 256-bit DEK, so HKDF-Expand with a
  distinct `info` label is correct. Flagging it here so a future reviewer does
  not re-raise it. A clarifying comment at that line would be worth adding.

---

### C-1 — Windows credential protection assumes a location the code does not control 🟢

> **Revised 2026-07-19, downgraded 🟡 → 🟢 after maintainer feedback.** My
> original framing ("credentials are unprotected on Windows") was wrong. Skipping
> `chmod` on Windows is a **deliberate, documented, precedented decision**, not
> an oversight — see
> [plan_0_09_cli_keychain_credentials.md:55–67](docs/plans/completed/plan_0_09_cli_keychain_credentials.md#L55).
> `gcloud` (`%APPDATA%\gcloud`) and OpenSSH (`~/.ssh`) both rely on exactly this
> model, and the plan surveyed OS-native keychain integration and consciously
> deferred it. I should have found that plan before writing the finding.

What survives is narrower, and is a gap in the *rationale* rather than the
decision. The plan's reasoning is that `{dbDir}/local/` "gets the same free ride
from whatever directory the user chose for their database." The two cases are
not equivalent:

| | `gcloud` | KMDB |
| :--- | :--- | :--- |
| Credential location | `%APPDATA%\gcloud` — **fixed**, always under the user profile | `{dbDir}/local/` — an **arbitrary positional CLI argument** |
| Profile ACL inheritance | Guaranteed by construction | Holds only if the user happened to put their database there |

`gcloud` controls its own credential path, so the profile-ACL inheritance it
relies on is a property it can guarantee. KMDB inherits whatever location the
user passed as `kmdb <db> …`. The inheritance assumption then fails for a
database placed on a non-system volume (a freshly-formatted `D:\` grants
`Users` full control at the root, and children inherit), a network share or
mapped drive, `C:\ProgramData`, or a directory inside a OneDrive/Dropbox-synced
folder — where the credentials would themselves be replicated.

There is also an **asymmetry worth naming**: on POSIX the protection travels
*with the file* (`chmod 700`/`600` applied wherever `dbDir` is, plus a read-side
hard refusal if the mode is ever loosened). On Windows the protection is a
property of *where the file happens to sit*, and there is no read-side check
that could detect the assumption failing.

Low severity — the common case (a database under the user profile) is genuinely
fine, and this matches accepted industry practice. Cheapest fixes, in
preference order, and none of them require `icacls`:

1. **Document the constraint** where users will see it: on Windows, keep the
   database under your user profile if you store sync credentials in it.
2. **Warn on write** when `dbDir` is not under `%USERPROFILE%` — cheap, and it
   turns a silent assumption into an informed choice.
3. Optionally, a Windows read-side equivalent of the POSIX refusal.

### C-2 — REPL history is unfiltered and world-readable 🟢

`History.add` records every submitted line with no filtering, and the file is
written with `writeAsString` and no permission tightening
([history.dart:91](packages/kmdb_cli/lib/src/repl/history.dart#L91),
[:81](packages/kmdb_cli/lib/src/repl/history.dart#L81)) — typically mode 644,
i.e. readable by other local users. Shell histories are conventionally 600.

Impact is limited because **no CLI command accepts a secret as an argument** (I
checked: no `--token`/`--secret`/`--password`-style options exist anywhere), so
passphrases cannot land here. The residual exposure is document content echoed
in queries. Fix: `chmod 600` the history file, reusing the credential store's
existing helper.

### C-3 — Credential store, passphrase intake, and transport: no findings ✅

Recorded explicitly because this area was expected to yield findings and did
not. It is the strongest security work in the codebase.

- **Passphrase intake is correct.** Read only from interactive stdin with
  `echoMode = false`, and — importantly — restored in a **`finally`**
  ([encryption_command.dart:197–206](packages/kmdb_cli/lib/src/commands/encryption_command.dart#L197)),
  so an exception mid-read cannot leave the user's terminal with echo disabled.
- **No secret ever reaches `argv` or the environment.** There is no
  `--passphrase` flag and no secret-bearing env var. This is the single most
  commonly botched thing in CLI crypto tooling, and it is right here.
- **The POSIX credential store is thoughtfully engineered.** Directory chmod'd
  to `700` *before* the file is written — closing the window where a
  world-readable file exists by path — then the file chmod'd to `600`. If the
  file chmod fails, the secret is **deleted** rather than left at loose
  permissions
  ([directory_credential_store.dart:127–146](packages/kmdb_cli/lib/src/config/credential_store/directory_credential_store.dart#L127)).
  Reads refuse a loosely-permissioned file and name the exact `chmod` command to
  fix it. The reasoning is documented at each step.
- **No transport weakening.** No `http://` URLs, no
  `badCertificateCallback`, and no certificate-validation overrides anywhere in
  `kmdb_google_drive` or `kmdb_icloud`; both rely on the platform TLS stack.

---

### F-1 — Native allocations happen before the `try` 🟢

In `ZstdSimple.compress`, two buffers are allocated and *then* the `try` opens
([zstd_native.dart:111–115](/Users/gonk/development/bettongia/zstd/lib/src/zstd_native.dart#L111)):

```dart
final srcPtr = malloc<Uint8>(srcSize);
final dstPtr = malloc<Uint8>(dstCapacity);   // if this throws, srcPtr leaks
try { … } finally { malloc.free(srcPtr); malloc.free(dstPtr); }
```

`package:ffi`'s allocator throws when the OS refuses an allocation, so a large
`dstCapacity` leaks `srcPtr`. `betto_icu` has the same shape with `textBuf` /
`statusBuf` ([icu_tokenizer.dart:265–269](/Users/gonk/development/bettongia/icu/lib/src/icu_tokenizer.dart#L265)).

Low severity — it requires an allocation failure, and the process is already in
trouble at that point. Notably, `decompress` in the same file gets it *right*
(nested `try`/`finally` per allocation); mirroring that structure in `compress`
is a two-line fix.

### F-2 — FFI memory safety and isolate safety: no findings ✅

The FFI review found **no memory-corruption, use-after-free, or race
conditions**. Recording the specific things checked, since "no findings" is only
meaningful if the search was real:

- **No GC-relocation hazard.** Both packages **copy** Dart data into
  native memory (`srcPtr.asTypedList(srcSize).setAll(0, data)`;
  `textBuf[i] = codeUnits[i]`) rather than handing a `Uint8List`'s backing store
  to native code. This sidesteps the entire class of use-after-move bugs that
  arise from passing unpinned Dart buffers across FFI.
- **Return codes are checked before use as lengths.** `compress` validates both
  `_compressBound` and the compressed size with `_isError` before either is used
  ([zstd_native.dart:105](/Users/gonk/development/bettongia/zstd/lib/src/zstd_native.dart#L105),
  [:126](/Users/gonk/development/bettongia/zstd/lib/src/zstd_native.dart#L126)),
  and output buffers are sized by `ZSTD_compressBound` rather than a guess.
- **ICU handle lifetime is correct, including the subtle part.** `ubrk_open`
  retains a pointer to the caller's text buffer, so the buffer must outlive the
  iterator. The nested `finally` closes the iterator *before* the outer
  `finally` frees `textBuf`
  ([icu_tokenizer.dart:328–333](/Users/gonk/development/bettongia/icu/lib/src/icu_tokenizer.dart#L328))
  — the right order, and an easy one to get backwards.
- **No shared native context to race on.** `betto_zstd` uses the one-shot
  stateless API; there is no `ZSTD_CCtx`/`DCtx` held across calls, so the vault
  indexing isolate (O-4) cannot corrupt a shared compression context. Isolate
  safety here is structural rather than accidental.

> **A useful result for the O-1c version-skew risk.** §3 flagged that reviewing
> local HEAD might audit code KMDB has never tested against. For `betto_zstd`,
> `git diff 0.1.0-dev.3..HEAD -- lib/` is **empty** — every commit since the
> published version is documentation or roadmap. The FFI KMDB builds against
> today and the FFI a `0.1.0` would be cut from are **identical**, so this
> review's conclusions carry over unchanged. That removes the risk for the
> highest-stakes native dependency, though it still needs confirming per-package
> for the other eleven.

The one serious defect on the native path is **S-2** (unbounded allocation from
the attacker-declared decompressed size), which is a missing-bounds-check
problem rather than a memory-safety one — recorded above with the security
findings because that is where its impact lands.

---

### L-1 — `kmdb help <unknown>` crashes instead of erroring 🟡

```
$ kmdb help put
Unhandled exception:
Could not find a command named "put".
…
exit=255
```

An unrecognised sub-command passed to `help` escapes as an **unhandled Dart
exception** with exit code 255, rather than a clean diagnostic. The same
mistake is *not* made elsewhere — `kmdb <db> put …` correctly prints
`Error: unknown command 'put'. Run 'kmdb --help' for a list of commands.` and
exits 1, and `--db` (a flag that does not exist) is likewise rejected cleanly.
So `help` is the odd one out.

Exit 255 is Dart's uncaught-exception code, which means a script cannot
distinguish "you asked for help on a typo" from "the CLI crashed". Fix: route
the unknown-`help`-topic path through the same handler the unknown-command path
already uses.

*(Aside: `put` is genuinely not a command — insertion is `insert`. The finding
is the crash, not the missing command.)*

### L-2 — Core CLI lifecycle: no findings ✅

Exercised end-to-end against a real on-disk database (not the memory adapter):

| Command | Result |
| :--- | :--- |
| `create-collection notes` | ✅ `{"name":"notes","created":true}`, exit 0 |
| `insert notes --value '{…}'` | ✅ document returned with generated `_id`, exit 0 |
| `count notes` | ✅ `{"count":1}`, exit 0 |
| `scan notes --limit 2` | ✅ document returned, exit 0 |
| `verify` | ✅ `{"checked":1,"errors":0}`, exit 0 |
| `stats` | ✅ correct L0/L1/L2 SSTable counts |
| `get notes <missing-key>` | ✅ exit 1 |
| `<unknown command>` | ✅ clean error, exit 1 |

**Exit codes are accurate**, which matters more than it sounds: a CLI that
prints errors but exits 0 is unusable in scripts, and this one gets it right.

> **Correction worth recording**, since it nearly became a false finding: my
> first pass appeared to show errors returning exit 0. That was an artefact of
> reading `$?` after a shell pipeline (`… | tail`), which yields `tail`'s status,
> not the CLI's. Re-measured without the pipe, the exit codes are correct. The
> identical mistake also made the phase-0 test run look green before it had
> actually executed. **Any exit code in this document was measured without a
> pipeline.**

---

### D-1 — A dead indexing isolate hangs `close()` before the flush 🟠

**If the vault indexing isolate dies with work in flight, `KmdbDatabase.close()`
never returns — and the memtable flush it was about to perform never happens.**

Three things combine:

1. **`Isolate.spawn` is called with no `onError:` or `onExit:` port**
   ([vault_indexing_isolate.dart:232](packages/kmdb/lib/src/vault/search/vault_indexing_isolate.dart#L232)).
   Nothing observes isolate death.
2. **Nothing times out.** `sendWork` stores a `_PendingWork` completer and
   returns its future; `_onResult` is the *only* path that completes it, and it
   only fires when a message arrives. `VaultSearchManager` awaits it bare —
   `result = await _isolate!.sendWork(item);`
   ([vault_search_manager.dart:591](packages/kmdb/lib/src/vault/search/vault_search_manager.dart#L591))
   — with no timeout. A dead isolate sends no message, so the future never
   completes.
3. **`shutdown()` waits on that same completer** before signalling the isolate
   ([vault_indexing_isolate.dart:264](packages/kmdb/lib/src/vault/search/vault_indexing_isolate.dart#L264)),
   so the graceful-close path inherits the hang.

The consequence is in the close ordering:

```dart
Future<void> close({bool flush = true}) async {
  await _vaultSearchManager?.close();   // ← hangs here
  await _cache.close(flush: flush);     // ← the flush. Never reached.
  _embeddingModel?.dispose();
}
```
([kmdb_database.dart:1005–1014](packages/kmdb/lib/src/query/kmdb_database.dart#L1005))

The user calls `close()`, it never returns, they kill the process — and the
memtable was never flushed.

#### What can actually kill the isolate

`_processWorkItem` wraps `extractor.extract` in a `try`/`catch`, so ordinary
Dart failures are caught and returned as a result with an `error` field. Only a
**hard** death gets through — which is precisely what the isolate's workload
invites:

- **A native crash in PDFium.** `kmdb_extractor_pdf` runs a large native parser
  over adversary-supplied bytes inside this isolate. A segfault there is not
  catchable.
- **OOM.** Per **S-8** the extractors have no size, depth, or time bounds, and
  per **S-2** there is no decompressed-size cap — so a bomb blob can exhaust the
  isolate's heap.

So this compounds with S-2 and S-8 rather than standing alone: they supply the
trigger, and D-1 turns "one blob failed to index" into "the database will not
close."

#### Severity

🟠 rather than 🔴 because it is **not silent data loss**: the writes are in the
WAL, and D-2 confirms the C1 crash-recovery fix still replays it correctly, so a
forced kill is recoverable on reopen. What the user gets is a hang, an
unclean shutdown, and a `hadInterruptedWrites` flag.

It is worth noting the mobile case is worse: §15 observes that mobile and web
processes are killed silently, so a `close()` that hangs during app suspension
is likely to be terminated by the OS mid-shutdown.

#### Recommended fix

1. Pass `onError:` and `onExit:` ports to `Isolate.spawn` and complete the
   in-flight completer with an error when either fires.
2. Put a timeout on `sendWork` — indexing is best-effort, and no blob is worth
   blocking a close.
3. Make `shutdown()` bounded: wait for in-flight work, but abandon it after a
   deadline and kill the isolate.
4. **Reorder `close()` so the flush is not behind best-effort index work**, or
   wrap the vault-search close so it can never propagate a hang into the
   durability path. Indexing is derived state and rebuildable; the memtable is
   not.
5. With S-8's bounds in place, the trigger largely disappears — but the missing
   death handling should be fixed regardless, since native crashes cannot be
   bounded away.

### D-2 — The v0.02.01 durability hardening held ✅

Regression-checked against the closed items from `docs/roadmap/0_02_01.md`. **No
reversions found.**

- **C1** (post-flush WAL writes destroyed on recovery) — correctly fixed. The
  replay boundary is `if (seq < state.maxLogNumber)`
  ([crash_recovery.dart:180](packages/kmdb/lib/src/engine/kvstore/crash_recovery.dart#L180)),
  strictly-less-than, with a comment stating the reason the original review
  found: *"the active WAL's own sequence equals maxLogNumber."* This is the
  fix the confirmed data-loss bug demanded, and it is intact.
- **C2 / H1 / M3** (manifest fsync, `syncDir`, `CURRENT` swap) — `syncFile`/
  `syncDir` calls present throughout `manifest_writer.dart`, `current_file.dart`
  and `lsm_engine.dart`.
- **H2** (atomic `WriteBatch` WAL frame) — present in `wal_record.dart`.
- **H4** (tombstone GC gated on the sync horizon) — horizon/floor logic present
  in `compaction_job.dart`.
- **H5** (lease CAS atomicity) — `compareAndSwap` used throughout
  `consolidation_coordinator.dart`.
- **M1** (SSTable reader caching) — `table_cache.dart` present and on the ingest
  path.

This matters beyond its own sake: D-1's severity assessment *depends* on C1
still working, and it does.

### D-3 — Fault injection stops at the sync boundary 🟡

`FaultyStorageAdapter` is real and used — six test files exercise it across
encryption crash-safety, `$meta` encryption, manifest fsync recovery, WAL
behaviour, vault GC recovery, and the vault search manager. That is genuine
durability fault injection and it does its job.

**But no test under `test/sync/` uses it.** The fault-injection harness the
2026-05-22 review demanded was built for *local durability* paths, and the sync
ingest path — the one place where bytes arrive from outside the process — runs
exclusively on `MemoryStorageAdapter`.

That is the same structural gap S-1 exploits, seen from the other side: the
project has the right tool and has not yet pointed it at the trust boundary.
Fixing this is already Phase 8 of the hardening plan (*run the sync tests
against `StorageAdapterNative`*); this finding records **why** that item exists,
so it does not get dropped as optional polish.

### O-4 — The indexing isolate does not break the §18 model ✅

Raised as an unverified concern in §3: a real isolate in a system whose spec
describes a synchronous, single-threaded model. **Investigated and cleared** —
the boundary is well designed.

- **Only pure data crosses.** `VaultWorkItem` carries a hash, a media type, raw
  bytes and two ints; `VaultIndexResult` returns text, chunk records, and
  term-frequency maps. **No `KvStore`, no `StorageAdapter`, and no database
  handle** is sent, so the isolate structurally cannot write to storage and
  cannot violate the single-writer invariant.
- **The DEK never crosses.** Decryption happens on the main isolate before the
  work item is built — documented on `VaultWorkItem.bytes` and correct.
- **Thread-affine native resources stay put.** ORT embedding is deliberately
  kept on the main isolate (annotated RQ-3/RQ-5), which is the right call and
  avoids the shared-native-context hazard W3 went looking for.
- **Concurrency is bounded to one item**, asserted in `sendWork`.

The isolate is a pure compute worker. §18's model is intact; the defect found
here (D-1) is about *lifecycle*, not concurrency.

---

### SC-1 — §31 claims a DEK-cache verification step that does not exist 🟠 (CONFIRMED)

§31's *DEK Cache* section makes an explicit, security-relevant promise:

> If the DEK is found in the cache, Argon2id is skipped and the cached DEK is
> used directly (**only AES-GCM decryption of `enc:blob` is still performed to
> confirm the cached key is correct**).

**No such confirmation is performed.** `_runEncryptionBootstrap`
([kmdb_database.dart:732–735](packages/kmdb/lib/src/query/kmdb_database.dart#L732))
is the whole of State 5's cache path:

```dart
final cachedDek = await encryptionConfig!.dekCache.read(dbId);
if (cachedDek != null) {
  return encryptionConfig.buildProvider(cachedDek);
}
```

The cached bytes are wrapped in a provider and returned. `enc:blob` is never
consulted, the passphrase the caller supplied is never used, and no AES-GCM
operation runs.

#### Consequence 1 — the passphrase is not a gate on a cache hit (reproduced)

A throwaway probe, run 2026-07-20 against `MemoryStorageAdapter`: provision a
database with passphrase `correct-horse-battery-staple` and an
`InMemoryDekCache`, close, then reopen with the *same cache* and the passphrase
`totally-the-wrong-passphrase`:

```
PROBE A RESULT: open() SUCCEEDED with a wrong passphrase
```

Any application that re-prompts for the passphrase as an authorisation gate —
a lock screen, a re-authentication step before viewing sensitive records — gets
**nothing** from that prompt whenever a `DekCache` is populated. This is the
recommended production configuration on mobile: §31 tells Flutter hosts to
inject `FlutterSecureDekCache` so "the user is only prompted once per device,"
and `KeychainAccessibility.first_unlock_this_device` means the DEK is readable
from the Keychain for the whole of an unlocked session. The passphrase check
that §31 documents as the backstop is absent exactly where the cache is most
likely to be warm.

#### Consequence 2 — a stale DEK fails late and unattributably

A second probe recreated a database at the same path with a new passphrase and
DEK while a stale entry for that path remained in the cache — the
`FlutterSecureDekCache` shape exactly, since it keys on
`kmdb_dek_<base64url(utf8(path))>` and the Keychain outlives a deleted database
directory. Opening with the correct new credentials but the stale cache fails:

```
EncryptionError(badCredentials): AES-GCM authentication failed
  package:kmdb/src/encryption/encryption_provider.dart 197:7  decrypt
  package:kmdb/src/engine/kvstore/meta_store.dart 238:23      MetaStore.getNamespaces
  package:kmdb/src/query/kmdb_database.dart 539:31            KmdbDatabase.open
```

Two things are worth separating here. The **good** news is that Gap 3's `$meta`
encryption incidentally catches the stale DEK, so this does not silently
proceed to write user data under the wrong key — the blast radius is far
smaller than the missing check alone would suggest. The **bad** news is that it
surfaces as an unattributed authentication failure from inside
`MetaStore.getNamespaces`, four frames below the bootstrap, rather than as the
clean `EncryptionError.badCredentials` the bootstrap exists to raise. A host
cannot distinguish "your passphrase is wrong" from "your DEK cache is stale,
clear it" — and §31's error-code table offers no code for the latter.

That incidental protection is also *conditional*: it holds only because `$meta`
is encrypted and non-empty. It is not a designed check, nothing tests it as
one, and any future change that reads a cached DEK before the first `$meta`
access removes it silently.

#### Recommended fix

Either implement the verification §31 already documents — after a cache hit,
unwrap `enc:blob` (or trial-decrypt a known `$meta` value) with the cached DEK
and reject on failure — or, if the cache is meant to bypass credential checking
by design, say so plainly in §31 and remove the sentence claiming otherwise.
The first is a few lines and restores the documented behaviour; the second is a
deliberate weakening of a security claim and should be an explicit decision, not
a silent one. Whichever is chosen, a stale-cache open needs its own error code.

**Do not resolve this by editing §31 to match the code without deciding the
question first** — that is precisely the reconciliation failure mode §4 flagged.

---

### SC-2 — §31 documents a vault blob format PR #61 replaced 🟠

PR #61 fixed S-4 by making the vault blob **self-describing**: the blob is
wrapped through `EncryptionEnvelope` unconditionally, and `getBytes` decides
whether to decrypt from the blob's own leading flag byte, never from the synced
manifest. `VaultStore.ingest`
([vault_store.dart:251–253](packages/kmdb/lib/src/vault/vault_store.dart#L251))
and `getBytes` ([:368–375](packages/kmdb/lib/src/vault/vault_store.dart#L368))
implement this, and §24 was updated correctly
([24_vault.md:618–661](docs/spec/24_vault.md)).

**§31 was not.** Its *Vault Encryption* section still specifies the superseded
layout, with no flag byte:

```
stored = nonce(12B) || AES-GCM-256(key=dek, plaintext=blob) || tag(16B)
```

and still describes the **vulnerable** read path as current behaviour:

> When reading a blob, `VaultStore.getBytes()` checks this flag. If
> `encrypted: true` but no `EncryptionProvider` is available, a `StateError` is
> thrown.

Both statements are now false. The actual stored form is
`[EncryptionFlag 1B] || …` in **both** the encrypted and unencrypted cases, and
`getBytes` deliberately does *not* consult `manifest.encrypted` — that it once
did was the S-4 vulnerability.

Two distinct problems follow. First, §24 and §31 now give **contradictory byte
layouts for the same file**, and §08's framing makes on-disk formats a `0.1.0`
promise. Second, §31 is the document a security-conscious reader consults; it
currently documents the pre-fix, attacker-controllable decryption gate as
though it were the design. A reader auditing KMDB's vault integrity from §31
alone would conclude the S-4 finding is still open.

§31 also omits the new `VaultContentMismatchException` verification-on-every-read
guarantee that §24 documents and `getBytes` implements — a real security
property that the security spec does not currently claim.

**Fix:** update §31's *Vault Encryption* to point at §24 as the normative
description rather than restating the layout, and delete the manifest-flag
sentence. Duplicated byte-layout prose in two specs is what produced this drift;
one authority per format is the durable fix.

---

### SC-3 — §15's Materialised View Cache does not exist 🟠

§15 opens by stating the Cache Layer "provides two distinct caches," the second
being:

> **Materialised view cache** — persisted scan results in the `$cache` system
> namespace, surviving process restarts on mobile and web.

Its platform-tier table marks this cache **Required** for both mobile and web,
with the rationale "process silently killed frequently. Must rebuild from
`$cache` on cold open." A full subsection then specifies its behaviour:
generation-stamped CBOR key lists, stale-while-revalidate on mobile/web,
background re-scan, caller notification.

**None of it is implemented.** Every occurrence of `$cache` in
`packages/kmdb/lib` is a doc comment or a system-namespace exclusion list —
there is no write to, or read from, the `$cache` namespace anywhere.
`CacheLayer.scan` explicitly defers it
([cache_layer.dart:145–151](packages/kmdb/lib/src/cache/cache_layer.dart#L145)):

> Materialised view caching (spec §15.3) … **is handled by the Query Layer
> (Phase 7, `KmdbQuery`)**, which has knowledge of the query parameters needed
> to form a stable cache key.

`KmdbQuery` does not implement it either. The deferral points at a layer that
never picked it up, and the hand-off was never reconciled — a
responsibility-shaped gap that reads as "implemented elsewhere" from either end.

§31 is the one document that gets this right, hedging with "when the
materialised-view cache is implemented." §15 and `CLAUDE.md` both describe it in
the present tense.

**Second defect in the same section.** §15 states the session cache size "is
configurable via `KvStoreConfig.sessionCacheMaxObjects`." That field does not
exist anywhere in the workspace. The real seam is the `maxObjects` constructor
parameter on `CacheLayer`
([cache_layer.dart:84–89](packages/kmdb/lib/src/cache/cache_layer.dart#L84)),
which defaults from `CacheTier`. A developer following §15 to tune cache size on
a memory-constrained device will not find the knob it names.

**Why this is High rather than Medium.** §15 does not describe a missing
optimisation; it describes a component it marks *Required* for the two platforms
where KMDB's local-first pitch matters most. A developer architecting a mobile
app around §15 will expect scan results to survive a cold start and will
discover otherwise only at runtime. There is no workaround short of building the
cache themselves.

**Fix:** decide whether `$cache` is in scope for `0.1.0`. If it is not — and
nothing suggests it is — §15 must be rewritten to describe the session cache as
the only implemented tier, with the materialised view cache moved to a clearly
labelled *Planned* section and removed from the tier table's Required column.
`CLAUDE.md`'s Cache Layer summary needs the same correction; it is the
`English-language only` failure mode again, in a different file.

---

### SC-4 — §31's Algorithms table misstates the recovery-KEK derivation 🟡

The recovery code is the last-resort access path to an encrypted database — the
one mechanism a user reaches for when the passphrase is gone. §31's *Algorithms*
table specifies its derivation as:

| Purpose | Algorithm | Parameters |
| :--- | :--- | :--- |
| Recovery entropy → KEK | HKDF-SHA256 | Salt = SHA-256(recovery_entropy), info = `"kmdb-recovery-kek"` |

`KeyDerivation.deriveKekFromRecoveryEntropy`
([key_derivation.dart:106–116](packages/kmdb/lib/src/encryption/key_derivation.dart#L106))
uses neither parameter as documented:

- **Salt** is the empty byte string (`nonce: <int>[]`), not `SHA-256(recovery_entropy)`.
- **Info** is `kmdb-recovery-kek-v1` (20 bytes, `kRecoveryKekInfo`), not
  `kmdb-recovery-kek`.

Neither is a cryptographic weakness — HKDF with an empty salt over a uniformly
random 128-bit IKM is sound, and the info string only needs to be
domain-separating, which it is. The defect is that **the spec's byte-level
recipe does not reproduce the implementation's key.** Anyone writing an
independent recovery tool from §31 — the most plausible reason to read this
table at all — derives the wrong KEK and cannot unwrap the DEK.

Two further symbols in the same area name things that do not exist:

- §31's *Key Derivation* section calls `KeyDerivation.deriveKekFromRecovery(...)`;
  the method is `deriveKekFromRecoveryEntropy`.
- The *Algorithms* table gives DEK generation as "`SecureRandom` from
  `package:cryptography`". There is no `SecureRandom` use in the codebase;
  `generateRandom` extracts bytes from `AesGcm.with256bits().newSecretKey()`
  ([key_derivation.dart:188–197](packages/kmdb/lib/src/encryption/key_derivation.dart#L188)).
  The result is CSPRNG-backed, so the security claim holds — the named API does
  not.

**Fix:** correct the table to `Salt = <empty>, info = "kmdb-recovery-kek-v1"`,
correct the two symbol names, and consider adding a round-trip test vector
(entropy → mnemonic → KEK) to the spec so this table cannot drift again without
a test failing.

---

### SC-5 — §08's device-identity paragraph describes an unimplemented mechanism 🟡

§08's *SSTable Naming Convention* closes with:

> The device ID is a stable per-installation UUID generated on first launch and
> persisted in platform-specific secure storage (Keychain on iOS,
> SharedPreferences on Android, localStorage on web). **It must not be stored
> inside the database itself to avoid circular dependency during bootstrap.**

The code does the thing the paragraph forbids. `DeviceId`
([device_id.dart:21,37–38](packages/kmdb/lib/src/engine/kvstore/device_id.dart#L21))
is explicit:

> The device ID is persisted in `$meta` … Full platform-specific secure storage
> (iOS Keychain, Android SharedPreferences, etc.) is **deferred to Phase 8**.

So the mechanism §08 describes is *unimplemented*, and the prohibition §08
states as an invariant is *violated by design*. §31 gap 4 confirms the real
location, listing "device ID" among the `$meta` entries now encrypted — meaning
§08 and §31 contradict each other on where device identity lives.

The consequence worth stating is behavioural, not cosmetic: because identity
lives in the database rather than beside it, **deleting and recreating a local
database produces a new device ID**. A reader of §08 would reasonably expect
identity to survive that, and would design sync recovery, `.hwm` bookkeeping,
and peer-liveness logic on that assumption. (This is also the mechanism behind
SC-1's stale-cache scenario: the DEK cache keys on the *path*, which is stable
across a recreate, while the device ID is not.)

Note that the Phase 8 deferral in `device_id.dart` predates the Implementation
Status table's "Phase 8 ✅ Complete" entry, which does not mention device
identity — worth checking whether the deferral was consciously carried past
Phase 8 or simply lost.

**Fix:** rewrite the paragraph to describe `$meta` storage as the implemented
mechanism, state the recreate-changes-identity consequence explicitly, and move
the secure-storage design to a *Planned* note cross-referenced to the roadmap
`PlatformIdStore` item that §31 already cites.

---

### SC-6 — §31's Provisioning Guard describes a different check than the code performs 🟡

§31:

> State 4 (provisioning an empty database) rejects databases that already
> contain any KV entries. **The check is performed by scanning the `$meta`
> namespace for existing records and verifying the database is truly empty.**

The code
([kmdb_database.dart:678–683](packages/kmdb/lib/src/query/kmdb_database.dart#L678))
inverts this — it lists namespaces and considers only those *not* beginning
with `$`:

```dart
final userNamespaces = (await store.listNamespaces())
    .where((ns) => !ns.startsWith(r'$'))
    .toList();
if (userNamespaces.isNotEmpty) {
  throw EncryptionError.cannotProvisionNonEmptyDatabase();
}
```

Scanning `$meta` as §31 describes could not work — `$meta` is never empty (it
holds `device_id` and the format-version marker from the moment the database is
created), so a literal implementation would reject every provisioning attempt.
The code's check is the sensible one; the spec sentence is simply wrong about
what it does.

The reason this is worth more than a wording fix is the gap it leaves. The guard
sees only user collections, so a database that has accumulated **only**
system-namespace state — `$vault:` ref-counts and plaintext vault blobs from
attachment ingestion, `$ver:` history, `$$fts:` indexes — passes the guard and
can be retroactively provisioned. §31 gap 5 asserts the opposite as a
load-bearing invariant:

> a database is either born encrypted or never encrypted, so the two are always
> set in lockstep; **there is no scenario where one is encrypted and the other
> is not**.

Per-blob `manifest.encrypted` and the SC-2 self-describing envelope mean such a
database still *reads* correctly — this is not a data-loss path. But it
produces exactly the mixed encrypted/plaintext state §31 says cannot arise, and
pre-existing vault blobs stay plaintext on disk and in the cloud with no
indication to the user that provisioning did not cover them.

I have **not** built an end-to-end reproduction of vault-only ingestion
preceding provisioning; whether `VaultStore.ingest` can be reached without
registering a user namespace needs confirming before this is treated as more
than a documentation defect. Recorded as reasoned-about, not confirmed.

**Fix:** correct §31's description of the check. Separately, decide whether the
guard should also reject on `$vault:`/`$ver:` state, and either tighten it or
narrow gap 5's lockstep claim to match.

---

### SC-7 — §05 overstates the vault blob size bound 🟢

§05's *Decompressed-Size Bound* section closes:

> Vault blobs are **not** compressed by this codec at all and are bounded
> separately and much more generously (`VaultSearchConfig.maxBlobBytes`, §24).

`maxBlobBytes` (default 200 MiB) has exactly one enforcement site:
`VaultSearchManager`
([vault_search_manager.dart:584](packages/kmdb/lib/src/vault/search/vault_search_manager.dart#L584)),
which skips *search extraction* for oversized blobs. It is not enforced by
`VaultStore.ingest` or `VaultStore.getBytes`, so the vault read path itself is
unbounded — and the check tests `bytes.length` on a blob **already fully read
into memory**, so it does not prevent the allocation it appears to bound; it
only prevents handing the result to an extractor.

The sentence is defensible as written about *extraction*, but a reader tracing
S-2's remediation will read "vault blobs are bounded" as a statement about the
read path, which is the surface a hostile synced blob actually arrives on.

**Fix:** say that the bound is on search extraction specifically, applied
post-read, and that the vault read path has no size bound today.

---

### SC-8 — Minor drift 🟢

Two small items, recorded so they are not rediscovered:

- **The encrypted branch of the S-2 bound is untested.** §05 states
  `kMaxDecodedValueBytes` is enforced "on both the encrypted and plaintext
  branches," and it is
  ([value_codec.dart:219](packages/kmdb/lib/src/encoding/value_codec.dart#L219)
  and [:239](packages/kmdb/lib/src/encoding/value_codec.dart#L239)). Only the
  plaintext branch has a test
  (`test/encoding/value_codec_test.dart:375`); a regression that dropped the
  `_checkDecodedSize` call from the encrypted branch would pass the suite.
  Verdict `untested`, not `divergent`.
- **"4-state matrix" over a 5-state table.** Both §31's *Bootstrap Sequence* and
  the doc comment at
  [kmdb_database.dart:343](packages/kmdb/lib/src/query/kmdb_database.dart#L343)
  call it a 4-state matrix; the table beneath enumerates States 1–5. The states
  themselves are correct and correctly implemented — only the count is wrong,
  in both places.

---

### SC-9 — PR #61's spec edits are accurate ✅

Because the §05/§08/§12/§17/§18/§24 edits landed days before this pass, they
were traced claim-by-claim rather than assumed. They hold up, and the areas that
generated this review's criticals are now the best-documented in the spec:

- **§08's untrusted-input validation section** matches `SstableReader` field by
  field — footer bounds, index `keyLen`, block `shared`/`unsharedLen`/`valueLen`,
  varint sign rejection, and the uniform funnel to `CorruptedSstableException`.
  The hostile corpus exists (`test/util/hostile_sstable.dart`,
  `test/engine/sstable_hostile_parsing_test.dart`) and covers the classes the
  section names.
- **The quarantine claim is real.** §08's "a rejected peer file's high-water
  mark still advances past it" is implemented — `SyncEngine.pull` catches
  `CorruptedSstableException`, `FormatException`, `RangeError`,
  `StorageException` *and* `OutOfMemoryError`, advancing the peer HWM on each
  ([sync_engine.dart:578–624](packages/kmdb/lib/src/sync/sync_engine.dart#L578)).
  This directly reverses S-1's re-poisoning behaviour. (§08 lists four of those
  five types; the `OutOfMemoryError` catch is undocumented but present.)
- **S-6 is fixed on both paths**, which was worth checking specifically since
  the original finding named `commit()` and the obvious fix site is
  `consolidate()`. `_safeSstablePath` is applied in both, plus a third defence
  in `commit` — deleting only paths present in this device's *own* `sstables/`
  listing rather than trusting the lease.
- **§18's D-1 lifecycle bounds** (`kWorkTimeout` 30 s,
  `kShutdownDrainTimeout` 5 s, flush strictly before isolate shutdown) match
  `VaultIndexingIsolate` and `KmdbDatabase.close`, and are covered by
  `test/query/kmdb_database_close_isolate_death_test.dart`.
- **§07's WAL directory-entry durability** claim — that `append`/`appendBatch`
  `syncDir` once per newly-active file — is implemented (`_syncDirOnce`,
  [wal_writer.dart:185](packages/kmdb/lib/src/engine/wal/wal_writer.dart#L185))
  and fault-injection tested against `FaultyStorageAdapter`, including the
  revert-and-confirm-failure check. §07's honest note that retired-WAL
  *deletion* has the mirror-image gap, with its argument for why that is benign,
  also checks out.

The contrast with the findings above is instructive: the specs that were
rewritten under adversarial pressure are accurate, while the drift clusters in
sections nobody has had reason to re-read — §15, §08's naming appendix, §31's
reference tables.

---

## 7. Scoping decisions and remaining questions

### 7.1 Resolved — 2026-07-18

| # | Question | Decision |
| :-- | :--- | :--- |
| Q1 | How far does the FFI review reach into external repos? | **`betto_zstd` + `betto_icu` internals**, plus `betto_pdfium`'s input-validation boundary. `betto_onnxrt` excluded as a recorded risk acceptance. (§2.3) |
| Q2 | Which packages ship in `0.1.0`? | **The entire workspace** — all nine packages, including both cloud adapters, all three extractors, and `kmdb_flutter`. (§2.2) |
| Q3 | What threat model? | **All four adversaries** — untrusted (read+write) provider, honest-but-curious provider, malicious peer device, and device theft. (§W2 threat-model table) |
| Q4 | Report only, or fix as I go? | **Report only.** No code changes during the review; remediation plans drafted as a follow-up once severity is agreed. |
| Q7 | Must `betto_*` dependencies be stable for `0.1.0`? | **Yes — hard gate.** All 12 packages in the direct+indirect closure must reach a suffix-free `0.1.0`. (§3 O-1) |

**What these add up to.** The two consequential decisions are Q2 and Q3, and
they compound. Shipping the whole workspace puts the cloud adapters under the
`0.1.0` promise — and the threat model says the party on the other end of those
adapters is *actively hostile and can write*. So the review's centre of gravity
moves decisively toward **W2c (untrusted-input parsing)**: under T1+T3, every
SSTable, vault blob, highwater file, and lease file pulled from the sync folder
is adversary-controlled input being fed to parsers that were written to read
this codebase's own well-formed output. I would be surprised if that yielded
nothing.

Q4 being "report only" means I will not fix even obvious defects as I find them.
If I hit something severe enough that leaving it unfixed feels wrong, I will
flag it to you immediately rather than quietly breaking the agreement.

### 7.2 Still open

### Q5 — May I delegate workstreams to the project's subagents?

`CLAUDE.md` establishes `kmdb-architect`, `kmdb-qa`, and `kmdb-researcher` and
says to prefer delegating over working inline. For a review this size that would
help — e.g. `kmdb-architect` for the W1 conformance matrix (it is authoritative
on `docs/spec`), `kmdb-qa` for the W6 audit (that is its documented second
mode). W2 and W3 I would keep in the main session; they need the sustained,
suspicious reading that doesn't survive being split across cold-start agents.

I'm asking rather than assuming because subagent fan-out has a real cost and
you may prefer a single reviewer's coherent view.

### Q6 — Is the naming right?

Filed as `release-readiness-review-2026-07-18.md` to match the
`<type>-review-<date>` convention (`code-review-…`, `roadmap-review-…`). It is
substantially a code review, so `code-review-2026-07-18.md` would also be
defensible — say the word and I'll rename before there's anything to link to.

---

## 8. Execution plan

Once the questions above are settled:

| Phase | Work | Output |
| :-- | :-- | :-- |
| 0 | Establish baseline: full test suite, coverage, analyzer, benchmarks | Recorded facts in §3, so findings are measured against a known-good state |
| 1 | **W2c** untrusted-input parsing | Findings — promoted to first position by the T1+T3 threat model |
| 2 | **W2a/W2b** cryptographic construction and confidentiality boundary | Findings, incl. the intended-vs-documented threat-model delta |
| 3 | **W2d/W2e** in-transit and CLI secret hygiene | Findings across both cloud adapters |
| 4 | **W3** FFI and native safety (`betto_zstd`, `betto_icu`, pdfium boundary) | Findings |
| 5 | **W1** spec conformance | Conformance matrix + findings |
| 6 | **W4** concurrency and durability | Findings |
| 7 | **W5** CLI functional sweep | Findings |
| 8 | **W6** code health and release hygiene | Findings + release-checklist status |
| 9 | Synthesis | Executive summary, severity table, `0.1.0` go/no-go recommendation |

The security workstream leads, and within it parsing leads, because that is
where a defect is simultaneously most likely to be severe and least likely to be
caught by the existing suite. The 2026-05-22 review was productive for exactly
this reason: it went looking where the tests structurally could not see. The
equivalent blind spot here is that **every parser test feeds the parser
well-formed input this codebase produced**, while the agreed threat model says
the real input can come from an adversary.

Phases are checkpoints, not a fixed contract — if phase 1 turns up something
critical I will stop and report it rather than working through to phase 9 first.

---

## 9. Coverage actually achieved

**Read this before planning remediation.** The review front-loaded security, and
security is where it spent its budget. Two workstreams did not get a fair pass,
and treating this document as complete coverage would be a mistake.

| Workstream | Status | Notes |
| :--- | :--- | :--- |
| **W2a/W2b** crypto + boundary | ✅ **Complete** | Nonce, KDF, HKDF, AAD, threat-model delta |
| **W2c** untrusted input | ✅ **Complete** | SSTable, WAL, manifest, KVLT, vault, lease, extractors, Zstd |
| **W2d/W2e** transit + CLI secrets | ✅ **Complete** | Credential store, passphrase, TLS, history |
| **W3** FFI safety | ✅ **Complete** | `betto_zstd` + `betto_icu` internals; PDFium boundary via S-8 |
| **W5** CLI | 🟡 **Partial** | Core lifecycle exercised end-to-end; **not** swept: `sync`, `vault`, `search`, `index`, `schema`, `encryption`, `import`/`export`/`restore`, `promote`/`versions`, REPL, `--read` scripts |
| **W6** code health | 🟡 **Partial** | Analyzer clean (all 9 packages); dependency gate analysed (O-1). **Not** done: coverage run, benchmark verification vs §18, public API surface, dead code, doc-comment audit, CHANGELOGs |
| **W1** spec conformance | 🟡 **Partial** (2026-07-20) | Tiers 1–3 audited to depth on their highest-consequence claims; tiers 4–6 **surveyed, not audited**. Found SC-1…SC-8, and confirmed PR #61's spec edits (SC-9). See §11 for the conformance matrix and an explicit statement of what was *not* covered |
| **W4** concurrency + durability | ✅ **Complete** (2026-07-19) | 0.02.01 regression check (D-2), fault-injection coverage (D-3), and O-4 all done. Found **D-1** |

### Specific questions left open

1. ~~**Where does S-2 detonate?**~~ **Resolved 2026-07-19** — on read, not on
   ingest. Compaction decodes only keys and ingest triggers no indexing, so the
   database stays openable and the blast radius is one collection. See S-2's
   "Detonation point" subsection. This was a genuine scope reduction: no
   quarantine-and-repair path is needed.
2. ~~**O-4 — the vault indexing isolate.**~~ **Resolved** — the isolate does not
   violate §18 (only pure data crosses, no DEK, no storage handle). But the
   investigation surfaced **D-1**, a lifecycle defect that hangs `close()`
   before the flush.
3. ~~**Did the 0.02.01 hardening hold?**~~ **Resolved** — yes, verified item by
   item (**D-2**). No reversions.
4. ~~**Is coverage still ≥90%?**~~ **Measured 2026-07-20 on merged `main`
   (post-PR #61): 94.8% (11,181 of 11,800 lines), 205 source files, full suite
   SUCCESS.** Above CLAUDE.md's 90% floor, ~0.2pp below the 95% post-remediation
   baseline.

   **But the more useful answer is the qualitative one**, and it came out of the
   PR #61 QA pass rather than the number. `kmdb-qa` confirmed the hostile-SSTable
   corpus exercises fourteen corruption classes — and found that the **two
   classes it was missing (`blockOffset`/`blockSize`, and varint overflow reached
   *through* SSTable parsing) were precisely the two whose exceptions escaped as
   non-`CorruptedSstableException`**. The corpus gap and the code gap were the
   same gap; a test would have caught the bug. Both have since been added.

   That is the concrete vindication of this section's original warning: line
   coverage on parser files tells you almost nothing, while *corpus* coverage
   found a live defect. Judge future parser work the same way.
5. ~~**Do the §18 benchmarks still meet their P99 targets?**~~ **Run 2026-07-20
   on merged `main` (post-PR #61): 10/10 PASS.** The read-path validation added
   by PR #61 did not regress anything.

   | Operation | P99 | Target | Headroom |
   | :--- | ---: | ---: | ---: |
   | Put / Delete (no flush) | 0.54ms | 5.00ms | 89% |
   | Put (flush + compact) | 8.10ms | 200.0ms | 96% |
   | Get (in memtable) | 0.03ms | 1.00ms | 97% |
   | Get (single-file mode) | 0.18ms | 2.00ms | 91% |
   | Get (multi-level, present) | 0.11ms | 5.00ms | 98% |
   | Get (warm cache, multi-file) | 0.10ms | 5.00ms | 98% |
   | Get (absent key) | 0.17ms | 3.00ms | 94% |
   | **Scan (namespace, 100 results)** | **7.43ms** | **10.0ms** | **26%** |
   | Database open | 1.46ms | 100.0ms | 99% |
   | Index build (2,000 docs) | 38.4ms | 500.0ms | 92% |

   **One number to watch: `Scan` sits at 74% of its budget** while every other
   benchmark is at a few percent of its own. Scan is the operation that decodes
   many values per call, and PR #61's value-size check sits on that path. There
   is no pre-PR baseline, so it is not possible to say whether this is new or
   long-standing — but it is the only benchmark where a future change could
   plausibly breach the target. **Re-run it after the AAD work lands**
   ([plan_0_10_01_value_aad.md](../plans/plan_0_10_01_value_aad.md)), which adds
   per-value AAD construction to exactly this path.

   Note that the §18 P99
   table is itself a set of normative claims with no CI enforcement, so W1
   cannot verify it either — it is `untested` by construction until the
   benchmark is wired into a gate.
6. ~~**W1 spec conformance remains entirely outstanding.**~~ **Partially
   executed 2026-07-20** — tiers 1–3 to depth, tiers 4–6 surveyed only. §11
   records the matrix and, explicitly, the ~60% of spec surface still
   unaudited. The remaining question is now narrower but real: **§12 (2,000+
   lines), §24 (900+), §22, §26, and §13 have had only spot checks**, and
   three of the eight findings came from sections that had never been
   re-read since they were written — which is weak evidence that the
   unaudited remainder is clean.
7. **SC-1 needs a product decision, not just a fix.** Whether a `DekCache` hit
   is *intended* to bypass passphrase verification determines whether the fix
   is code or spec. Do not let this be resolved by editing §31.

### Suggested sequencing for the follow-up pass

W1 and W4 are largely independent of the security remediation and could proceed
in parallel with it. W4 should go first — it carries the S-2 detonation question
and the isolate risk, both of which could change severities already recorded
here. W1 is the larger effort and the better candidate for delegation to
`kmdb-architect`, which is authoritative on `docs/spec/`.

---

## 10. Remediation grouping

Offered as input to roadmap planning. Findings are grouped by the work they
share, not by severity — several cluster into single pieces of work, and
splitting them across plans would duplicate effort.

### Group A — Harden the sync trust boundary *(the big one)*

**S-1, S-2, S-6, S-7, S-3** — all instances of "sync-folder content is input, not
truth." These are worth one coordinated plan rather than four:

- Bounds-validate SSTable footer/index/block fields; make `Varint.decode` reject
  negatives; funnel all structural failures to `CorruptedSstableException`.
- Cap decompressed size in `betto_zstd` and enforce a max decoded-value size in
  `ValueCodec`.
- Validate lease `inputFiles` before any delete; reject separators and `..`.
- Replace the hardcoded `/tmp` staging path with an adapter-derived unique dir.
- Broaden `pull()` / `ingestAt0` catches, and quarantine rather than re-poison.
- **Test work is the point, not an afterthought:** a corpus of checksum-valid
  hostile SSTables, plus running the sync tests against the **native** adapter.
  Without that, this class of bug returns.

*Fix these regardless of how E-1 is decided* — corruption and buggy peers do not
require an attacker.

### Group B — Vault integrity

**S-4** — verify blob content against its address on hydration and read; stop
letting a synced manifest decide whether authentication happens. Small,
self-contained, and high value: hashing on hydration needs no key material and
defeats substitution outright.

### Group C — The threat-model decision *(blocks the others' framing)*

**E-1, E-2** — a product decision first (§7.3 options a/b/c), then either a
documentation narrowing or a design cycle for authenticated sync. **Sequence
this early**, because the answer sets the severity of Groups A and B and decides
whether E-2's AAD change must land before the on-disk format freezes. E-2 is a
breaking format change, which argues strongly for doing it pre-`0.1.0`.

### Group D — Release gate

**O-1, O-1b, O-2** — publish all 12 `betto_*` packages at stable `0.1.0`, add
`betto_abnf` to `CLAUDE.md` and the overrides, reconcile the `kmdb_flutter` /
`kmdb_icloud` pins, and confirm `kmdb_flutter` is in a CI lane. Then re-run the
full suite **against the promoted pins** before tagging.

### Group E — Smaller, independent

**C-1** (document/warn when `dbDir` is outside the Windows user profile),
**C-2** (history file mode), **L-1** (`help` crash), **S-8** (extractor bounds),
**S-5** (`package:crypto`), **F-1** (allocation ordering). Each is small and
independently shippable.

### Group F — Complete the review

~~**W1** spec conformance and~~ **W4** concurrency/durability (§9). W4 is
complete; W1 is **partially** complete as of 2026-07-20 — see §11 for what
remains.

### Group G — Spec corrections (W1)

**SC-1 … SC-8.** Per the review's standing instruction, W1 did **not** edit
`docs/spec/`; the corrections are proposed here and should be sequenced
deliberately. Two of them are not documentation tasks:

- **SC-1** is a code-or-spec decision about whether a `DekCache` hit bypasses
  passphrase verification. **Sequence this first** — it is the only W1 finding
  with a security consequence, and the answer determines whether §31 gains a
  fix or an admission.
- **SC-3** is a scope decision about whether `$cache` ships in `0.1.0`. If it
  does not, §15 and `CLAUDE.md` both need rewriting, not patching.

The rest (SC-2, SC-4, SC-5, SC-6, SC-7, SC-8) are spec edits with no code
change, and can land as one pass. SC-2 should be fixed by making §24 the single
authority for the vault blob layout and having §31 reference it — the
duplication is what caused the drift.

---

## 11. W1 — Spec conformance matrix

**Executed 2026-07-20** against `main` post-PR #61. Method per §4: extract
normative claims — MUST/never/always statements, byte layouts, state machines,
ordering guarantees, numeric thresholds — and trace each to implementing code
and to a test that would fail if it were violated.

### 11.1 Depth actually achieved — read this first

This is a **partial audit reported as partial**. The spec is 10,728 lines; a
complete claim-by-claim trace is a multi-pass effort and this was one pass.

| Tier | Sections | Depth |
| :-- | :--- | :--- |
| 1 | §31 encryption | 🔵 **Audited** — full read, all normative claims traced |
| 1 | §24 vault, §12 sync | 🟡 **Targeted** — encryption/integrity/lease/namespace-exclusion claims traced; the bulk (sync state machine, consolidation recovery, GC) spot-checked only |
| 2 | §05 value encoding, §08 SSTable, §07 WAL | 🔵 **Audited** |
| 2 | §10 manifest | ⚪ **Surveyed** — not traced |
| 3 | §18 concurrency, §17 crash recovery | 🟡 **Targeted** — D-1/PR #61 claims traced; §17 otherwise surveyed |
| 3 | §11 KvStore | ⚪ **Surveyed** |
| 4 | §13 query, §16 indexes, §25 schemas, §26 versioning | ⚪ **Surveyed** — §14/§15 spot-checked (§15 yielded SC-3) |
| 5 | §20–23 text search, §32 vault search | ⚪ **Surveyed** — the `English-language only` drift that motivated W1 was already corrected in `CLAUDE.md` and the §20/§01 working tree |
| 6 | §29/§30 adapters, §33 credential store, §19 platform | ⚪ **Not examined** |

**Roughly 40% of the spec surface received real scrutiny.** Do not read the
absence of findings in §10, §11, §13, §16, §22, §25, §26, §29, §30, §32 or §33
as evidence they are conformant — they were not audited. Given that three of
eight findings (SC-3, SC-5, and half of SC-4) came from reference material
nobody had re-read since it was written, the unaudited remainder should be
assumed to hold drift at a similar rate.

**What would make a second pass cheaper.** The findings cluster by *cause*, not
by section: duplicated byte-layout prose across two specs (SC-2), reference
tables listing API symbols with no test binding them to reality (SC-4, SC-3's
`sessionCacheMaxObjects`), and design intent recorded as present-tense fact
(SC-3, SC-5). A targeted sweep for those three patterns — every API symbol named
in the spec grepped against the codebase, every byte layout appearing in two
places — would likely find most of what remains at a fraction of the cost of a
linear read.

### 11.2 Matrix

Verdicts: **C** conformant (code matches, test enforces) · **U** untested (code
matches, nothing catches a regression) · **D** divergent · **X** unimplemented.

| Spec | Claim | Code site | Test site | Verdict |
| :--- | :--- | :--- | :--- | :-- |
| §31 | AES-256-GCM, 96-bit random nonce, 128-bit tag | `encryption_provider.dart:135–170` | `encryption_provider_test.dart` | **C** |
| §31 | Argon2id m=64 MiB, t=3, p=1, 32-byte output | `key_derivation.dart:51–57,86–91` | `key_derivation_test.dart` | **C** |
| §31 | Recovery KEK: HKDF-SHA256, salt = SHA-256(entropy), info = `kmdb-recovery-kek` | `key_derivation.dart:106–116` — empty salt, info `…-v1` | — | **D** (SC-4) |
| §31 | `KeyDerivation.deriveKekFromRecovery` | method is `deriveKekFromRecoveryEntropy` | — | **D** (SC-4) |
| §31 | DEK generation via `SecureRandom` | `key_derivation.dart:188` — `AesGcm.newSecretKey()` | — | **D** (SC-4) |
| §31 | Encrypted wire format `[0x01][nonce 12B][ct][tag 16B]`; CompressionFlag inside ciphertext | `value_codec.dart:199–220`, `encryption_flag.dart` | `value_codec_encryption_test.dart` | **C** |
| §31 | Unknown `EncryptionFlag` byte → `ArgumentError` | `encryption_flag.dart:60–70` | `encryption_envelope_test.dart` | **C** |
| §31 | `enc:blob` bypasses ValueCodec; structurally exempt from `$meta` encryption | `meta_store.dart` get/putEncryptionBlob | `meta_store_encryption_test.dart` | **C** |
| §31 | Bootstrap state matrix (5 states) — called a "4-state matrix" | `kmdb_database.dart:661–756` | `kmdb_database_encryption_test.dart` | **C** (count wrong, SC-8) |
| §31 | Provisioning guard scans `$meta` for emptiness | `kmdb_database.dart:678–683` — checks non-`$` namespaces only | `kmdb_database_encryption_test.dart` | **D** (SC-6) |
| §31 | Cached DEK verified by AES-GCM decrypt of `enc:blob` | `kmdb_database.dart:732–735` — **no verification** | — | **D** (SC-1) |
| §31 | Format-version gate: 3-way discrimination, `LegacyDatabaseFormatException` | `kv_store_impl.dart` open | `meta_store_encryption_test.dart` | **C** |
| §31 | Recovery code: 16 words, 256-word list, 16 bytes, case-insensitive | `recovery_code.dart` | `recovery_code_test.dart` | **C** |
| §31 | `indexToken` = HMAC-SHA256 under HKDF sub-key, info `kmdb-index-token` | `encryption_provider.dart:228–265` | `encryption_provider_test.dart` | **C** |
| §31 | Vault blob stored as `nonce‖ct‖tag`; `getBytes` gates on `manifest.encrypted` | `vault_store.dart:251–252,368–375` — envelope-framed, manifest not consulted | `vault_encryption_test.dart` | **D** (SC-2) |
| §31 | `$meta`/`$ver:`/`$vault:` sync; `$$`-prefixed are local-only | `sync_engine.dart`, `SstableInfo.localOnly` | `local_only_namespace_test.dart`, `vault_sync_exclusion_test.dart` | **C** |
| §31 | `appendTombstoneFloorAdvance` has zero call sites | `meta_store.dart` | — | **C** |
| §24 | Blob wrapped through `EncryptionEnvelope` unconditionally | `vault_store.dart:251–252` | `vault_encryption_test.dart` | **C** |
| §24 | SHA-256/CRC32C over plaintext | `vault_store.dart:215–216` | `vault_store_test.dart` | **C** |
| §24 | Content verified against address on **every** read | `vault_store.dart:371–374` | `vault_store_test.dart` | **C** |
| §24 | `originalName` encrypted in place, base64, sole decrypt point `getManifest` | `vault_store.dart:297–306,399–421` | `vault_encryption_test.dart` | **C** |
| §12 | Lease `inputFiles` validated before download **and** before delete | `consolidation_coordinator.dart:446–457,597–610,670–681` | `consolidation_coordinator_test.dart` | **C** |
| §12 | `commit` deletes only files in this device's own listing | `consolidation_coordinator.dart:612–631` | `consolidation_coordinator_test.dart` | **C** |
| §12 | Staging path is unique-per-run, not hardcoded `/tmp` (S-7) | `consolidation_coordinator.dart` `_stagingPathFor` | `consolidation_coordinator_test.dart` | **C** |
| §12 | `.local.sst` excluded from push via `SstableInfo.parse(f).localOnly` | `sync_engine.dart:445` | `vault_sync_exclusion_test.dart` | **C** |
| §05 | 2-byte prefix `[EncryptionFlag][CompressionFlag]` | `value_codec.dart:223–240` | `value_codec_test.dart` | **C** |
| §05 | Compression only when `compressed.length < raw.length`; min 64 bytes | `value_codec.dart:34,144` | `value_codec_test.dart` | **C** |
| §05 | `0x02` (Deflate) rejected with `ArgumentError` | `compression_flag.dart` | `value_codec_test.dart` | **C** |
| §05 | `kMaxDecodedValueBytes` = 1 MiB, both branches, post-decompress pre-CBOR | `value_codec.dart:122,219,239` | plaintext branch only (`value_codec_test.dart:375`) | **U** (SC-8) |
| §05 | `DecodedValueTooLargeException` distinct from `FormatException` | `value_codec.dart:317` | `value_codec_test.dart:391` | **C** |
| §05 | Vault blobs bounded by `VaultSearchConfig.maxBlobBytes` | `vault_search_manager.dart:584` — extraction only, post-read | `vault_search_manager_test.dart` | **D** (SC-7) |
| §08 | Footer 48 B; 4 KB data blocks | `sstable_writer.dart:24,166`, `sstable_reader.dart:171,371` | `sstable_test.dart` | **C** |
| §08 | Footer fields non-negative and `offset+size <= fileSize` | `sstable_reader.dart:400–440` | `sstable_hostile_parsing_test.dart` | **C** |
| §08 | Index `keyLen`, block `shared`/`unsharedLen`/`valueLen` bounds-checked pre-alloc | `sstable_reader.dart:474–540` | `sstable_hostile_parsing_test.dart` | **C** |
| §08 | Varint with bit 63 set rejected as `FormatException` | `varint.dart` | `varint_test.dart`, hostile corpus | **C** |
| §08 | All structural failures surface as `CorruptedSstableException` | `sstable_reader.dart` open/`_readBlock` | `sstable_hostile_parsing_test.dart` | **C** |
| §08 | Rejected peer file's HWM still advances (quarantine, not re-poison) | `sync_engine.dart:570–624` | `sync_engine_native_adapter_test.dart` | **C** |
| §08 | 3 filename formats; `.local` infix parsed before splitting on `-` | `sstable_info.dart` | `local_only_namespace_test.dart` | **C** |
| §08 | Device ID in platform secure storage; **must not** be in the database | `device_id.dart:21,37` — stored in `$meta`; secure storage deferred | — | **D/X** (SC-5) |
| §08 | TableCache LRU, default 256, evict-before-delete/rename | `table_cache.dart`, `kv_store.dart:519` | `table_cache_test.dart`, `table_cache_integration_test.dart` | **C** |
| §07 | WAL never synced to cloud | `sync_engine.dart` push list | `sync_engine_test.dart` | **C** |
| §07 | `append`/`appendBatch` `syncDir` once per newly-active file | `wal_writer.dart:96–97,147–148,185` | `wal_test.dart:174` (fault-injected) | **C** |
| §07 | Batch = one WAL frame, one fsync; no partial batch observable | `wal_writer.dart` `appendBatch` | `writebatch_atomicity_test.dart` | **C** |
| §07 | Rotation writes no boundary marker; replay not truncated at flush boundary | `wal_reader.dart`, `crash_recovery.dart` | `crash_recovery_test.dart` | **C** |
| §18 | All operations on the calling isolate; vault isolate touches no KvStore | `vault_indexing_isolate.dart` | `vault_indexing_isolate_test.dart` | **C** |
| §18 | `kWorkTimeout` 30 s, `kShutdownDrainTimeout` 5 s | `vault_indexing_isolate.dart:240,249` | `kmdb_database_close_isolate_death_test.dart` | **C** |
| §18 | Memtable flush strictly **before** isolate shutdown in `close()` | `kmdb_database.dart:1028,1041` | `kmdb_database_close_isolate_death_test.dart` | **C** |
| §18 | P99 latency targets (11 rows) | — | **no CI gate** | **U** |
| §14 | `watch()` debounced at 50 ms | `kmdb_query.dart:282` | `kmdb_query_test.dart` | **C** |
| §15 | Session cache 2,000 desktop / 256 mobile+web | `cache_tier.dart:63–64` | `session_cache_test.dart` | **C** |
| §15 | Size configurable via `KvStoreConfig.sessionCacheMaxObjects` | **field does not exist** | — | **X** (SC-3) |
| §15 | Materialised view cache persists scan results in `$cache`; *Required* on mobile/web | **no read or write of `$cache` anywhere** | — | **X** (SC-3) |
| §15 | Generation counters `gen:{namespace}` incremented per WriteBatch | `meta_store.dart`, `kv_store_impl.dart` | `cache_layer_test.dart` | **C** |
| §09 | Bloom filter 10 bits/key, ~0.8% FPR | `bloom_filter.dart:26,54` | `bloom_filter_test.dart` | **C** |

### 11.3 Observations on the `0.09` reconciliation

§4 asked specifically whether the `0.09` pass resolved drift by weakening the
spec where the *code* was wrong. **I found no instance of that.** The two
places where a claim looks carved out — §07's retired-WAL deletion note and
§31's gaps 10 and 11 — both argue their case explicitly, name the QA pass that
found them, and state why the code is acceptable as-is. That is the honest
pattern, not the failure mode.

The drift W1 did find has the opposite shape: it is in sections the `0.09` pass
evidently did **not** reach. §15 has not been substantively touched since it was
written, §08's naming appendix carries a Phase-8-era claim, and §31's reference
tables were not re-derived from code when the surrounding prose was. A
reconciliation pass that reads for *narrative* coherence will not catch a wrong
`info` string or a config field that does not exist — those need mechanical
checking, which is the SC-4/SC-3 pattern noted in §11.1.

One structural note. §31 is now 951 lines, much of it a changelog of resolved
gaps written in the past tense ("previously… **Resolved** by…"). That form is
valuable as history and actively hostile as a specification: SC-2 exists
precisely because a reader must hold both the superseded and current behaviour
in mind to work out which is which, and the superseded one is stated first. Once
`0.1.0` ships, the resolved-gap narratives belong in the roadmap's completed
records, with §31 stating only what is true today.
