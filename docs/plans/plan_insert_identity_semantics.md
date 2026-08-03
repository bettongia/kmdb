# `insert()` identity semantics — always-mint vs honour-key (SC-16)

**Status**: **Open**

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

## The decision this plan must make

Is `insert`'s contract **(A) "always create new"** or **(B) "create at the
value's identity, reject a duplicate"**?

- **(A) Always-mint (document the current behaviour, remove the dead exception).**
  `insert` is defined as "add a brand-new document, assigning a fresh key";
  calling it twice with the same value legitimately yields two documents. If this
  is the intent, then `DocumentAlreadyExistsException` and its unreachable check
  are **dead code** to remove (CLAUDE.md: no unreachable code), and §13 must state
  plainly that `insert` ignores any `_id`/`keyOf` on the input and never dedupes.
  `replace()`/`put()` remain the identity-carrying writes. The "silent duplicate"
  is then not a bug but a documentation failure.

- **(B) Honour the key when present (make the exception reachable, kill the
  silent duplicate).** When `value` already carries a key (`keyOf` succeeds),
  `insert` uses it, checks existence, and throws `DocumentAlreadyExistsException`
  if present; only when no key is present does it mint one. This makes
  `rawCollection.insert(previouslyReadDoc)` throw instead of duplicate, matching
  the documented exception and the "identical pipeline layers" claim. Cost: a
  behavioural change to `insert`, new tests, and a decision on the typed-codec
  path (a typed `KmdbCodec.keyOf` may always return a key — does typed `insert`
  then also honour it, changing today's always-mint behaviour for typed
  collections too?).

**Investigation must establish the intended contract** before choosing — check:
`insert`'s original design intent (§13, `plan`s), how `replace`/`put`/`upsert`
divide responsibility, whether any caller relies on always-mint, what the typed
vs raw `keyOf` contract is (does typed `keyOf` throw when `_id` absent, like
`RawDocumentCodec.keyOf` does?), and whether `DocumentAlreadyExistsException` has
any other (reachable) caller. The recommendation is not pre-judged here — that is
the reviewer/investigation's job.

## Scope

- `insert()` behaviour + `DocumentAlreadyExistsException` reachability
  (`kmdb_collection.dart`).
- The raw vs typed `_id`/`keyOf` pipeline asymmetry
  (`raw_document_codec.dart`, the codec contract).
- §13 *Write Methods* doc block: `insert` return type (`Future<T>`), the
  identity semantics chosen, and the "all pipeline layers identically" claim.
- Tests: reproduce the current silent-duplicate (fail-first if fixing per B), and
  lock in whichever contract is chosen; exercise both typed and `rawCollection`.

## Out of scope

The rest of WI-2 (done). Any broader write-API redesign (`upsert`, batch inserts)
beyond settling `insert`'s identity contract.

## Open questions

- [ ] **Q1 — contract A (always-mint) or B (honour-key)?** The core decision
      above; the reviewer/investigation resolves it against the intended design.
- [ ] **Q2 — if B, does the typed path change too?** Does typed `insert` start
      honouring `keyOf`, and is that a breaking behavioural change for existing
      typed callers, or is honour-key scoped to when a key is genuinely present?

## Implementation plan

_(to be completed once Q1/Q2 are resolved to `Investigated`.)_

## Summary

_(to be written on completion.)_
