# Export `StorageAdapterSahPool` from the public barrel (web persistence via the public API)

**Status**: Implementing (branch
`20260902_plan_0_10_01_sahpool_barrel_export`, started 2026-09-02) —
precondition satisfied: PR #86 merged to `main` 2026-09-01. All implementation
steps, tests, docs, and the mechanical `make pre_commit` gate are done (see the
Implementation plan checklist). **`kmdb-qa` sign-off: ✅ PASS (2026-09-02)** —
zero findings; seam verified implemented exactly as pinned (stub throws in
constructor, full public surface incl. non-interface `close()`, correct
polarity); analyze/format/native+web tests/full VM suite (2657/0) independently
reproduced. Proceeding to commit + PR.

**PR link**: _(none yet)_

> **✅ Precondition satisfied (2026-09-01): PR #86 is merged to `main`.** This
> plan's premises hold only against the post-#86 tree — the precedent seams
> (`embedding_model*.dart`, `default_local_adapter*.dart`), the web-compilable
> barrel, and the README "fast-follow" caveat + §19 "not re-exported" note this
> plan edits all landed in PR #86 (squash-merged to `main` on 2026-09-01). Base
> the implementation branch on current `main`, which now contains them.

> **Provenance.** Follow-up surfaced by the web-barrel compile fix
> (`plan_0_10_01_web_barrel_compile.md`, PR #86) and flagged by `kmdb-qa`
> (memory `web-barrel-sahpool-export-gap`). That plan made `package:kmdb/kmdb.dart`
> *compile* for web and gave web a working **internal** default adapter, but it
> deliberately left one gap: the OPFS/SAHPool adapter is not part of the public
> API, so a web consumer cannot construct persistent storage through
> `package:kmdb/kmdb.dart`. Part of the WI-9 Phase C release-readiness work
> (`docs/roadmap/0_10_01.md`) — it should land before the 0.1.0 tag so the README's
> web claim is fully true, but it is smaller and lower-risk than the compile fix.

## Problem statement

`KmdbDatabase.open`'s `adapter:` parameter is **required** (no default). The
public barrel `packages/kmdb/lib/kmdb.dart` exports only three `StorageAdapter`
implementations (`kmdb.dart:37-43`): the `StorageAdapter` interface,
`MemoryStorageAdapter` (non-persistent), and `StorageAdapterNative`
(`dart:io`, throws at runtime on web). It does **not** export
`StorageAdapterSahPool`, the OPFS-backed web adapter.

Consequently a web application author using only `import 'package:kmdb/kmdb.dart'`
**cannot construct a persistent web database**: their only importable options are
`MemoryStorageAdapter` (lost on reload) or `StorageAdapterNative` (throws at the
first file op on web). PR #86 wired `StorageAdapterSahPool` in as the *internal*
default used by `sync`/`push`/`pull` when `localAdapter` is omitted, but `open()`
itself still has no way for a web caller to supply it. The 0.1.0 README carries an
honest interim caveat ("persistent web storage is a fast-follow"); this plan
closes it.

## Investigation

**Why it can't just be exported unconditionally.** `storage_adapter_sahpool.dart`
imports `dart:js_interop` (via `package:web`). Verified directly on HEAD (Dart
3.13): a native `dart compile exe` of a fixture importing that file **fails** —
`Dart library 'dart:js_interop' is not available on this platform` (from
`package:web`'s `accelerometer.dart` etc.). This is the **asymmetric opposite** of
the `dart:io`-on-wasm finding from PR #86: `dart:io` compiles on dart2wasm, but
`dart:js_interop` does **not** compile on the native VM. So an unconditional
`export 'storage_adapter_sahpool.dart'` from the barrel would break **every native
compile** of `package:kmdb`.

**Therefore the export needs a native-stub triad** — the same conditional-export
seam pattern PR #86 established for `EmbeddingModel` and `default_local_adapter`:

```dart
// lib/src/engine/platform/storage_adapter_sahpool_export.dart
export 'storage_adapter_sahpool_stub.dart'
    if (dart.library.js_interop) 'storage_adapter_sahpool.dart'
    show StorageAdapterSahPool;
```

- The web branch re-exports the real `StorageAdapterSahPool`.
- The native branch (`storage_adapter_sahpool_stub.dart`, new) declares a
  same-named `class StorageAdapterSahPool implements StorageAdapter` with a
  matching public constructor whose members throw `UnsupportedError` (no
  `dart:js_interop`). This keeps the *name* resolvable in native signatures while
  the *behaviour* is web-only — mirroring how `StorageAdapterNative` behaves in
  reverse on web.
- Note the polarity: `dart analyze` resolves a conditional export to its
  **unconditional** branch, so — exactly as documented in PR #86's
  `embedding_model.dart` — the stub must be the unconditional (default) branch and
  the real adapter the `if (dart.library.js_interop)` branch, so the analyzer/VM
  see the pure-Dart stub and only the web compile pulls the real
  `dart:js_interop` file. **Confirm this polarity empirically during
  implementation** (the PR #86 seam is the reference).

**Public-API-freeze note (0.1.0).** This *adds* a public export
(`StorageAdapterSahPool`) — additive, non-breaking. It does freeze
`StorageAdapterSahPool`'s public constructor/surface as part of 0.1.0, so the
reviewer should confirm that surface is what we want to commit to (the
parameterless constructor at `storage_adapter_sahpool.dart:127` is the likely
minimal public shape; check whether any of its other members should be public).

**Anchor points.**
- `packages/kmdb/lib/kmdb.dart:37-43` — the storage-adapter export block to extend.
- `packages/kmdb/lib/src/engine/platform/storage_adapter_sahpool.dart` — the real
  adapter (and its constructor surface).
- `packages/kmdb/lib/src/engine/platform/default_local_adapter*.dart` and
  `lib/src/search/semantic/embedding_model*.dart` — the seam pattern to copy.
- `packages/kmdb/README.md` (web row) — has the interim "fast-follow" caveat to
  remove once this lands.

## Reviewer findings (kmdb-plan-reviewer, 2026-09-01)

Independent pass. The seam design is **sound** and both open questions are now
resolved in-place. One **blocking precondition** (PR #86 not yet merged) is
recorded at the top; it is a sequencing fact, not an architectural gap. With the
decisions below pinned, a Sonnet implementer can execute this mechanically once
#86 lands.

**Empirically reproduced (the load-bearing claim):**

- `dart:js_interop` is **not** available on the native VM — confirmed by
  `dart compile exe` of a fixture importing `storage_adapter_sahpool.dart` from
  inside `packages/kmdb`: it fails with `Dart library 'dart:js_interop' is not
  available on this platform` (dragged in via `package:web`). The compile fixture
  was removed afterward and `git status` verified clean. So an unconditional barrel
  export would break every native compile — the native-stub seam is genuinely
  required, exactly as the Investigation states.

**Seam polarity — CORRECT (priority 1).** `export <stub> if (dart.library.js_interop)
<real>` puts the pure-Dart stub on the unconditional branch. `dart analyze`, the VM,
and `dart compile exe` all evaluate `dart.library.js_interop` as **false** and
resolve to the stub (no `dart:js_interop` in the graph); only dart2wasm/dart2js
evaluate it **true** and pull the real adapter. This is the exact dual of the
already-shipped `local_directory_adapter` seam at `kmdb.dart:57-59`
(`if (dart.library.io)` picks the native branch) and matches PR #86's
`default_local_adapter.dart` seam (`if (dart.library.js_interop)` picks the web
branch). No empirical surprise here — the idiom is in the tree today.

**Public-API-freeze safety (priority 2).** Additive and non-breaking: no existing
symbol is removed or renamed. Both open questions resolved above — key correction:
the native stub must **throw in its constructor** (matching
`local_directory_adapter_stub.dart`, *not* the draft's first-use recommendation),
and must mirror the concrete class's **full** public surface including the
non-interface `close()` (`storage_adapter_sahpool.dart:421`), or cross-platform
consumer code calling `.close()` breaks on native. `show StorageAdapterSahPool`
alone is sufficient — no companion type crosses the boundary.

**Test adequacy (priority 3).** The proposed native + web tests are the right
shape and, with the explicit `close()`-and-fresh-reopen refinement pinned in the
checklist, are sufficient to prove persistence-through-the-public-API. No RC entry
needed.

**Verified against the actual tree.** The problem statement is accurate:
`KmdbDatabase.open` has `required StorageAdapter adapter` (`kmdb_database.dart:316`),
and the barrel exports only `MemoryStorageAdapter` (non-persistent) and
`StorageAdapterNative` (`kmdb.dart:40-43`) — a web caller genuinely cannot construct
persistent storage today. The plan's Phase D doc targets (README "fast-follow"
caveat; §19 "not re-exported from the public barrel today" note) were confirmed to
exist **in PR #86's worktree** (they are what #86 introduces) — hence the sequencing
precondition. Note: `storage_adapter_impl.dart`, flagged as orphaned dead code in
PR #86's review, is **absent from `main`** — no action required here.

## Open questions

Both **resolved** by the reviewer (2026-09-01) against the actual codebase — see
"Reviewer findings". Pinned so no decision is left for the implementer.

- [x] **Does the native stub need to implement the full `StorageAdapter`
      interface, or only exist as a constructible name?** **RESOLVED — throw in the
      constructor, and implement the full public surface throwing too.** The plan's
      original recommendation (constructor allowed, throw at first use) is *reversed*:
      it contradicts this codebase's own established stub convention. The real
      precedent is **`local_directory_adapter_stub.dart`** (not `StorageAdapterNative`,
      which on web is the *real* `dart:io` class throwing at runtime, not a designed
      stub — so there is no symmetry to preserve). That stub declares
      `final class LocalDirectoryAdapter implements SyncStorageAdapter`, throws
      `UnsupportedError` **in the constructor**, *and* gives every interface member a
      throwing body. Mirror it exactly: `final class StorageAdapterSahPool implements
      StorageAdapter`, constructor throws `UnsupportedError('StorageAdapterSahPool is
      not supported on native platforms; it requires OPFS/dart:js_interop.')`, and all
      members throw. **Stub-completeness detail the draft missed:** the concrete
      `StorageAdapterSahPool` has a public **`close()`** method
      (`storage_adapter_sahpool.dart:421`) that is **not** part of the `StorageAdapter`
      interface. Because the barrel exports the *concrete* type, the stub must expose
      the identical public surface or cross-platform consumer code calling
      `adapter.close()` compiles on web but fails to compile on native. The stub must
      therefore declare: the constructor, all **15** `StorageAdapter` members
      (`readFile`, `readFileRange`, `writeFile`, `appendFile`, `syncFile`, `syncDir`,
      `deleteFile`, `fileExists`, `listFiles`, `listFilesRecursive`, `fileSize`,
      `renameFile`, `createDirectory`, `acquireLock`, `releaseLock`), **and**
      `close()` — every body throwing `UnsupportedError`. Pure `dart:typed_data`
      import only; no `dart:js_interop`, no `package:web`.
- [x] **Is any surface beyond the constructor part of the public contract?**
      **RESOLVED — minimal `show StorageAdapterSahPool` is sufficient; no companion
      export needed.** The constructor is parameterless (`storage_adapter_sahpool.dart:127`)
      — there is no config/options type. Every method parameter and return type is
      either a Dart core type (`Uint8List`, `bool`, `int`, `List<String>`, `void`) or
      `StorageException`/`LockException`, both **already exported** from the barrel
      (`kmdb.dart:37-38`). Nothing else crosses the API boundary.

## Implementation plan

- [x] **Precondition:** confirm PR #86 is merged to `main` and base this branch on
      post-#86 `main` (see the boxed precondition at the top). Do not proceed
      otherwise. — confirmed: branch created from `main` @ `47fb40d` (2026-09-02),
      which contains PR #86.
- [x] Create `lib/src/engine/platform/storage_adapter_sahpool_stub.dart` — native
      stub `final class StorageAdapterSahPool implements StorageAdapter`. **Throw
      `UnsupportedError` in the constructor** (per resolved OQ1 / the
      `local_directory_adapter_stub.dart` precedent), and give a throwing body to all
      **15** `StorageAdapter` members **plus the non-interface `close()`** so the
      concrete public surface matches the web class. Import `dart:typed_data` only —
      no `dart:js_interop`, no `package:web`. License header + doc comments;
      `// coverage:ignore-file` (matches the sibling stubs — the throwing bodies are
      unreachable on the platform where the file compiles). — done; verified via
      `dart run` from inside `packages/kmdb` (a scratch fixture importing
      `package:kmdb/kmdb.dart`, deleted afterward) that on native the import
      resolves to this stub and `StorageAdapterSahPool()` throws
      `UnsupportedError` while `StorageAdapterNative()` still constructs fine
      (`dart compile exe` itself doesn't support betto_zstd's native-asset build
      hook in this SDK — `dart run` was used instead, same resolution semantics).
- [x] Create `lib/src/engine/platform/storage_adapter_sahpool_export.dart` —
      conditional export, **stub as the unconditional/default branch**, real adapter
      behind `if (dart.library.js_interop)` (polarity confirmed correct — see
      Reviewer findings; this is the dual of the existing `local_directory_adapter`
      seam at `kmdb.dart:57-59`):
      `export 'storage_adapter_sahpool_stub.dart' if (dart.library.js_interop) 'storage_adapter_sahpool.dart' show StorageAdapterSahPool;` — done.
- [x] Add `export 'src/engine/platform/storage_adapter_sahpool_export.dart' show StorageAdapterSahPool;`
      to `kmdb.dart` alongside the other adapter exports (`kmdb.dart:37-43`). — done;
      `dart analyze lib/` is clean.
- [x] **Tests:**
      - Native (VM): assert `StorageAdapterSahPool` is importable from
        `package:kmdb/kmdb.dart` and that `StorageAdapterSahPool.new` throws
        `UnsupportedError` (e.g. `expect(StorageAdapterSahPool.new, throwsUnsupportedError)`).
        — done: `test/engine/storage_adapter_sahpool_barrel_export_test.dart`
        (also asserts `StorageAdapterNative` still coexists). Passes under
        `dart test`.
      - Web (`@TestOn('browser')`, wired into `cicd_web`): construct
        `StorageAdapterSahPool` **through the public barrel** and
        `KmdbDatabase.open(path:..., adapter: StorageAdapterSahPool())`, write a
        document, **`await db.close()`**, then `open()` the **same OPFS path** with a
        **freshly constructed** `StorageAdapterSahPool()` and assert the document is
        still readable. The close-and-fresh-reopen (not reusing the same handle) is
        what actually proves durable persistence through the public API — that is the
        whole point of the plan. No release-checklist (RC) entry is needed: both tests
        run in automated CI; the un-automatable cross-tab exclusion case is already
        RC-10 (per PR #86). — done:
        `test/query/storage_adapter_sahpool_web_persistence_test.dart`. Must run
        with `--compiler dart2wasm` (same reason as the barrel smoke/vault KAT
        tests — transitively imports xxhash.dart's 64-bit int literals, which
        dart2js's front end rejects). Verified passing locally with
        `dart test --platform chrome --compiler dart2wasm
        test/query/storage_adapter_sahpool_web_persistence_test.dart`; wired
        into `make_cicd.mk`'s `cicd_web` target.
- [x] **Docs:** remove the "fast-follow" caveat from `README.md`'s web row (web is
      now fully usable persistently via the public API); update `docs/spec/19_platform.md`'s
      note that `StorageAdapterSahPool` "is not re-exported from the public barrel
      today" — it now is. — done: `packages/kmdb/README.md`'s platform table and
      `docs/spec/19_platform.md`'s "Conditional Exports" section both updated.
- [x] Verify `dart compile wasm` barrel smoke still passes and the VM suite stays
      green; then `kmdb-qa` → `kmdb-pre-commit` → PR. — done: wasm barrel smoke
      (`test/web/kmdb_barrel_wasm_smoke_test.dart`) and the new web persistence
      test both pass under `--compiler dart2wasm`; full VM suite
      (`cd packages/kmdb && dart test`) passes (2657 tests, 12 e2e skipped);
      `melos run analyze` and `melos format` are clean workspace-wide; `make
      pre_commit` (format_check, analyze, license_check, `pre_commit_test`)
      is green. **This session's toolset has no Agent/Task tool**, so
      `kmdb-qa` sign-off could not be invoked directly — the mechanical
      `make pre_commit` gate was run directly instead (see above), but the
      substantive `kmdb-qa` judgment call is still outstanding and must be
      obtained by the coordinator before this is committed/PR'd (per this
      agent's operating instructions: never fabricate that sign-off).

## Summary

_To be completed when the work is done._
