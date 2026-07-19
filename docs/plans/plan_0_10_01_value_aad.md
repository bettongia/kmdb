# Bind encrypted values to their context with AES-GCM associated data (E-2)

**Status**: Open

**PR link**: _(none yet)_

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
- [ ] **What exactly goes into the AAD for each value class?** Proposed below;
      needs confirmation before implementation.
- [ ] **Does the AAD need a version/domain-separation prefix** so a future
      change to its composition cannot be confused with the current one?
      (Recommended: yes — a single leading byte.)
- [ ] **`$ver:` entries** — should a version entry's AAD bind the HLC, making
      promotion re-encrypt, or bind only the logical key so a promoted version
      can be moved without re-encryption? This is a real trade-off between
      replay resistance and promotion cost.

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

**51 call sites in `lib/`** (more including tests). The important ones are in
the collection layer — `kmdb_collection.dart:115`, `:203`, `:219` — where the
namespace and document key are already in scope, so threading is mechanical
rather than architectural.

### Value classes needing an AAD definition

Not every value has a natural document key. Each of these needs an explicit
decision, and the plan should not let an implementer improvise:

| Class | Natural context | Proposed AAD |
| :--- | :--- | :--- |
| Collection documents | namespace + document key | `ns \|\| key \|\| recordType` |
| `$meta` raw-by-name | a name, no key | `ValueContext.meta(name)` |
| `$ver:` history entries | key + HLC | see open question above |
| Vault blobs | the SHA-256 address | `ValueContext.vaultBlob(sha256)` |
| `$$fts:` / `$$vec:` | local-only, never synced | still bind; cost is nil |

### Interaction with the encryption envelope

`EncryptionEnvelope` (added by the 0.08 reconciliation) wraps scalar/opaque
values that bypass `ValueCodec`. Those call sites need the same treatment —
this plan must audit them, not just `ValueCodec`.

## Implementation plan

### Phase 1 — Define the context type

- [ ] `ValueContext` with named constructors for each class in the table above.
- [ ] A canonical, unambiguous byte encoding — length-prefixed fields, not
      concatenation, so `("ab", "c")` and `("a", "bc")` cannot collide.
- [ ] A leading version/domain byte.
- [ ] Doc comments explaining *why* each field is bound.

### Phase 2 — Thread it through

- [ ] Add a **required** `ValueContext` parameter to `ValueCodec.encode`/`decode`.
- [ ] Fix every resulting compile error — the point of making it required.
- [ ] Same for `EncryptionEnvelope` call sites.
- [ ] Pass the AAD to `AesGcm.encrypt`/`decrypt` (`package:cryptography` already
      supports it).

### Phase 3 — Format version

- [ ] Bump the format version so an older database **fails to open with a clear
      diagnostic** rather than decoding garbage. No migration is written.

### Phase 4 — Tests

- [ ] **Relocation:** encrypt at key A, place the ciphertext at key B, assert
      authentication failure. This is the test that proves the fix.
- [ ] **Cross-namespace transplant:** same, across namespaces.
- [ ] **Rollback:** replace a value with an older ciphertext for the same key,
      assert detection where the AAD binds enough to detect it — and document
      honestly where it does not.
- [ ] Round-trip tests for every `ValueContext` constructor.
- [ ] Old-format database fails to open with the expected diagnostic.

### Phase 5 — Spec

- [ ] Update §31 (encryption) with the AAD composition and its rationale.
- [ ] Update §05 (value encoding) for the format version bump.
- [ ] Note in §31 what AAD does **not** protect against (a peer that legitimately
      holds the DEK).

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off. Do not open a PR until
      sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

## Summary

_To be completed when the work is done._
