# Export `StorageAdapterSahPool` from the public barrel (web persistence via the public API)

**Status**: Draft (needs investigation → `kmdb-plan-reviewer`)

**PR link**: _(none yet)_

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

## Open questions

- [ ] **Does the native stub need to implement the full `StorageAdapter`
      interface, or only exist as a constructible name?** `StorageAdapterNative`'s
      stub treatment in PR #86 is the precedent — decide whether the stub throws in
      its constructor or only at first use. Recommend: implement the interface with
      members throwing `UnsupportedError`, constructor allowed (matches how a web
      caller would discover the mistake at the first real op, symmetric with
      `StorageAdapterNative` on web).
- [ ] **Is any surface beyond the constructor part of the public contract?**
      Confirm the minimal export (`show StorageAdapterSahPool`) is sufficient and
      no companion type (config/options) must also be exported.

## Implementation plan

- [ ] Create `lib/src/engine/platform/storage_adapter_sahpool_stub.dart` — native
      stub `StorageAdapterSahPool implements StorageAdapter`, members throw
      `UnsupportedError`, no `dart:js_interop`. License header, doc comments.
- [ ] Create `lib/src/engine/platform/storage_adapter_sahpool_export.dart` —
      conditional export (stub default, real behind `if (dart.library.js_interop)`).
- [ ] Add `export '.../storage_adapter_sahpool_export.dart' show StorageAdapterSahPool;`
      to `kmdb.dart` alongside the other adapter exports.
- [ ] **Tests:**
      - Native: assert `StorageAdapterSahPool` is importable from the barrel and
        that constructing/using it throws a clear `UnsupportedError` on the VM.
      - Web (`@TestOn('browser')`, wired into `cicd_web`): construct
        `StorageAdapterSahPool` via the public barrel and open a persistent
        database with it, round-tripping a write across a re-open to prove
        persistence through the public API.
- [ ] **Docs:** remove the "fast-follow" caveat from `README.md`'s web row (web is
      now fully usable persistently via the public API); update `docs/spec/19_platform.md`'s
      note that `StorageAdapterSahPool` "is not re-exported from the public barrel
      today" — it now is.
- [ ] Verify `dart compile wasm` barrel smoke still passes and the VM suite stays
      green; then `kmdb-qa` → `kmdb-pre-commit` → PR.

## Summary

_To be completed when the work is done._
