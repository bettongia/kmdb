# SAHPool OPFS Web Storage

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

**Roadmap**: docs/roadmap/0_04.md

## Problem statement

`StorageAdapterWeb` already uses the browser's Origin Private File System (OPFS)
via the async File System Access API. However, several operations are
fundamentally inefficient:

- `readFileRange()` reads the entire file then slices in Dart
- `appendFile()` reads the full file, concatenates, and rewrites
- Every operation crosses the JS/Dart boundary asynchronously

OPFS exposes a second, synchronous API — `FileSystemSyncAccessHandle` — that
allows direct byte-level reads and writes without async overhead. The catch: sync
handles can only be obtained inside a dedicated Web Worker. The SAHPool pattern
maintains a pool of pre-opened sync handles in a Worker, proxying calls from the
main thread. The result is 3–4× throughput over the current async adapter, per
the spec §19 note already in the codebase.

The goal is to implement `StorageAdapterSahPool` — a drop-in `StorageAdapter`
replacement that routes all I/O through a SAHPool Worker — and adopt it as the
default web adapter once the database exceeds a configurable size threshold.

## Open questions

- [ ] **Message-passing protocol** — two options for main-thread → Worker
  communication:
  - `SharedArrayBuffer` + `Atomics.wait()` in the Worker: truly synchronous from
    the main thread's perspective, zero round-trip latency, but requires the page
    to be served with `Cross-Origin-Opener-Policy: same-origin` and
    `Cross-Origin-Embedder-Policy: require-corp` headers. Many hosting
    environments (Firebase Hosting, GitHub Pages) do not set these by default.
  - `postMessage` + `Atomics.waitAsync()` round-trips: async from Dart's
    perspective but still uses sync handles inside the Worker; no special headers
    required.
  Which approach is appropriate? The header requirement of `SharedArrayBuffer` is
  a deployment concern for library users. Recommendation: async `postMessage`
  round-trips (no header requirement), accepting that the Dart API remains async
  — which it already is.

- [ ] **Worker lifecycle** — who creates and terminates the Worker? Options:
  - `StorageAdapterSahPool` owns the Worker (spawned on first use, terminated on
    `close()`)
  - The caller provides a pre-created Worker (more testable, avoids double-spawn)
  Recommendation: adapter owns the Worker; expose a `close()` method.

- [ ] **Threshold-based adoption** — the existing code comments suggest switching
  to SAHPool above 10 MB. Should this be automatic (checked at `open()`) or
  always-on for the SAHPool adapter (caller decides which adapter to use)?
  Recommendation: always-on — the caller selects the adapter at `open()` time,
  consistent with how the rest of the adapter pattern works. No magic switching.

- [ ] **Atomic rename** — `StorageAdapterWeb.renameFile()` simulates rename with
  read-write-delete (OPFS has no native rename). `FileSystemSyncAccessHandle`
  doesn't add rename either. Can the Worker implement a safer simulation using
  sync handles, or does this remain best-effort?

- [ ] **Cross-tab locking** — the current adapter uses an in-memory `Set` for
  lock tracking, which doesn't prevent two tabs from opening the same database.
  Does the SAHPool Worker improve this? `FileSystemSyncAccessHandle` itself
  provides exclusive access per handle, which could serve as a real cross-tab
  lock. Worth addressing here or a separate plan?

## Investigation

### Current adapter limitations

`StorageAdapterWeb` (`packages/kmdb/lib/src/engine/platform/storage_adapter_web.dart`):

| Method | Current implementation | Issue |
|--------|----------------------|-------|
| `readFileRange(path, offset, length)` | Reads whole file, slices | O(file size) per block read |
| `appendFile(path, bytes)` | Read + concat + rewrite | O(file size) per WAL append |
| `syncFile()` / `syncDir()` | No-ops | Fine — writes are durable on close |
| `renameFile(from, to)` | Read + write + delete | Not atomic |

`readFileRange` is particularly critical — the SSTable reader calls it for every
4KB block read; reading a 20MB SSTable 4KB at a time triggers 5,000 full-file
reads under the current implementation.

### StorageAdapter interface

14 methods defined in
`packages/kmdb/lib/src/engine/platform/storage_adapter_interface.dart`:
`readFile`, `readFileRange`, `writeFile`, `appendFile`, `syncFile`, `syncDir`,
`deleteFile`, `fileExists`, `listFiles`, `fileSize`, `renameFile`,
`createDirectory`, `acquireLock`, `releaseLock`.

All are async (`Future<T>`), so the SAHPool Worker's sync-handle I/O can be
wrapped in async Dart methods without interface changes.

### SAHPool pattern

A Web Worker is spawned with access to the OPFS root. On startup it calls
`FileSystemDirectoryHandle.getFileHandle(..., {create: true})` and
`FileHandle.createSyncAccessHandle()` for each file it needs to operate on.
These handles support synchronous `read(buffer, {at: offset})`,
`write(buffer, {at: offset})`, `truncate(size)`, `getSize()`, and `flush()`.

Main thread communicates via `postMessage` / `onmessage`. Each message carries
an operation descriptor and a `MessagePort` for the response. The Worker
executes the operation synchronously (no await inside the Worker) and posts back
the result.

### Dart Worker interop

Dart compiles to JS/WASM. A Web Worker script must be a separate JS entrypoint.
Options:
- Compile a minimal Dart Worker library to JS and serve it alongside the app
- Write the Worker in plain JS (simpler, no Dart toolchain dependency in the
  Worker)
- Use `package:web`'s `Worker` bindings from the main Dart thread

A plain JS Worker is the most practical approach: the Worker only needs to
implement the SAHPool message protocol; it doesn't need Dart's type system.
The Dart adapter sends typed messages and parses typed responses.

### Existing spec reference

`storage_adapter_web.dart` already documents the SAHPool pattern and references
spec §19 (`docs/spec/19_platform.md`) as the authoritative source. The
implementation plan should update §19 to cover the SAHPool design.

### Web dependencies

`packages/kmdb/pubspec.yaml` already includes `web: ^1.0.0` for OPFS bindings.
No additional packages are expected to be needed.

## Implementation plan

### Phase 1 — Worker script

- [ ] Write `lib/src/engine/platform/sahpool_worker.js` — a plain JS Web Worker
  that implements the SAHPool message protocol:
  - `open(path)` — open/create a sync handle for a path; cache it
  - `close(path)` — flush and close the handle
  - `read(path, offset, length)` → `Uint8Array`
  - `write(path, offset, bytes)` — write bytes at offset
  - `truncate(path, size)` — set file size
  - `getSize(path)` → number
  - `list(dirPath, extension?)` → `string[]`
  - `delete(path)` — close handle if open, delete file
  - `rename(from, to)` — read + write + delete (best-effort, same as current)
  - `exists(path)` → boolean
  - Each message includes a `id` field; responses echo it for correlation
- [ ] Write unit tests for the Worker protocol using a Worker test harness

### Phase 2 — Dart adapter

- [ ] Implement `StorageAdapterSahPool` in
  `lib/src/engine/platform/storage_adapter_sahpool.dart`
- [ ] Constructor spawns the Worker from the bundled JS URL; waits for `ready`
  message before any operations
- [ ] Each `StorageAdapter` method serialises to a Worker message, awaits the
  response `MessagePort`, deserialises the result
- [ ] `acquireLock` / `releaseLock` — use SAH's exclusive-handle semantics for
  cross-tab safety (open the lock file's handle exclusively; release closes it)
- [ ] `appendFile` — Worker uses `getSize()` then `write(path, size, bytes)`
  (true append using sync handles, no read required)
- [ ] `readFileRange` — Worker calls `read(path, offset, length)` directly
  (O(length) not O(file size))
- [ ] `close()` — sends close-all to Worker, terminates it
- [ ] Add license header (use `@header_template.txt`, year 2026)

### Phase 3 — Conditional export

- [ ] Update `packages/kmdb/lib/kmdb.dart` to export
  `StorageAdapterSahPool` under the `dart.library.js_interop` condition
- [ ] Ensure `StorageAdapterWeb` remains exported as the fallback for
  environments where SAHPool is not desired

### Phase 4 — Tests

- [ ] Integration tests running in a headless browser (using `dart test -p chrome`)
  covering all 14 interface methods
- [ ] Edge cases: `readFileRange` beyond EOF, `appendFile` to non-existent file,
  double `acquireLock`, `releaseLock` without lock
- [ ] Benchmark comparing `StorageAdapterWeb` vs `StorageAdapterSahPool`
  throughput for sequential SSTable writes and block reads (target: confirm 3–4×
  improvement)
- [ ] Achieve ≥90% line coverage on new Dart code

### Phase 5 — Spec and docs

- [ ] Update `docs/spec/19_platform.md` (§19) with SAHPool design: Worker
  protocol, message format, handle lifecycle, cross-tab locking behaviour
- [ ] Update `docs/roadmap/0_04.md` to mark SAHPool OPFS item done
- [ ] Update `CLAUDE.md` implementation status table if a new phase is warranted

## Summary

{Dot points highlighting the work undertaken}
