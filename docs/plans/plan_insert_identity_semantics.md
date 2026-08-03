# Key-presence-driven upsert + versioning (SC-16)

**Status**: **Investigated** (Q1–Q4 resolved against `main`; implementation plan
and test surface below are ready for the `kmdb-plan-implement` agent)

**PR link**: _(none yet)_

> **Provenance.** Spun out of **WI-2** (0.10.01 spec corrections) as a code-fix
> work item, per the maintainer's call: unlike the rest of WI-2, SC-16 is not a
> pure documentation drift — it describes a **behaviour** (`rawCollection.insert`
> silently duplicating) that a spec edit should not simply paper over. WI-2's
> other SC items (SC-2/3/11–15/17/18/19/20) are done and on `main`. Code
> coordinates verified against `main` (HEAD after WI-2, post-`cc843d7`).
> Source finding: `docs/reviews/release-readiness-review-2026-07-18.md`, SC-16.

## Problem statement

`KmdbCollection<T>.insert(T value)`
([kmdb_collection.dart:176-189](../../packages/kmdb/lib/src/query/kmdb_collection.dart#L176-L189))
**always mints a fresh UUIDv7 key** and ignores any key already carried by
`value`:

```dart
Future<T> insert(T value) async {
  final key = keyGenerator.next();                 // fresh key, always
  final existing = await _db.cache.get(namespace, key);
  if (existing != null) {
    throw DocumentAlreadyExistsException(key, namespace); // ~unreachable
  }
  final newValue = codec.withKey(value, key);
  await _writeDocument(key: key, newDoc: codec.encode(newValue), oldDoc: null);
  return newValue;
}
```

Two consequences the 2026-07-18 review reproduced:

1. **`DocumentAlreadyExistsException` is unreachable.** The existence check is
   against a freshly-generated UUIDv7 that (barring astronomical collision) never
   already exists — the doc comment even hedges "rare for UUIDv7". `insert` never
   consults `codec.keyOf(value)`, so a caller-supplied key is never honoured and
   the exception the doc advertises can't fire.

2. **`rawCollection.insert(previouslyReadDoc)` silently duplicates.** A document
   read back from a collection carries its `_id`; passing it to `insert` mints a
   *new* key and writes a second copy, rather than detecting the existing key and
   throwing. `RawDocumentCodec.encode` strips `_id` before the schema validator
   sees it
   ([raw_document_codec.dart:24-25](../../packages/kmdb/lib/src/query/raw_document_codec.dart#L24-L25)),
   so §13's claim that `rawCollection` "runs all write pipeline layers
   identically" is false for `_id` specifically.

There is also a **pure documentation drift** riding along (SC-16's doc half):
§13's *Write Methods* block declares `insert` as `Future<void>`; it is actually
`Future<T>` (returns the stored document with its assigned key). That correction
belongs with whichever behaviour this plan settles on, so §13 is edited once.

## Decision (maintainer, 2026-08-03)

**The desired behaviour is upsert, driven by key presence: if the write's value
carries a key it is an *update*; if it carries no key it is an *insert* (mint a
fresh UUIDv7).** And **versioning must be respected** — every write, insert or
update, extends the *logical* document's `$ver:` history correctly; a keyed value
must never start a fresh version chain under a new key (which is exactly the
damage the SC-16 silent-duplicate does today).

This reframes SC-16 from "fix `insert`" to "make the write API key-presence-
driven." The current surface (`kmdb_collection.dart`) already has most of the
pieces — the work is to unify them cleanly:

| method | today | role under the decision |
| :--- | :--- | :--- |
| `put(value)` (215) | upsert, but **requires** `keyOf(value)` to yield a key; passes the existing doc as `oldDoc` so versioning appends | the natural home for the unified upsert — extend it to **mint a fresh key when the value carries none**, so key-present → update, key-absent → insert |
| `insert(value)` (176) | always mints, ignores `keyOf` → silent duplicate on a keyed value; `DocumentAlreadyExistsException` unreachable | resolve: either remove it (subsumed by the keyless `put` path), or keep it strictly as "always create new" but make it **reject a value that already carries a key** so it can never silently duplicate |
| `replace(value)` (197) | update-only, throws `DocumentNotFoundException` if absent | keep as the strict "update, error if missing" write |

### Resolved decisions (reviewer, 2026-08-03)

All four questions are resolved against `main` (`kmdb_collection.dart`,
`raw_document_codec.dart`, `kmdb_codec.dart`, `version_manager.dart`,
`exceptions.dart`, plus every in-repo caller). Verified findings and the
concrete surface follow.

#### Q1 — surface: `put` upserts (mints when keyless); `insert` becomes strict-create; `replace` unchanged — **RESOLVED**

**Decision: keep all three methods; give each a single, sharp role.**

| method | new contract |
| :--- | :--- |
| `put(T value)` → **`Future<T>`** | Canonical key-presence upsert. Keyless value → **mint** a fresh UUIDv7 (`keyGenerator.next()` + `codec.withKey`), write with `oldDoc: null`. Keyed value → read the existing doc and write with `oldDoc` = existing-or-`null`. **Returns the stored document with its key** (needed so callers recover a minted key). |
| `insert(T value)` → `Future<T>` | **Strict create.** Keyless value → mint + write (as today). Keyed value → **throw `ArgumentError`** (`'insert requires a value with no key; use put() to upsert an existing document'`). This is the guardrail that turns the SC-16 silent-duplicate into a loud failure. Still returns the stored document. |
| `replace(T value)` → `Future<void>` | Unchanged update-only semantics. Keyless value → throw `ArgumentError` (was a `StateError` bubbled up from `keyOf`). |
| `putMany` / `update` | Unchanged; both delegate to `put` and discard its new return value. |

**Why keep `insert` rather than remove it (the maintainer's other option):**

1. **Blast radius.** `insert` has **223 call sites across 26 test files** plus 13
   benchmark files and the CLI `insert` command. Removing it forces a
   223-site mechanical migration to `put` with real regression risk; nearly all
   those calls are keyless "create new" and keep working verbatim under
   strict-`insert`.
2. **`insert`-as-strict-create is genuinely useful and sync-safe.** Its check is
   on the *input value's* key presence — a purely local, synchronous test — **not**
   a storage-existence check. That is exactly the guardrail that catches the
   reported bug (`rawCollection.insert(readBackDoc)` now throws instead of
   forking a duplicate). Keeping it costs one branch and pays for itself.

The distinction is clean: **`insert` = "assert this is new, fail loudly if it
carries a key"; `put` = "upsert".** Both mint on a keyless value.

**Caller impact (verified):**
- CLI `insert_command.dart:145` (`col.insert(doc)`): keyless user JSON is
  unaffected. To preserve the command's documented "the `_id` is silently
  stripped / a new key is assigned" behaviour, `insert_command` must **strip
  `_id` from each doc before `insert`** so a stray `_id` mints rather than
  throwing. One-line change.
- CLI `update_command.dart:234/244/390` and `kmdb_harness` `device.dart:193`
  (`col.put(...)`): all pass **keyed** maps → update path, unchanged. They
  discard the new `Future<T>` return — fine.
- Benchmarks (`col.insert(benchPayload(i))`, incl. `final first = await
  col.insert(...)`): keyless payloads → mint, return `T` as before. No change
  needed to keep them compiling, but see the audit step in the checklist.

**Breaking-change flags (pre-1.0, acceptable — called out per the task):**
- `KmdbCodec.keyOf` return type `String` → `String?` (see Q2 — covariant-safe
  for existing typed impls).
- `KmdbCollection.put` return type `Future<void>` → `Future<T>` (source-safe at
  every in-repo call site — all discard it).
- `KmdbCollection.insert` now **throws** on a keyed value (was silent mint).
- `KmdbCollection.replace` throws `ArgumentError` (was `StateError`) on a keyless
  value.
- `DocumentAlreadyExistsException` removed (Q3).

#### Q2 — keyless detection: make `keyOf` return `String?`; treat `null` **or** empty as keyless — **RESOLVED**

**Decision: change the contract method `KmdbCodec.keyOf` from `String` to
`String?`, and centralise detection in `KmdbCollection` as "`null` or empty
string ⇒ keyless".** No new method, no `StateError`-catching heuristic.

Rationale, verified against the code:
- **Covariant-safe.** All 26 in-repo typed codecs declare `@override String
  keyOf(...)`. `String` is a subtype of `String?`, so those overrides remain
  **valid without edits** — only codecs that must express "keyless" change.
- **`RawDocumentCodec.keyOf` stops throwing.** It becomes
  `String? keyOf(m) => m['_id'] as String?` (returns `null` when `_id` is absent
  or not a `String`). This removes the raw-vs-typed asymmetry the plan calls out
  and is the single line that lets a keyless raw doc reach the mint path.
- **Empty-string is the typed "keyless" sentinel, already in use.** The existing
  suite constructs new typed objects as `_Task(id: '')`
  (`kmdb_collection_test.dart:163`) and `_TaskCodec.keyOf` returns `value.id`
  (i.e. `''`). Treating `''` as keyless means **no typed codec needs editing** and
  the established convention keeps working. `''` is never a valid 32-char hex
  UUIDv7, so this can never mask a real key.
- **Why not catch `StateError`.** Catching a bare `StateError` from `keyOf` to
  mean "keyless" is exactly the fragile heuristic that reintroduces silent
  duplication — an unrelated `StateError` inside a codec would be misread as
  "keyless" and mint a duplicate. Rejected.

Concrete mechanism — one private helper in `KmdbCollection`:

```dart
/// Returns the value's key, or null if it carries none (keyless ⇒ mint).
String? _keyOrNull(T value) {
  final k = codec.keyOf(value);
  return (k == null || k.isEmpty) ? null : k;
}
```

`put`, `insert`, and `replace` all route their key detection through
`_keyOrNull`.

#### Q3 — `DocumentAlreadyExistsException` is removed — **RESOLVED**

**Decision: remove it entirely.** Confirmed it has **no reachable production
caller** — the only references are its declaration, the `kmdb.dart:75` export,
and two tests (`exceptions_test.dart`, `kmdb_collection_test.dart:168-189`). The
sole thrower is the unreachable existence check inside today's `insert`.

Under the resolved surface a key-present write is an update (`put`) or a loud
`ArgumentError` (`insert`) — never an existence conflict. Recorded architectural
rationale for **not** replacing it with any create-fail-if-exists exception: in a
synced database, "does this key already exist?" is **not globally answerable** —
a concurrent device may hold the key under LWW, so a local existence check would
be a lie. KMDB deliberately does not offer create-fail-if-exists.

Remove: the class (`exceptions.dart:58-73`), the `kmdb.dart` export line, the
`exceptions_test.dart` group, and the `kmdb_collection_test.dart:168-189` test
(replaced by the "insert rejects a keyed value" test in the test surface below).

#### Q4 — versioning correctness: no path can fork a chain — **RESOLVED (no `_writeDocument`/augmentor change needed)**

Traced `_writeDocument` → `VersionWriteAugmentor.interceptWrite` (both key the
`$ver:{ns}` entry by the **same `docKey`** passed by the write method, in the
**same `WriteBatch`** — one WAL frame per H2). The chain outcome is fully
determined by *which key the write method uses*:

- **`put` keyless / `insert` keyless →** mint `K`, `oldDoc: null` → a `$ver:{ns}`
  entry is written under fresh `K` → **starts a new chain.** Correct (new logical
  doc).
- **`put` keyed, existing `K` →** `oldDoc` = existing → `$ver:{ns}` entry under
  `K` → **appends to the existing chain.** Correct.
- **`put` keyed, absent `K` →** `oldDoc: null`, write at `K` → **starts a chain at
  `K`.** Correct (create-at-supplied-key).
- **The SC-16 fork is now impossible.** The only path that forked a chain was
  `insert` minting `K' ≠ K` for a value already carrying `K` (leaving `K`'s chain
  un-extended and orphaning a duplicate under `K'`). That path is now an
  `ArgumentError`, and `put` of the same value uses `K` for **both** the main and
  `$ver` writes.

Because the main-namespace put and its `$ver:` entry share one atomic
`WriteBatch`/WAL frame, a crash mid-write cannot fork the chain either — it
either fully applies (chain +1) or not (chain unchanged). This is exercised by
the fault-injection test below (per CLAUDE.md — not the golden path).

## Scope

- The write API's key-presence-driven upsert (`put`/`insert`/`replace` in
  `kmdb_collection.dart`) and `DocumentAlreadyExistsException`'s fate.
- The raw vs typed `_id`/`keyOf` pipeline asymmetry and the keyless-detection
  contract (`raw_document_codec.dart`, the `KmdbCodec` contract).
- **Versioning correctness** (§26): every branch extends the correct `$ver:`
  chain; no path forks a new chain for an existing logical document.
- §13 *Write Methods* doc block: `insert` return type (`Future<T>`), the unified
  upsert semantics, and the false "all pipeline layers identically" claim.
- Tests: reproduce the current silent-duplicate + orphaned-version-chain
  (fail-first), lock in the upsert contract, exercise both typed and
  `rawCollection`, and cover the versioning behaviour on each branch.

## Out of scope

The rest of WI-2 (done). Broader write-API redesign beyond settling the upsert
contract (e.g. bulk/transactional insert semantics), `putMany` atomicity.

## Open questions

- [x] **Q1** — surface: `put` = key-presence upsert returning `T`; `insert` =
      strict-create (throws on a keyed value); `replace` unchanged. `insert`
      kept (not removed) — see rationale in the Decision section.
- [x] **Q2** — `KmdbCodec.keyOf` → `String?`; `KmdbCollection` treats `null` or
      empty string as keyless.
- [x] **Q3** — `DocumentAlreadyExistsException` removed; no replacement.
- [x] **Q4** — no `_writeDocument`/augmentor change needed; fork is impossible
      once `insert` rejects keyed values and `put` reuses the carried key.

No questions remain for the maintainer.

## Implementation plan

Order matters: land the contract change and the write-method behaviour first,
then fix callers surfaced by the failing suite, then docs.

### 1. Codec contract (`kmdb_codec.dart`, `raw_document_codec.dart`)

- [ ] Change `KmdbCodec.keyOf` signature to `String? keyOf(T value)`. Update the
      doc comment: the key may be `null` (or empty) for a not-yet-persisted
      value, which the write methods treat as "mint a new key".
- [ ] `RawDocumentCodec.keyOf` → `String? keyOf(m) => m['_id'] as String?`
      (delete the `StateError` throw). Update its class/method doc comments
      (lines 25, 42-46) to describe the nullable contract.
- [ ] Confirm no typed codec needs editing (covariant `String` return stays
      valid). Only edit a typed codec if it must express keyless via `null`
      (none in-repo — they use `id: ''`).

### 2. Write methods (`kmdb_collection.dart`)

- [ ] Add the private `_keyOrNull(T value)` helper (`null` when `keyOf` is `null`
      or empty).
- [ ] `put`: change return type to `Future<T>`. Detect via `_keyOrNull`; when
      keyless, mint `keyGenerator.next()`, `codec.withKey`, `oldDoc: null`, and
      **return the stamped value**; when keyed, read existing → `oldDoc`, write,
      return `value`.
- [ ] `insert`: keep minting on a keyless value; when `_keyOrNull(value) != null`
      throw `ArgumentError` with the message in the Decision section. Delete the
      unreachable existence check and the `DocumentAlreadyExistsException` throw.
- [ ] `replace`: route through `_keyOrNull`; throw `ArgumentError` (not
      `StateError`) when keyless.
- [ ] `putMany` / `update`: no logic change; they discard `put`'s new return.
- [ ] Update the class-level doc comments (Keys section lines 44-47; the
      `insert`/`put`/`replace` method docs) to the new contracts.

### 3. Exceptions (`exceptions.dart`, `kmdb.dart`)

- [ ] Remove `DocumentAlreadyExistsException` (class + doc).
- [ ] Remove its export from `kmdb.dart:75`.

### 4. Callers

- [ ] CLI `insert_command.dart`: strip `_id` from each doc before `col.insert`
      (preserve the "new key is assigned" behaviour; a stray `_id` must not throw).
      Keep using the returned document for `ctx.writeDocuments`.
- [ ] **Audit every `insert` call site for keyed values.** After steps 1-3, run
      the full suite; any `insert(...)` that passes a value already carrying a key
      now throws `ArgumentError` and will fail. Switch those specific sites to
      `put` (or drop the key). Expect nearly all 223 test sites + 13 benchmarks to
      be keyless and need no change; the failing tests pinpoint the exceptions.
- [ ] Verify `update_command`, `device.dart` (harness), and `putMany` callers
      compile against `put`'s new `Future<T>` return (they discard it).

### 5. Spec & docs (§13, §26)

- [ ] §13 *Write Methods* block (lines 330-341): `Future<T> insert(T value)`
      (strict create — mints on keyless, throws `ArgumentError` on a keyed value;
      remove the `DocumentAlreadyExistsException` comment); `Future<T> put(T
      value)` (key-presence upsert — mints on keyless, updates on keyed, returns
      the stored doc).
- [ ] §13 `KmdbCodec` listing (line 97) and the example (line 175): `String?
      keyOf(...)`.
- [ ] §13 *rawCollection* section (lines 276-285): correct "All write pipeline
      layers run identically" — note that `RawDocumentCodec.encode` strips `_id`
      (so `_id` does **not** flow through validation like other fields) and that a
      keyless raw doc mints a key; keep the example but ensure it reads as an
      insert of a keyless map.
- [ ] §26 (`26_document_versioning.md`): review/annotate which write methods start
      vs append a `$ver:` chain and state the no-fork invariant (keyless
      `insert`/`put` start a chain; keyed `put` appends; `insert` rejects keyed
      values). Edit only if the section currently misstates this.
- [ ] Check the §25 example (`25_collection_schemas.md:46`,
      `contacts.insert(contact)`) reads correctly under strict `insert` (contact
      must be keyless there).

### 6. Tests (`packages/kmdb/test/query/**`, benchmarks unaffected)

**Fail-first regression + invariant locks — not golden-path only.**

- [ ] **SC-16 raw reproduction (the reported bug).** `put` a keyless raw doc → key
      `K`; `get(K)` returns a map carrying `_id: K`. Assert
      `insert(readBackDoc)` now `throwsA(isA<ArgumentError>())`; assert the
      namespace still holds exactly **one** doc and `$ver:{ns}` holds exactly one
      key (`K`) with one entry. (Fails on current `main`, where `insert` succeeds,
      the namespace holds two docs, and a second orphaned `$ver` chain appears.)
- [ ] **Correct path.** `put(readBackDoc)` updates `K` in place → one doc, `$ver:K`
      length 2, and **no second key** exists in `$ver:{ns}` (orphan-chain lock).
- [ ] **Typed equivalent.** Both of the above for a typed collection: a typed
      model carrying a real id → `insert` throws, `put` appends; `_Task(id: '')` →
      `insert`/`put` mint.
- [ ] **`put` keyless mint.** `put` of a keyless value returns a document whose
      `_id` is a valid UUIDv7, is retrievable via `get`, and has a `$ver` chain of
      length 1.
- [ ] **`put` keyed-absent.** `put` of a value carrying a fresh, not-yet-present
      UUIDv7 creates it at that key with a chain of length 1.
- [ ] **`replace` keyless** → `throwsA(isA<ArgumentError>())`.
- [ ] **Codec unit tests** (`raw_collection_test.dart:67-74`): replace the two
      `keyOf throws StateError` tests with `keyOf returns null` (absent `_id`, and
      non-`String` `_id`).
- [ ] **`_keyOrNull` detection**: empty-string typed id and absent `_id` both take
      the mint path; a valid key takes the update path.
- [ ] **Remove** the `DocumentAlreadyExistsException` group in `exceptions_test.dart`
      and the `kmdb_collection_test.dart:168-189` test; migrate the
      "uses collection keyGenerator" test (line 152-166) to the surviving surface.
- [ ] **N-put orphan-chain lock.** Round-trip the same logical doc through
      read→`put` N times; assert exactly one key in the namespace **and** exactly
      one key in `$ver:{ns}` with N entries (no forked chain).
- [ ] **Fault injection (CLAUDE.md, not golden-path).** Using `FaultyStorageAdapter`,
      crash mid-`put` during the second write of an existing doc; reopen and assert
      atomicity — the doc/`$ver` pair either both advanced (one doc, chain 2) or
      neither did (one doc, chain 1), never two docs / a forked chain. This locks
      the single-WAL-frame guarantee.
- [ ] **CLI regression** (`kmdb_cli/test`): `insert` of a `--value` containing an
      `_id` still writes a **new** document (key stripped) and does not throw; add
      or extend a test to cover it.

_No release-checklist (`docs/spec/28_release_checklist.md`) entry is required:
the fork/atomicity scenarios all run in-suite via `FaultyStorageAdapter` and
`MemoryStorageAdapter`. RC-6 already covers multi-device tombstone
non-resurrection; SC-16 is a single-device local-mint bug fully covered here._

### 7. Final gate

- [ ] `make coverage` — >95% on changed files (`kmdb_collection.dart`,
      `raw_document_codec.dart`, `kmdb_codec.dart`, `exceptions.dart`).
- [ ] `cd packages/kmdb_cli && dart test` (pre_commit's test step is `kmdb`-only).
- [ ] `kmdb-qa` sign-off, then `make pre_commit`.
- [ ] Licence headers unchanged on edited files (no new files expected).

## Reviewer assessment (2026-08-03)

**Problem statement:** Sound and worth solving. The silent-duplicate + orphaned
`$ver:` chain is a real data-integrity defect, correctly diagnosed. The riding
doc drift (§13 `insert` return type; the false "all layers identically" claim)
is genuine and verified.

**Solution:** The key-presence upsert is the right model and fits the existing
augmentor/`_writeDocument` machinery with **no storage-engine change** — the fix
is entirely at the query-layer boundary plus a nullable-key contract tweak. The
critical realisation that makes this safe is that `keyOf → String?` is
**covariant-compatible** with all 26 existing typed codecs, so the blast radius
collapses to `RawDocumentCodec` + two call sites + the deleted exception. Keeping
`insert` as a strict, *input-only* create guard (rather than a sync-unsafe
existence check) both preserves 223 call sites and directly converts the reported
bug into a loud failure.

**Risk & edge cases covered:** version-chain fork (the real damage), crash
atomicity of the doc/`$ver` pair, empty-string vs null keyless detection, and the
CLI `_id`-stripping behaviour. The one migration hazard — an `insert` call site
that passes a keyed value — is discoverable mechanically by running the suite
after the contract change, and is called out as an explicit audit step.

**Implementation readiness:** Named files, methods, signatures, the detection
helper, and a fail-first + fault-injection test surface are all specified. A
Sonnet implementer can execute this without further design decisions.

## Summary

_(to be written on completion.)_
