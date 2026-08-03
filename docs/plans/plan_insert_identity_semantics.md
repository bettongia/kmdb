# Key-presence-driven upsert + versioning (SC-16)

**Status**: **Open** (decision recorded — key-presence-driven upsert; Q1–Q4 in
the Decision section remain for investigation before `Investigated`)

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

### The genuine design questions (for the reviewer / investigation)

- **Q1 — which method carries the unified upsert, and what happens to `insert`?**
  Recommended shape: `put` becomes the canonical key-presence-driven upsert
  (mint when keyless); `insert` is either removed or narrowed to strict-create
  that rejects a keyed value; `replace` unchanged. Confirm against how callers
  and the CLI use these today.
- **Q2 — `keyOf` on a keyless value.** `RawDocumentCodec.keyOf` *throws* when
  `_id` is absent ([raw_document_codec.dart:44-53](../../packages/kmdb/lib/src/query/raw_document_codec.dart#L44-L53));
  a typed `KmdbCodec.keyOf` may always return a key. The upsert must reliably
  distinguish "has a key" from "no key" for **both** codec kinds — decide the
  detection contract (e.g. a nullable `tryKeyOf`, or catch the `StateError`).
- **Q3 — `DocumentAlreadyExistsException`'s fate.** Under upsert semantics a
  key-present write is an update, not a conflict, so the exception has no caller.
  Remove it (CLAUDE.md: no dead code) unless a strict-`insert` (Q1) keeps it
  reachable.
- **Q4 — versioning correctness across the branches.** Verify the version-chain
  behaviour on each path: keyless insert starts a chain; keyed update appends to
  the existing chain (via `oldDoc`); and confirm no path can fork a new chain for
  an existing logical document. Fault-injection/versioning tests per §26.

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

See **Q1–Q4** in the Decision section — which method carries the upsert and
`insert`'s fate (Q1); keyless-value detection across codec kinds (Q2);
`DocumentAlreadyExistsException` removal (Q3); versioning correctness on every
branch (Q4). All to be resolved by the reviewer/investigation before
`Investigated`.

## Implementation plan

_(to be completed once Q1/Q2 are resolved to `Investigated`.)_

## Summary

_(to be written on completion.)_
