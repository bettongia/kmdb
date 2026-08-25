# Make `package:kmdb/kmdb.dart` compile for web (0.1.0 release blocker)

**Status**: Questions

**PR link**: _(none yet)_

> **Provenance.** Release-blocker #1 from the pre-0.1.0 `bettongia:release-ninja`
> audit (2026-08-26, HEAD `e7dec55`), verified by direct compile, and scoped by
> `kmdb-architect`. It sits inside **WI-9 Phase C** (the pre-tag readiness gate,
> `docs/roadmap/0_10_01.md`) — the tag cannot be cut until the public API
> compiles for a platform the package advertises. Bundles the tightly-coupled
> release-ninja findings **#2** (web storage engine has no executed CI) and
> **#5** (README ↔ §19 web contradiction), because all three are "make web real
> and true." Release-ninja **#3** (Flutter native build in CI) and **#4**
> (publish dry-run gate) are a separate CI-hardening slice, out of scope here.

## Problem statement

`package:kmdb/kmdb.dart` — the public API barrel, named in `README.md:80` as
"the primary API" — **does not compile to web**. Verified on HEAD `e7dec55`: a
one-line `import 'package:kmdb/kmdb.dart'; void main() {}` fails under both
`dart compile js` and `dart compile wasm` with `Dart library 'dart:ffi' is not
available on this platform`.

Yet `README.md:93` (the pub.dev landing page) and `docs/spec/19_platform.md`
advertise web support (Core LSM ✓, Zstd ✓ WASM, Sync ✓), with only **semantic
search** excluded on web. Any consumer who follows those claims and adds the
import to a web target gets a hard compile failure on the first build. **Web is
a confirmed 0.1.0 target** (maintainer decision, 2026-08-26), so the fix is to
make the barrel web-compilable — not to drop the web claims.

CI never caught this because the `test-web` lane (`make cicd_web`) compiles only
three isolated low-level test files, **none of which import `kmdb.dart` or
`KmdbDatabase`** — nothing in CI ever asks the compiler to build the public API
for web.

## Investigation

Scoped by `kmdb-architect` against HEAD `e7dec55`. There are **exactly two**
unconditional native reaches from the web-reachable import graph; the full graph
was traced and there is no hidden third blocker.

### Root cause

**Blocker 1 — `dart:ffi` via `betto_inferencing`.** Five lib files import
`package:betto_inferencing/betto_inferencing.dart`:
`lib/kmdb.dart:116` (re-export of `EmbeddingModel, EmbeddingKind`),
`lib/src/query/kmdb_database.dart:36`,
`lib/src/search/semantic/vec_manager.dart:27`,
`lib/src/vault/search/vault_searcher.dart:26` (`show EmbeddingKind`), and
`lib/src/vault/search/vault_search_manager.dart:41`.

**Decisive fact:** `betto_inferencing.dart` itself imports no `dart:ffi`. The
break is its barrel's `export 'package:betto_onnxrt/betto_onnxrt.dart'`, and
`betto_onnxrt` imports `dart:ffi` unconditionally. Because a Dart `export`
compiles the exported library, **even `show EmbeddingKind` drags
`betto_onnxrt`→`dart:ffi` into the web compile** — the `vault_searcher.dart:108`
comment calling the enum import "lightweight" is right about coupling but wrong
about web compilation.

**Crucial enabling fact:** the types kmdb exposes are already web-safe.
`EmbeddingModel` is an `abstract interface class` and `EmbeddingKind` a plain
enum, both defined in `betto_inferencing`'s `lib/src/embedding_model.dart`,
which imports **only `dart:typed_data`** — no ffi, no onnxrt. The concrete
FFI-bearing `OnnxEmbeddingModel` merely *implements* that interface elsewhere.
So the type surface in kmdb's public signatures is pure Dart; only the package
*barrel's* `betto_onnxrt` re-export poisons the web compile. This makes a
kmdb-owned conditional-import seam viable **without** first abstracting behind a
new kmdb interface.

**Blocker 2 — `dart:io` via the native storage adapter.**
`lib/src/engine/platform/storage_adapter_native.dart:15` imports `dart:io` and
reaches the barrel two ways: the export at `kmdb.dart:42-43` and the
unconditional import at `kmdb_database.dart:32` (used at `:1136`,
`resolvedLocalAdapter = localAdapter ?? StorageAdapterNative()`). Everything
else touching `dart:io` is **already gated** and is not a blocker
(`_cache_tier_detect_native.dart` via `cache_tier.dart:16-18`,
`local_directory_adapter.dart` via `kmdb.dart:57-59`,
`local_directory_vault_adapter.dart` via `kmdb.dart:156-158`,
`io_kmdb_config_store.dart` reachable only from the separate `kmdb_config.dart`
library).

### The seam design (recommended)

**Semantic / `EmbeddingModel` seam.** Introduce one kmdb-owned indirection,
`lib/src/search/semantic/embedding_model.dart`, using conditional export:

```dart
export 'embedding_model_stub.dart'
    if (dart.library.io) 'embedding_model_native.dart';
```

- `embedding_model_native.dart` **re-exports** `EmbeddingModel, EmbeddingKind`
  from `package:betto_inferencing` — preserving *type identity* so a caller
  passing an `OnnxEmbeddingModel` into `open()` still satisfies the signature on
  native. **This re-export (not redeclaration) is the single most important
  correctness constraint of the seam.**
- `embedding_model_stub.dart` redeclares `abstract interface class
  EmbeddingModel` (same members: `embed()`, `dimensions`, `modelId`, `dispose`)
  and `enum EmbeddingKind { document, query }`, pure `dart:typed_data`. Nothing
  constructs it on web (no concrete impl exists), so it only needs to exist as a
  name for signatures — the `web_sync_authenticator_stub.dart` pattern
  (`kmdb.dart:72-74`).

Reroute all five `betto_inferencing` import sites to this indirection, and
replace the barrel re-export at `kmdb.dart:116` with a re-export of the
indirection. `VecManager` compiles on web unchanged once its type import is
rerouted (it depends on `EmbeddingModel` only by interface) and is simply dead
at runtime on web (guarded at `kmdb_database.dart:505`:
`vecIndexes.isNotEmpty && embeddingModel != null`, and no `EmbeddingModel` can
exist on web). `vault_searcher.dart` already type-erases the model to `Object?`
(`:107`) and calls `model.embed(...)` dynamically (`:486`) — only its `show
EmbeddingKind` import needs rerouting.

**`dart:io` / storage-adapter seam.** Mirror the existing
`local_directory_adapter` pattern:
- `kmdb.dart:42-43` → conditional export
  `export 'storage_adapter_native_stub.dart' if (dart.library.io)
  'storage_adapter_native.dart' show StorageAdapterNative;` (a stub must be
  created — none exists).
- `kmdb_database.dart:32` → reroute to the same conditional indirection.
- **Web storage default.** The runtime default is `StorageAdapterNative()`
  (`kmdb_database.dart:1136`), which resolves to a throwing stub on web. Since
  web is supported, add a conditional `default_local_adapter.dart` indirection
  exposing `defaultLocalStorageAdapter()` → `StorageAdapterNative()` on native,
  `StorageAdapterSahPool()` on web (parameterless ctor confirmed at
  `storage_adapter_sahpool.dart:127`, per §19 OPFS/SAHPool). Note
  `storage_adapter_impl.dart` already encodes "web default = sahpool" but is
  **orphaned** relative to `open()` — this wires it in.

### Blast radius

New files (5): `lib/src/search/semantic/embedding_model.dart` (indirection),
`embedding_model_native.dart`, `embedding_model_stub.dart`,
`lib/src/engine/platform/storage_adapter_native_stub.dart`, and (recommended)
`lib/src/engine/platform/default_local_adapter.dart`.

Modified files (5): `lib/kmdb.dart` (`:42-43`, `:116`),
`lib/src/query/kmdb_database.dart` (`:32`, `:36`, `:1136`),
`lib/src/search/semantic/vec_manager.dart` (`:27`),
`lib/src/vault/search/vault_search_manager.dart` (`:41`),
`lib/src/vault/search/vault_searcher.dart` (`:26`).

**Public-API-surface impact (0.1.0 freeze).** The barrel keeps exporting symbols
**named** `EmbeddingModel`/`EmbeddingKind`. On **native** (re-export) these
remain the *identical* `betto_inferencing` types → no consumer break. On **web**
they become kmdb-declared stub types of the same name/shape (source-compatible;
semantic search is unsupported there anyway). `open()`'s `EmbeddingModel?
embeddingModel` param (`:326`), the `EmbeddingModel?` getter (`:1663`), and
`VecManager? get vecManager` (`:1267`) keep their signatures. `StorageAdapterNative`
stays exported (now conditionally; web name resolves to the throwing stub — a
behavioral, not signature, change). **Net: no public signature removed or
renamed.** The reviewer should consciously accept that the web canonical
declaration site of `EmbeddingModel` differs from native (judged non-breaking).

### Spec implications

- **`docs/spec/19_platform.md`** — the matrix (`:169-177`) is essentially correct
  for the target state, but: (a) the `storage_adapter.dart` conditional-export
  **code sample (`:10-13`, `:232-235`) names a file that does not exist** — fix
  it to describe the actual mechanism this plan lands; (b) it marks Lexical/Vault
  `✗ (deferred)` on web (`:174`, `:176`), contradicting §20
  (`20_text_search.md:54-55`: "Lexical search is fully supported on web") — a
  pre-existing §19↔§20 conflict to reconcile (likely lexical ✓ web, semantic ✗
  web).
- **`docs/spec/22_semantic_search.md`** — already states web exclusion (`:50`);
  add that the exclusion is enforced **at compile time** via the kmdb-owned
  `EmbeddingModel` indirection stub, and that using the stub throws
  `UnsupportedError`.
- **`README.md:93` is the wrong artefact in the README↔§19/§5 contradiction.**
  It claims web is "Read-only … Zstd values throw `UnsupportedError` (see §5)",
  but §5 (`05_value_encoding.md:74-75, 120, 186-193`) says the **opposite**
  ("Both native and web platforms compress values with Zstd… native-written can
  be read by web and vice versa"), §19 (`:172`) agrees (Zstd ✓ WASM), and
  `cicd_web` runs a passing web Zstd test. Rewrite `README.md:93` to match
  §19/§5 (full support minus semantic search); its "(see §5)" citation is doubly
  wrong. *(Caveat for implementer: whether web actually **writes** Zstd `0x01`
  vs only reads it is a separate `kmdb-spec-auditor` conformance question — base
  the rewrite on §19/§5 as written, not on README:93.)*

### Invariants / risks / gotchas

- **Type identity on native must be preserved** — re-export, never redeclare, or
  `OnnxEmbeddingModel` stops satisfying kmdb's signatures.
- **Tree-shaking is not a safeguard** — `betto_onnxrt`→`dart:ffi` is a front-end
  *resolution* error (before tree-shaking), so "never called on web" does not
  help; the import must be physically absent from the web graph. This is why
  `show EmbeddingKind` is insufficient and the indirection is required.
- **Make web failure explicit** — `open()` should throw a clear `UnsupportedError`
  if a web caller passes non-empty `vecIndexes` (today the failure is an implicit
  can't-construct-model null path — see `kmdb_database.dart:505`).
- **`$$vec:` namespaces unaffected** — local-only, never synced; web devices
  simply never build them.
- **dart2js vs dart2wasm divergence is live** — `make_cicd.mk:147-153` documents
  that `xxhash.dart`'s 64-bit int literals make **dart2js reject** paths that
  reach them, and the barrel transitively includes the engine (XXH64). So a
  `dart compile js` smoke may fail on xxhash **independently** of the ffi/io
  fixes. See Open Question 2.
- **`lib/test_support.dart` / `lib/kmdb_test_cloud_support.dart`** are separate
  top-level libraries, not imported by the barrel, so they don't affect
  barrel web-compile; the CI smoke must target the barrel specifically.

### CI guard

Add a barrel-compile smoke to `make cicd_web` (`make_cicd.mk:161-166`), already
run by the `test-web` job (`.github/workflows/cicd.yml:263`, Chrome + pinned SDK
in place — no new job needed): compile `import 'package:kmdb/kmdb.dart'; void
main() {}` with `dart compile wasm` (the real regression fence for the ffi/io
seam) and, **subject to Open Question 2**, `dart compile js`. Also wire the
**SAHPool web adapter test** (`test/engine/storage_adapter_sahpool_test.dart`,
`@TestOn('browser')`) into `cicd_web` — today it runs in **no** lane
(release-ninja #2), so §19's "web LSM ✓/Sync ✓" rests on an adapter CI never
executes.

## Open questions

- [ ] **Q1 — Web storage default: SAHPool factory vs. throwing stub.** The
      architect recommends defaulting web to `StorageAdapterSahPool()` via a
      `defaultLocalStorageAdapter()` factory (since web is a supported platform,
      `open()` should work out-of-the-box on web, not throw unless the caller
      supplies an adapter). Alternative: default to a throwing stub and require
      web callers to pass `StorageAdapterSahPool()` explicitly. **Recommendation:
      SAHPool factory.** Reviewer to confirm.
- [ ] **Q2 — Is `dart compile js` a supported 0.1.0 web target, or is wasm the
      sole supported web compiler?** `make_cicd.mk:147-153` shows dart2js already
      rejects xxhash 64-bit int-literal paths, and the barrel reaches XXH64 — so
      the JS target may fail independently of this fix. Either (a) commit to
      wasm-only for web, guard `dart compile wasm` in CI, and state "web =
      WASM" in §19/README; or (b) additionally resolve the xxhash JS reach and
      guard both. **Recommendation: wasm-only** (matches the existing
      `--compiler dart2wasm` posture in `cicd_web`), with §19/README wording to
      match. Reviewer to confirm; this decision changes both the CI guard and the
      platform-matrix wording.

## Implementation plan

_Checklists to be executed by `kmdb-plan-implement` on a dated branch + worktree
once this plan is `Investigated`. Order: land the seam, prove the compile, then
make the docs/CI tell the truth._

**Phase A — the `dart:io` storage-adapter seam (simpler; lands first):**

- [ ] Create `lib/src/engine/platform/storage_adapter_native_stub.dart` — a
      `StorageAdapterNative` stub (no `dart:io`) whose members throw
      `UnsupportedError`, mirroring `web_sync_authenticator_stub.dart`.
- [ ] Create `lib/src/engine/platform/default_local_adapter.dart` — conditional
      `defaultLocalStorageAdapter()` factory (native → `StorageAdapterNative()`,
      web → `StorageAdapterSahPool()`), per Q1.
- [ ] `kmdb.dart:42-43` → conditional export of the native adapter behind the
      stub; `kmdb_database.dart:32` → reroute; `:1136` → call the factory.
- [ ] Add an explicit `UnsupportedError` in `open()` when web + non-empty
      `vecIndexes`.

**Phase B — the semantic / `EmbeddingModel` seam:**

- [ ] Create `lib/src/search/semantic/embedding_model.dart` (conditional export),
      `embedding_model_native.dart` (**re-export** betto_inferencing types), and
      `embedding_model_stub.dart` (pure-Dart redeclared interface + enum).
- [ ] Reroute the five `betto_inferencing` import sites (`kmdb.dart:116`,
      `kmdb_database.dart:36`, `vec_manager.dart:27`,
      `vault_search_manager.dart:41`, `vault_searcher.dart:26`) to the
      indirection.

**Phase C — prove it and fence it:**

- [ ] Verify `dart compile wasm` (and `dart compile js` per Q2) of a one-line
      barrel-import fixture succeeds from inside `packages/kmdb`.
- [ ] Add the barrel-compile smoke to `make cicd_web` (`make_cicd.mk:161`).
- [ ] Wire `test/engine/storage_adapter_sahpool_test.dart` into `cicd_web`
      (release-ninja #2).
- [ ] Full regression: VM suite (`kmdb` 2653+ tests must stay green — native
      type identity preserved), `make cicd_web`, `make coverage` ≥ baseline.
      Native semantic-search tests must be unaffected.

**Phase D — make the docs true (release-ninja #5 + spec fixes):**

- [ ] `README.md:93` rewritten to match §19/§5 (web = full support minus semantic
      search; not read-only; Zstd via WASM). Fix the "(see §5)" citation.
- [ ] `docs/spec/19_platform.md`: fix the non-existent `storage_adapter.dart`
      code sample (`:10-13`, `:232-235`); reconcile the §19↔§20 lexical-web
      conflict (`:174`); ensure the matrix matches the Q2 wasm/js decision.
- [ ] `docs/spec/22_semantic_search.md:50`: note the compile-time exclusion via
      the indirection stub + `UnsupportedError`.
- [ ] Add a `## 0.1.0` CHANGELOG line for `kmdb` if the reviewer deems the web
      canonical-declaration change worth noting (per the blast-radius decision).

**Then:** mandatory `kmdb-qa` sign-off → `kmdb-pre-commit` → PR (per
`docs/plans/README.md`).

## Summary

_To be completed when the work is done._
