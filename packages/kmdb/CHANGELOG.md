# Changelog

## 0.1.0

First stable release of KMDB — a local-first document database for Dart and
Flutter — and its first release published to pub.dev.

Covers the full feature set: the LSM storage engine (WAL, memtable, immutable
SSTables, compaction), cloud sync with Last-Write-Wins resolution, the cache
layer, the typed query API with secondary indexes and reactive `watch()`, text
search (lexical BM25, semantic, and hybrid), the content-addressable vault,
document versioning, and optional AES-256-GCM value encryption.

### Web platform support

`package:kmdb/kmdb.dart` — the public API barrel — now compiles for web via
`dart2wasm` (the only supported web compiler; `dart2js` is not supported).
Core LSM, sync, and Zstd compression all work on web; semantic search is
unsupported there and `KmdbDatabase.open` throws a clear `UnsupportedError`
if a non-empty `vecIndexes` list is supplied on web. This is not a breaking
change — the barrel never compiled for web in any published build, so there
is nothing an existing consumer's web build could have depended on.

### Breaking changes since the pre-release (`0.1.0-dev`) builds

These change on-disk formats, sync-wire formats, or public API signatures.
There is **no in-place migration** — a database or sync root written by an
earlier development build must be recreated from source data before adopting
`0.1.0`.

- **Sync artefacts are now authenticated.** Every synced artefact (SSTable,
  high-water mark, vault blob) carries a keyed sync-auth envelope. An artefact
  without a valid envelope — forged, corrupted, or written before authentication
  existed — raises `SyncAuthException` on pull. To adopt an existing remote,
  re-provision it: run `kmdb <db> remote pair show` on an already-enrolled
  device, then `kmdb <db> remote pair import <remote> <code>` on the joining
  device.
- **Encrypted values now bind `(namespace, key)` as AES-GCM associated data**
  (via `ValueContext`). This prevents a ciphertext from being transplanted to a
  different key or namespace, but means ciphertext written by earlier builds can
  no longer be decrypted.
- **Vault blobs carry an unconditional 1-byte encryption-envelope flag prefix**
  on disk (`0x00` unencrypted, `0x01` AES-256-GCM), changing the stored blob
  format.
- **`ConsolidationCoordinator` now requires a `dbDir` argument**, used to derive
  its local staging directory.
- **`pull()` and `sync()` now return `PullResult` / `SyncResult`** instead of
  `void`, reporting which artefacts were applied and which were rejected;
  artefacts that fail validation are recorded in a device-local `$$quarantine`
  log rather than aborting the pull.
- **`KmdbCollection` write semantics tightened.** `insert()` is now a strict
  create — it mints a UUIDv7 for a keyless value and throws `ArgumentError` for
  a value that already has a key. `put()` is a true upsert and returns the
  stored document with its key. `DocumentAlreadyExistsException` has been
  removed; use `insert()` (create), `put()` (upsert), or `replace()`
  (update-only).

### Requirements

- Dart SDK `^3.13.0`.
