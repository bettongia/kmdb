# Make `package:kmdb/kmdb.dart` compile for web (0.1.0 release blocker)

**Status**: Investigated

**PR link**: _(none yet)_

> **Review note (2026-08-29).** The `kmdb-plan-reviewer` agent hit an account
> session limit before starting, so this review was performed inline by the main
> session (Opus). It was not a rubber-stamp: it **empirically corrected the
> architect's scoping** (see "Reviewer findings" below) and de-scoped an
> unnecessary piece. A fresh independent `kmdb-plan-reviewer` pass can be run
> post-reset before implementation if extra assurance is wanted; the plan is
> otherwise ready to implement.

## Reviewer findings (inline, 2026-08-29)

1. **Only ONE of the two claimed blockers is a compile blocker.** The architect
   listed `dart:ffi` (via `betto_inferencing`) **and** `dart:io` (via the native
   storage adapter). Direct compilation on this repo's toolchain (Dart 3.13)
   shows **`dart:io` compiles cleanly on both `dart compile wasm` and `dart
   compile js`** — a bare `import 'dart:io'` returns EXIT=0 on both, and
   `package:kmdb/kmdb_config.dart` (which unconditionally exports the
   `dart:io`-backed `IoKmdbConfigStore`) compiles to wasm with no error. So
   `dart:io` is **not** a web-compile blocker here; the sole compile blocker is
   `dart:ffi`, reached only through `betto_inferencing` → `betto_onnxrt` (the
   barrel's wasm error implicated only `betto_onnxrt`/`package:ffi` files — no
   other `betto_*` dep contributes a `dart:ffi` chain; `betto_zstd` is web-safe
   via its conditional WASM build).
2. **Consequence — Phase A simplifies.** The `EmbeddingModel`/`betto_inferencing`
   seam (Phase B) is the **required compile fix**. The storage-adapter *stub*
   (`storage_adapter_native_stub.dart`) is **not needed for compilation** — the
   native adapter compiles on web. What web still needs is a **working default
   at runtime**: `StorageAdapterNative`'s `dart:io` operations throw at runtime
   in a browser, so the `defaultLocalStorageAdapter()` factory returning
   `StorageAdapterSahPool()` on web (Q1) stays in scope as a **runtime**
   correctness item, not a compile fix. Gating the `kmdb.dart:42` native export
   behind a stub is now **optional polish** (avoids shipping a class that throws
   at runtime on web), not a blocker requirement.
3. **Freeze-safety: confirmed sound.** No public signature is removed or renamed;
   the `_native` indirection must **re-export** betto_inferencing's types
   (identity preserved) so `OnnxEmbeddingModel` still satisfies signatures on
   native — the plan states this correctly as the core constraint.
4. **Test adequacy: adequate, with one addition** — add an explicit test that a
   **web** build calling `open()` with non-empty `vecIndexes` throws a clear
   `UnsupportedError` (per the risk note), alongside the VM regression (proves
   native type identity), the wasm barrel-compile smoke, and wiring the
   currently-unrun SAHPool browser test into `cicd_web`.
5. **Scope cut: endorsed.** Bundling release-ninja #2 (SAHPool CI) and #5
   (README↔§19) with the compile fix is right; deferring #3 (Flutter native
   build CI) and #4 (publish dry-run gate) to a separate slice is right.
6. **Residual risk (bounded):** a hidden *second* `dart:ffi` reach via another
   `betto_*` dep would only surface at compile time — caught by Phase C's
   `dart compile wasm` verify gate before the work can be called done. Evidence
   says there is none (see finding 1), but the gate is the backstop.

The two open questions (below) are resolved; the approach is de-risked and
concrete. **Status → Investigated.**

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

New files (4 required + 1 optional): `lib/src/search/semantic/embedding_model.dart`
(indirection), `embedding_model_native.dart`, `embedding_model_stub.dart`, and
`lib/src/engine/platform/default_local_adapter.dart` (the web SAHPool default).
`lib/src/engine/platform/storage_adapter_native_stub.dart` is **optional polish**
only (Reviewer finding 2 — `dart:io` is not a compile blocker on this toolchain).

Modified files (up to 5): `lib/kmdb.dart` (`:116` required; `:42-43` only if the
optional native-export gating is done),
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
seam; wasm-only per Q2 — no `dart compile js` guard). Also wire the
**SAHPool web adapter test** (`test/engine/storage_adapter_sahpool_test.dart`,
`@TestOn('browser')`) into `cicd_web` — today it runs in **no** lane
(release-ninja #2), so §19's "web LSM ✓/Sync ✓" rests on an adapter CI never
executes.

## Open questions

Both resolved by the maintainer (2026-08-26) before the reviewer pass.

- [x] **Q1 — Web storage default: SAHPool factory vs. throwing stub.**
      **Decision: SAHPool factory.** Default web to `StorageAdapterSahPool()`
      via a conditional `defaultLocalStorageAdapter()` factory so
      `KmdbDatabase.open()` works out-of-the-box on web; native still defaults to
      `StorageAdapterNative()`.
- [x] **Q2 — `dart compile js` supported, or wasm-only?** **Decision: WASM
      only.** dart2wasm is the sole supported web compiler for 0.1.0 — it matches
      the existing `--compiler dart2wasm` posture in `cicd_web` and sidesteps the
      dart2js rejection of xxhash's 64-bit int literals (`make_cicd.mk:147-153`),
      which would otherwise require extra engine work. Consequences threaded
      below: the CI guard fences `dart compile wasm` only, and §19/README state
      "web = WASM".

## Implementation plan

_Checklists to be executed by `kmdb-plan-implement` on a dated branch + worktree
once this plan is `Investigated`. Order: land the seam, prove the compile, then
make the docs/CI tell the truth._

**Phase A — the web storage default (runtime, not a compile fix — see Reviewer
finding 2):**

- [ ] Create `lib/src/engine/platform/default_local_adapter.dart` — conditional
      `defaultLocalStorageAdapter()` factory (native → `StorageAdapterNative()`,
      web → `StorageAdapterSahPool()`), per Q1. Wire it at
      `kmdb_database.dart:1136` (replacing the bare `StorageAdapterNative()`
      default). This is the **required** part of Phase A — it makes `open()`
      actually work on web.
- [ ] Add an explicit `UnsupportedError` in `open()` when running on web with
      non-empty `vecIndexes` (clear failure instead of an implicit
      can't-construct-model null path — `kmdb_database.dart:505`).
- [ ] _(Optional polish)_ Gate the `kmdb.dart:42-43` native-adapter export and
      the `kmdb_database.dart:32` import behind a `storage_adapter_native_stub.dart`
      so web never exposes a class that throws at runtime. Not required for the
      compile (native adapter compiles on web) — decide during implementation
      whether the tidiness is worth the extra stub.

**Phase B — the semantic / `EmbeddingModel` seam:**

- [ ] Create `lib/src/search/semantic/embedding_model.dart` (conditional export),
      `embedding_model_native.dart` (**re-export** betto_inferencing types), and
      `embedding_model_stub.dart` (pure-Dart redeclared interface + enum).
- [ ] Reroute the five `betto_inferencing` import sites (`kmdb.dart:116`,
      `kmdb_database.dart:36`, `vec_manager.dart:27`,
      `vault_search_manager.dart:41`, `vault_searcher.dart:26`) to the
      indirection.

**Phase C — prove it and fence it:**

- [ ] Verify `dart compile wasm` of a one-line barrel-import fixture succeeds
      from inside `packages/kmdb` (wasm-only per Q2).
- [ ] Add the barrel-compile smoke to `make cicd_web` (`make_cicd.mk:161`).
- [ ] Wire `test/engine/storage_adapter_sahpool_test.dart` into `cicd_web`
      (release-ninja #2).
- [ ] Add a web test asserting `open()` with non-empty `vecIndexes` throws a
      clear `UnsupportedError` (Reviewer finding 4).
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
