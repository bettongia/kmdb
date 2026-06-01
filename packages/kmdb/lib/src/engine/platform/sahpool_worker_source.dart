// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// coverage:ignore-file
// This file is compiled only when `dart.library.js_interop` is available
// (i.e. on web targets). It must not import `dart:io`.

/// The SAHPool Web Worker JavaScript source, verbatim.
///
/// At startup, [StorageAdapterSahPool] builds a `Blob` from this string,
/// calls `URL.createObjectURL()`, and constructs the `Worker` from the
/// resulting blob URL. This avoids any Flutter asset-bundle or `base href`
/// dependency and works identically under `dart compile js` and WASM builds.
/// No CSP beyond `worker-src blob:` is required.
///
/// **IMPORTANT:** This constant must be kept in sync with
/// `lib/src/engine/platform/sahpool_worker.js`. A future build step could
/// generate this file automatically, but for now manual sync is required.
/// When editing the `.js` file, copy the new content here verbatim.
const String kSahPoolWorkerSource = r"""
// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// SAHPool Web Worker — OPFS synchronous access handle I/O.
//
// This Worker implements the SAHPool message protocol for StorageAdapterSahPool.
// It runs in a dedicated Web Worker where FileSystemSyncAccessHandle is
// available, allowing synchronous byte-level reads and writes with no async
// overhead.
//
// IMPORTANT: The content of this file is also stored verbatim as a const String
// in sahpool_worker_source.dart. Keep the two files in sync — a future build
// step may automate this, but for now manual sync is required.
//
// Message protocol:
//   Request:  { id: int, op: string, ...args }
//   Response: { id: int, ok: true, result: any }
//          or { id: int, ok: false, error: string }
//
// Per-op handle lifecycle (durability contract):
//   Write ops:  open -> write -> flush() -> close
//   Read ops:   open -> read -> close
//   Lock handle: held open for the session lifetime (single-tab exclusion).
//
// Because every write op flushes-and-closes before posting the response,
// the engine's fsync callers (syncFile, syncDir) receive a no-op — the
// handle is already flushed. This satisfies the v0.02.01 durability ordering
// requirements for CurrentFile, WalWriter, ManifestWriter, and LsmEngine.

'use strict';

// Session-held lock handle (exclusive, held for lifetime of the Worker).
let _lockHandle = null;
let _lockPath = null;

// ── Path helpers ──────────────────────────────────────────────────────────────

// Splits a path like '/db/sst/foo.sst' into non-empty segments.
function _segments(path) {
  return path.split('/').filter(s => s.length > 0);
}

// Navigates to the parent directory of `path`, optionally creating missing
// intermediate directories. Returns [dirHandle, filename].
async function _resolve(path, create) {
  const segs = _segments(path);
  if (segs.length === 0) throw new Error('Empty path');
  const name = segs[segs.length - 1];
  let dir = await navigator.storage.getDirectory();
  for (let i = 0; i < segs.length - 1; i++) {
    dir = await dir.getDirectoryHandle(segs[i], { create: create === true });
  }
  return [dir, name];
}

// ── Operation implementations ─────────────────────────────────────────────────

// read(path, offset, length) → Uint8Array
// Opens path, reads [offset, offset+length) bytes, closes.
async function opRead(path, offset, length) {
  const [dir, name] = await _resolve(path, false);
  const fh = await dir.getFileHandle(name, { create: false });
  const sah = await fh.createSyncAccessHandle();
  try {
    const buf = new Uint8Array(length);
    const n = sah.read(buf, { at: offset });
    if (n < length) {
      // Partial read — range extends beyond EOF.
      throw new Error(
        `Range [${offset}, ${offset + length}) out of bounds (read ${n} bytes)`
      );
    }
    return buf;
  } finally {
    sah.close();
  }
}

// readAll(path) → Uint8Array
async function opReadAll(path) {
  const [dir, name] = await _resolve(path, false);
  const fh = await dir.getFileHandle(name, { create: false });
  const sah = await fh.createSyncAccessHandle();
  try {
    const size = sah.getSize();
    const buf = new Uint8Array(size);
    sah.read(buf, { at: 0 });
    return buf;
  } finally {
    sah.close();
  }
}

// write(path, offset, bytes) — open → truncate-to-fit (if growing) → write at
// offset → flush → close. Creates the file if it does not exist.
//
// For a full overwrite (offset === 0) the file is first truncated to the byte
// length being written, which matches the semantics of StorageAdapter.writeFile.
async function opWrite(path, offset, bytes) {
  const [dir, name] = await _resolve(path, true);
  const fh = await dir.getFileHandle(name, { create: true });
  const sah = await fh.createSyncAccessHandle();
  try {
    if (offset === 0) {
      // Full overwrite — truncate to new size so no stale tail remains.
      sah.truncate(bytes.length);
    } else {
      // Partial write — ensure the file is large enough.
      const currentSize = sah.getSize();
      const required = offset + bytes.length;
      if (required > currentSize) {
        sah.truncate(required);
      }
    }
    sah.write(bytes, { at: offset });
    sah.flush();
  } finally {
    sah.close();
  }
}

// append(path, bytes) — open → getSize → write at size → flush → close.
// Creates the file if it does not exist (size 0 → append at 0).
// True append using sync handles — no read-concat-rewrite.
async function opAppend(path, bytes) {
  const [dir, name] = await _resolve(path, true);
  const fh = await dir.getFileHandle(name, { create: true });
  const sah = await fh.createSyncAccessHandle();
  try {
    const size = sah.getSize();
    sah.write(bytes, { at: size });
    sah.flush();
  } finally {
    sah.close();
  }
}

// truncate(path, size) — open → truncate → flush → close.
async function opTruncate(path, size) {
  const [dir, name] = await _resolve(path, true);
  const fh = await dir.getFileHandle(name, { create: true });
  const sah = await fh.createSyncAccessHandle();
  try {
    sah.truncate(size);
    sah.flush();
  } finally {
    sah.close();
  }
}

// getSize(path) → number
async function opGetSize(path) {
  const [dir, name] = await _resolve(path, false);
  const fh = await dir.getFileHandle(name, { create: false });
  const sah = await fh.createSyncAccessHandle();
  try {
    return sah.getSize();
  } finally {
    sah.close();
  }
}

// list(dirPath, extension?) → string[]
// Returns file names (not full paths) in dirPath. If extension is provided,
// only files ending with that extension are returned.
async function opList(dirPath, extension) {
  const segs = _segments(dirPath);
  let dir = await navigator.storage.getDirectory();
  for (const seg of segs) {
    try {
      dir = await dir.getDirectoryHandle(seg, { create: false });
    } catch (_) {
      return []; // directory does not exist
    }
  }
  const names = [];
  for await (const [name, handle] of dir) {
    if (handle.kind !== 'file') continue;
    if (extension && !name.endsWith(extension)) continue;
    names.push(name);
  }
  return names;
}

// delete(path) — removes the file. If path is the held lock file, closes the
// lock handle first to allow deletion.
async function opDelete(path) {
  // Close the lock handle if we're deleting the lock file.
  if (_lockPath === path && _lockHandle !== null) {
    try { _lockHandle.flush(); } catch (_) {}
    try { _lockHandle.close(); } catch (_) {}
    _lockHandle = null;
    _lockPath = null;
  }
  const [dir, name] = await _resolve(path, false);
  try {
    await dir.removeEntry(name);
  } catch (_) {
    // No-op if already gone.
  }
}

// rename(from, to) — durability ordering: write dest → flush dest → close dest
// → delete source. This matches the atomic-rename simulation in the current web
// adapter and satisfies the CurrentFile safety requirement.
async function opRename(from, to) {
  // Read source bytes first.
  const srcBytes = await opReadAll(from);
  // Write destination with per-op flush (provided by opWrite).
  await opWrite(to, 0, srcBytes);
  // Delete source — the destination is already flushed-and-closed by opWrite.
  await opDelete(from);
}

// exists(path) → boolean
async function opExists(path) {
  try {
    const [dir, name] = await _resolve(path, false);
    await dir.getFileHandle(name, { create: false });
    return true;
  } catch (_) {
    return false;
  }
}

// acquireLock(path) — attempts to open an exclusive sync access handle on the
// lock file and hold it for the session. If another tab already holds the
// handle, createSyncAccessHandle() throws; we propagate that as an error so
// the Dart side can raise LockException.
async function opAcquireLock(path) {
  if (_lockHandle !== null) {
    throw new Error('Lock already held on ' + _lockPath);
  }
  const [dir, name] = await _resolve(path, true);
  // Create the lock file if it does not exist.
  const fh = await dir.getFileHandle(name, { create: true });
  // createSyncAccessHandle() throws DOMException (NoModificationAllowedError)
  // if another context already holds an exclusive handle on the same file.
  // We do NOT use a try/catch here — let the throw propagate so the caller
  // can detect it as a lock-collision and surface LockException.
  const sah = await fh.createSyncAccessHandle();
  // Write a sentinel so the file is non-empty and identifiable.
  const sentinel = new Uint8Array([0x4C, 0x4F, 0x43, 0x4B]); // "LOCK"
  sah.write(sentinel, { at: 0 });
  sah.flush();
  // Hold the handle open — this is the cross-tab exclusion mechanism.
  _lockHandle = sah;
  _lockPath = path;
}

// releaseLock(path) — flushes and closes the held lock handle.
async function opReleaseLock(path) {
  if (_lockHandle === null) return; // No-op if not held.
  try { _lockHandle.flush(); } catch (_) {}
  try { _lockHandle.close(); } catch (_) {}
  _lockHandle = null;
  _lockPath = null;
  // Remove the lock file.
  await opDelete(path);
}

// createDir(path) — creates the directory and all intermediate directories.
// OPFS directories are created lazily during write operations, but callers
// such as LsmEngine need to ensure the directory chain exists before listing.
async function opCreateDir(path) {
  const segs = _segments(path);
  let dir = await navigator.storage.getDirectory();
  for (const seg of segs) {
    dir = await dir.getDirectoryHandle(seg, { create: true });
  }
}

// ── Message dispatch ──────────────────────────────────────────────────────────

self.onmessage = async function(event) {
  const { id, op, ...args } = event.data;
  try {
    let result;
    switch (op) {
      case 'read':
        result = await opRead(args.path, args.offset, args.length);
        break;
      case 'readAll':
        result = await opReadAll(args.path);
        break;
      case 'write':
        await opWrite(args.path, args.offset, args.bytes);
        result = null;
        break;
      case 'append':
        await opAppend(args.path, args.bytes);
        result = null;
        break;
      case 'truncate':
        await opTruncate(args.path, args.size);
        result = null;
        break;
      case 'getSize':
        result = await opGetSize(args.path);
        break;
      case 'list':
        result = await opList(args.dirPath, args.extension);
        break;
      case 'delete':
        await opDelete(args.path);
        result = null;
        break;
      case 'rename':
        await opRename(args.from, args.to);
        result = null;
        break;
      case 'exists':
        result = await opExists(args.path);
        break;
      case 'acquireLock':
        await opAcquireLock(args.path);
        result = null;
        break;
      case 'releaseLock':
        await opReleaseLock(args.path);
        result = null;
        break;
      case 'createDir':
        await opCreateDir(args.path);
        result = null;
        break;
      default:
        throw new Error('Unknown op: ' + op);
    }
    // Transfer Uint8Array buffers without copying when possible.
    if (result instanceof Uint8Array) {
      self.postMessage({ id, ok: true, result }, [result.buffer]);
    } else {
      self.postMessage({ id, ok: true, result });
    }
  } catch (err) {
    self.postMessage({ id, ok: false, error: String(err) });
  }
};

// Signal readiness to the main thread so the Dart adapter can begin sending ops.
self.postMessage({ ready: true });
""";
