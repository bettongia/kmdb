# Fix M2: non-ASCII namespace names corrupt keys (use real UTF-8)

**Status**: Investigated

**PR link**: {pending}

**Implementation model:** Sonnet — mechanical and backward-compatible; verify all
three namespace-encoding paths are unified.

**Sequencing**: Independent of the other fixes. Backward-compatible for every
database that currently works (ASCII namespaces are byte-identical under the fix),
so it can land at any time.

## Problem statement

Namespaces (derived from user-supplied collection names) are encoded to bytes
with `String.codeUnits`, not UTF-8. `KeyCodec._toUtf8`
([key_codec.dart:213](../packages/kmdb/lib/src/engine/util/key_codec.dart#L213))
even says so: *"ASCII-safe; full UTF-8 for Phase 8"* — but the project is at Phase
10. `codeUnits` yields UTF-16 code units; when packed into the single-byte
namespace field they are **truncated to their low 8 bits**, so any character above
U+00FF (e.g. CJK, many emoji, and astral-plane characters via surrogate pairs) is
silently corrupted. The decode side (`String.fromCharCodes`) cannot reconstruct
the original, and the 255-byte length guard is computed against the wrong length.

Result: a collection whose name contains non-Latin characters produces a
corrupted, ambiguous namespace prefix — writes and reads can mismatch, and data
can become unreachable. Given Bettongia's explicit internationalisation focus,
this is a latent data-integrity bug for non-English users.

## Investigation

### All the encoding/decoding sites (they must agree)

The namespace is turned into bytes in **three** independent code paths that must
produce identical bytes or scans silently miss:

1. **Internal key** — `KeyCodec.encodeNamespace`/`encodeInternalKey` via
   `_toUtf8` ([key_codec.dart:134](../packages/kmdb/lib/src/engine/util/key_codec.dart#L134),
   [L152](../packages/kmdb/lib/src/engine/util/key_codec.dart#L152)); decoded by
   `decodeNamespace` ([key_codec.dart:186](../packages/kmdb/lib/src/engine/util/key_codec.dart#L186)).
2. **WAL record** — `WalRecord.encode` via `_toUtf8`
   ([wal_record.dart:254](../packages/kmdb/lib/src/engine/wal/wal_record.dart#L254));
   decoded at [wal_record.dart:217](../packages/kmdb/lib/src/engine/wal/wal_record.dart#L217).
3. **Scan prefixes** — `LsmEngine._buildKeyPrefix` and `_buildNamespacePrefix`
   call `namespace.codeUnits` **directly**
   ([lsm_engine.dart:1051](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L1051),
   [L1061](../packages/kmdb/lib/src/engine/kvstore/lsm_engine.dart#L1061)) — a
   *separate* encoding path from the codec. Fixing only `_toUtf8` would leave
   these inconsistent, so non-ASCII scans would fail to match the keys.

The fix must route **all three** through one shared UTF-8 helper.

### Out of scope (ASCII-only, safe today)

`$meta` symbolic names (`gen:`, `dirty`, `device_id`, …) hashed by
`MetaStore._nameToKey` ([meta_store.dart:230](../packages/kmdb/lib/src/engine/kvstore/meta_store.dart#L230)),
the device ID (8 hex chars), `CURRENT`/manifest filenames, and the `DEVICE_ID`
file are all ASCII by construction. They are unaffected by the bug; converting
them to UTF-8 is a harmless consistency nicety, not required.

### User keys are unaffected

Document keys are 32-char UUIDv7 hex (ASCII), validated as such
([kv_store_impl.dart:425](../packages/kmdb/lib/src/engine/kvstore/kv_store_impl.dart#L425)).
Only the **namespace** field carries arbitrary user text, so the fix is scoped to
namespaces.

### Backward compatibility (clean)

For any ASCII namespace, `utf8.encode` produces **byte-identical** output to
`codeUnits`, so every currently-working database is unchanged — no migration,
no format bump. Non-ASCII namespaces are *currently corrupted* (no valid data
exists in that state), so changing their encoding fixes them without a migration
concern.

### Unicode normalisation

Two visually identical names in different normalisation forms (e.g. NFC vs NFD
"é") encode to different UTF-8 bytes and would resolve to different namespaces —
a subtle "my collection disappeared" bug. Normalising namespaces to **NFC** at the
public boundary makes lookups robust. This is the one genuinely new design choice
(D3); Dart's `dart:core` does not include a normaliser, so it would need
`package:unorm_dart` or equivalent — weigh the dependency.

### Files to change

| File | Change |
|------|--------|
| `lib/src/engine/util/key_codec.dart` | `_toUtf8` → `utf8.encode`; `decodeNamespace` → `utf8.decode`; length guard on UTF-8 byte length with a clear error |
| `lib/src/engine/wal/wal_record.dart` | `_toUtf8` → `utf8.encode`; namespace decode → `utf8.decode` |
| `lib/src/engine/kvstore/lsm_engine.dart` | `_buildKeyPrefix`/`_buildNamespacePrefix` use the shared UTF-8 helper, not `codeUnits` |
| `lib/src/engine/kvstore/kv_store_impl.dart` (or `KmdbDatabase`) | (D3) NFC-normalise namespaces at the public boundary |
| `docs/spec/04_keys.md`, `06_storage_engine.md`, `11_kv_store.md` | Document UTF-8 namespace encoding, the 255-byte limit semantics, and normalisation |

## Decisions (recommended answers — confirm before implementation)

- [ ] **D1 — Use real UTF-8 everywhere.** Recommended: replace all three
  namespace code paths with one shared `utf8.encode`/`utf8.decode` helper.
- [ ] **D2 — Single encoding helper.** Recommended: one helper used by the codec,
  the WAL record, and the engine prefix builders, so the three can never diverge
  again.
- [ ] **D3 — NFC normalisation of namespaces.** Recommended: **yes**, normalise at
  the public boundary; accept a small normalisation dependency. (If declined,
  document that callers must supply already-normalised names.)
- [ ] **D4 — Length limit.** Recommended: enforce the 255-byte limit on the
  **UTF-8 byte length** (the field is length-prefixed with one byte) and throw a
  clear `ArgumentError` naming the namespace and its byte length.

## Implementation plan

### Step 1 — Shared UTF-8 helper + codec
- [ ] Add one `namespaceToBytes`/`bytesToNamespace` helper (UTF-8).
- [ ] `KeyCodec`: route `encodeNamespace`/`encodeInternalKey` and
      `decodeNamespace` through it; enforce the 255-byte limit on UTF-8 length.

### Step 2 — WAL + engine prefixes
- [ ] `WalRecord.encode`/decode use the helper.
- [ ] `LsmEngine._buildKeyPrefix`/`_buildNamespacePrefix` use the helper (drop the
      inline `codeUnits`).

### Step 3 — Normalisation (D3)
- [ ] NFC-normalise the namespace at the `KvStoreImpl`/`KmdbDatabase` boundary so
      all downstream encoding sees a canonical form.

### Step 4 — Tests
- [ ] **Round-trip** non-ASCII namespaces (accented Latin, CJK, emoji/astral) at
      every layer: put → get → scan → delete all resolve correctly.
- [ ] **Reactivity / indexes:** `watch()` and a secondary index on a non-ASCII
      namespace behave correctly.
- [ ] **Crash replay:** WAL replay restores entries written under a non-ASCII
      namespace.
- [ ] **ASCII unchanged:** assert `utf8.encode(ns) == codeUnits(ns)` for ASCII so
      existing databases are byte-identical (no migration).
- [ ] **Normalisation:** the same logical name in NFC vs NFD resolves to one
      namespace.
- [ ] **Length limit:** a namespace exceeding 255 UTF-8 bytes throws a clear
      error (and one just under succeeds).

### Step 5 — Documentation
- [ ] Update `docs/spec/04_keys.md` / `06_storage_engine.md` / `11_kv_store.md`:
      namespaces are UTF-8 (NFC-normalised), limited to 255 UTF-8 bytes; note the
      ASCII byte-compatibility (no migration).
- [ ] Remove the stale "full UTF-8 for Phase 8" comments.

### Step 6 — Verify
- [ ] `dart test packages/kmdb` and `cd packages/kmdb_cli && dart test` pass.
- [ ] `make analyze` clean. Consider running the `inclusivity` skill review since
      this is an internationalisation fix.

> No release-checklist (§28) entry needed: fully covered by unit tests in CI.

## Summary

{To be completed during implementation.}
