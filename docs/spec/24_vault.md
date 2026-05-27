# Vault

## Overview

The vault is kmdb's content-addressable binary object store. It provides
file attachment support for documents — analogous to a BLOB column in an RDBMS
— with built-in deduplication, metadata-driven storage, and first-class
distributed sync support.

The vault stores files outside the LSM engine. Each file is identified by its
SHA-256 hash and stored in a structured subdirectory of the database directory.
Documents reference vault objects by URI:

```
kmdb-vault://sha256/{64-hex-char-sha256}
```

Example document referencing a vault object:

```json
{
  "name": "Fred",
  "photo": "kmdb-vault://sha256/dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8"
}
```

The vault is native-platform only in v1. Web platform (OPFS) support is
deferred (see §19).

## Storage Layout

The vault lives in a `vault/` subdirectory of the local database directory.

```
{local-db-dir}/
  vault/
    staging/
      {uuidv4}                    ← in-progress write; swept on open
    blobs/
      sha256/
        {2-char prefix}/
          {62-char suffix}/
            manifest.json         ← always present for a known object
            blob                  ← absent if object is a stub
            tombstone.json        ← present if object has zero references
  VAULT_OFFLINE                   ← device-local pin list (not synced)
```

The `blobs/sha256/` two-level prefix structure mirrors Git's object store,
sharding the hash space to avoid large flat directories. A single 2-character
prefix is sufficient for the expected scale of a kmdb database.

The sync folder gains a parallel vault directory:

```
{sync-root}/
  vault/
    sha256/
      {2-char prefix}/
        {62-char suffix}/
          manifest.json
          blob
          tombstone.json          ← present if object is a GC candidate
```

## Content-Addressable Identity

Files are identified by their **SHA-256** hash. The system applies the
**ISS pattern** (Identity–Size–Secondary) for collision resistance:

1. **Primary hash:** SHA-256 of the raw file bytes.
2. **File size:** Exact byte count.
3. **Secondary hash:** CRC32C (stored in `manifest.json`).

In the extremely unlikely event that two different files share the same SHA-256
hash and file size, the CRC32C distinguishes them. An incoming file whose CRC32C
does not match the stored value is rejected — this prevents a different file
from silently overwriting an existing vault object.

Deduplication is cross-collection and cross-document. Two documents
referencing identical files share one vault object. The shared object is
reference-counted; it is deleted only when no document references it.

## Manifest Schema

Each vault object has a `manifest.json` file written by kmdb at ingestion time.
The manifest is **immutable** — it is never mutated after creation.

```jsonc
{
  "schemaVersion": "1",
  "sha256": "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8",
  "size": 12345,
  "crc32c": "a1b2c3d4",
  "mediaType": "image/jpeg",
  "originalName": "photo.jpg",
  "createdAt": "2026-04-08T12:00:00.000Z"  // HLC timestamp
}
```

| Field           | Type    | Description |
| :-------------- | :------ | :---------- |
| `schemaVersion` | string  | Always `"1"` in v1. |
| `sha256`        | string  | 64-hex-char SHA-256 hash. |
| `crc32c`        | string  | 8-hex-char CRC32C checksum. |
| `size`          | integer | File size in bytes. |
| `mediaType`     | string  | MIME type determined by file signature (magic numbers). |
| `originalName`  | string  | Original filename at time of ingestion. |
| `createdAt`     | string  | HLC timestamp passed in by the caller at write time. |

The media type is determined by file signature inspection, not the file
extension. A media type detection interface is defined; the concrete library
is resolved before implementation begins.

The HLC clock lives inside `LsmEngine`. The vault write API receives the
current HLC value from the caller rather than reading it from the KV store,
keeping the dependency one-directional.

## Object States

A vault object directory can be in one of three states:

| State | Directory contents | Meaning |
| :---- | :----------------- | :------ |
| **Fully hydrated** | `manifest.json` + `blob` | File is present and ready to serve. |
| **Stub** | `manifest.json` only | Object is known; `blob` has not been downloaded to this device. Triggers on-demand hydration. |
| **Unknown** | Directory absent | This device has not seen the object. |

A **tombstoned** object has `tombstone.json` alongside `manifest.json` (and
optionally `blob`). The GC sweep deletes the entire hash directory on its next
pass.

A stub always has a positive KV reference. `syncVaultMetadata` is the only
intended producer of stubs (see §24.7) and `VaultStore.createStub` enforces
the producer-side contract: it reads `$vault:{sha256}` via the same
fail-safe `VaultRefCount.read` used by GC and recovery, and refuses to write
`manifest.json` when the reference is absent or zero. An undecodable ref is
treated as referenced for consistency with the fail-safe rule (see
[Fail-safe ref-count rule](#fail-safe-ref-count-rule)).

A `manifest.json` without `blob` and with no KV reference is therefore by
definition an error state — never a valid stub — and crash recovery deletes
it on the next unclean open. This producer-side invariant is what makes the
recovery rule "manifest present, no ref → delete" safe: it cannot
misfire on a legitimate synced stub, because no legitimate synced stub
leaves that state to begin with.

## Write Path

The vault write (steps 1–4) must complete before the KV Store is updated.
Only once the blob and `manifest.json` are in their final hash directory does
the system write the document to the KV Store. The ref-count increment in
`$vault` and the document write are committed in the same `WriteBatch`.

### Write Ordering

1. Write blob to `vault/staging/{uuidv4}`
2. Verify SHA-256 hash
3. Rename/move blob to final path (atomic on local filesystems)
4. Write `manifest.json` to the final hash directory
5. Commit `WriteBatch`: increment `$vault` ref count + write document

### Crash Recovery

On `open()`, the vault recovery sweep runs before normal operation resumes,
after the standard LSM crash recovery (§17):

1. **Staging sweep:** delete all files and directories under `vault/staging/`.
   The LOCK file guarantees no other process is mid-write, so these are
   unconditionally incomplete and safe to delete.
2. **Hash directory sweep:** inspect each hash directory under
   `vault/blobs/sha256/`:
   - Blob present, no `manifest.json`, no KV ref → delete hash directory
     (incomplete write — not a stub).
   - `manifest.json` present, no KV ref → delete hash directory (orphaned
     vault object).
   - Ref entry present but **undecodable** → **retain** the hash directory (see
     [Fail-safe ref-count rule](#fail-safe-ref-count-rule)). Recovery reports a
     count of such objects so corruption is visible rather than silent.

| Crash after step | State | Recovery action |
| :--------------- | :---- | :-------------- |
| 1 or 2 | Orphaned staging file, no final directory | Delete staging file |
| 3 | Blob in final dir, no `manifest.json`, no KV ref | Delete hash directory |
| 4 | `manifest.json` + blob in final dir, no KV ref | Delete hash directory |
| — | `manifest.json` + blob, ref entry present but undecodable | **Retain** (fail-safe) |

## Deletion & Garbage Collection

### Reference Counting

The `$vault` system namespace maintains a reference count for each vault URI.
The Query Layer intercepts every `put`/`delete` via `writeBatchInternal`,
diffs the old and new document's vault URIs, and adjusts counters atomically
in the same `WriteBatch`. The counter and the document land in the same WAL
record and are replayed together on crash recovery.

```
$vault:{sha256}  →  integer reference count
```

When the count reaches zero, the vault subsystem deletes the `$vault:{sha256}`
entry entirely (so that *absence of the entry is an authoritative "zero
references" signal*) and creates `tombstone.json` alongside `manifest.json` in
the hash directory.

### Fail-safe ref-count rule

Both deletion paths — the GC sweep and crash recovery — read reference counts
through a single, fail-safe reader (`VaultRefCount.read`) that uses the same
`ValueCodec` that wrote them, never a hand-rolled partial decoder. The reader
returns one of three results, and **an object may be deleted only on a positive
determination of zero references**:

| Read result | Meaning | GC / recovery action |
| :---------- | :------ | :------------------- |
| Absent (no entry) | Genuinely zero references (entry deleted at zero) | Delete eligible |
| `refCount == 0` | Zero references | Delete eligible |
| `refCount > 0` | Referenced | Retain |
| **Undecodable** | Present but cannot be decoded (corrupt, truncated, or a future/older codec) | **Retain** |

The critical case is the last one. A content store must fail *safe*: when it
cannot prove an object is unreferenced, it keeps it. A corrupt or unexpected
`$vault` entry is therefore treated as *referenced* and the blob is preserved —
never deleted on uncertainty. Both `VaultGcResult` and `VaultRecoveryResult`
expose a `retainedUndecodable` count so that such entries surface for
investigation instead of being silently retained forever.

> Historical note: earlier builds decoded ref counts with hand-rolled partial
> CBOR parsers that returned `0` ("unreferenced") on any unanticipated byte
> pattern and then permanently deleted the blob. That was a fail-*dangerous*
> default and is replaced by the rule above.

### Tombstoning

`tombstone.json` signals unreferenced state without mutating the immutable
`manifest.json`. Its presence (not its content) is the signal. On its next pass
after `tombstone.json` is found, the GC sweep **re-reads the reference count**
(via the fail-safe reader above) and deletes the entire hash directory only if
the count is still a positive zero (absent or `0`). If the count is now positive
the object was re-referenced — the sweep removes the tombstone instead; if the
count is undecodable the object is retained.

To un-tombstone (when a new document references the hash), delete
`tombstone.json`. The ref-count increment and the `tombstone.json` deletion
happen in the same `WriteBatch` for atomicity.

`tombstone.json` is also uploaded to the sync vault, giving peer devices a
signal that this object is a GC candidate on their side too.

### Pin behaviour

A pin (see §24.8) does not affect the GC lifecycle. A pinned object with zero
references is tombstoned and deleted like any other zero-ref object. The GC
sweep does **not** remove deleted hashes from `VAULT_OFFLINE` automatically —
stale pin entries are silently ignored on startup.

## Distributed Sync

### Sync Adapter

`VaultStorageAdapter` is a separate interface from `SyncStorageAdapter`,
maintaining a clean abstraction boundary. Most implementations provide both.
The adapter is initialised with the local vault root and resolves all paths
from the SHA-256 hash internally.

```dart
abstract interface class VaultStorageAdapter {
  /// Uploads the full hash directory (manifest.json + blob) to the sync
  /// vault. Applies first-writer-wins for manifest.json: checks for
  /// existence before uploading; skips if already present.
  /// Called by push/sync after a new file is ingested.
  Future<void> uploadVaultObject(String sha256);

  /// Downloads manifest.json (and tombstone.json if present) from the sync
  /// vault to the local vault, creating a stub.
  /// Called during normal sync.
  Future<void> syncVaultMetadata(String sha256);

  /// Downloads blob from the sync vault into local staging for hash
  /// verification, then renames to the final path.
  /// Called on-demand when the user requests or pins a file.
  Future<void> hydrateVaultBlob(String sha256);

  /// Returns true if the object exists in the sync vault.
  /// Used by hydrateVaultBlob before attempting a download, and internally
  /// by uploadVaultObject for the first-writer-wins check.
  Future<bool> vaultObjectExists(String sha256);
}
```

### Conflict Avoidance

`blob` files have no conflict: two devices writing the same SHA-256 hash
produce identical bytes.

`manifest.json` files differ only in their `createdAt` HLC timestamp but are
semantically equivalent. A **first-writer-wins** policy applies:
`uploadVaultObject` checks whether `manifest.json` already exists in the sync
vault before uploading; if it does, the upload is skipped. This exploits
`manifest.json`'s immutability and requires no clock comparison or conflict
resolution.

There are no HLC orderings or high-water marks for vault objects. A device
knows whether it has an object locally by checking whether `blob` exists in
the local hash directory. No separate progress tracking is needed.

### On-Demand Hydration

Devices receive stubs (metadata only) during normal sync. The `blob` is not
downloaded until the user requests the file or pins it.

`VaultStore.get()` checks for `blob` presence. If absent and a sync remote is
configured, it triggers `hydrateVaultBlob`, which:

1. Calls `vaultObjectExists` to confirm the remote has the blob.
2. Writes the blob from the remote to `vault/staging/{uuidv4}`.
3. Verifies the SHA-256 hash.
4. Renames the staging file to the final `blob` path.

## Pinned Objects

Users may pin vault objects to prevent stubbing on their device:

```
VAULT_OFFLINE   ← plain-text file in the database root
```

Each line is a vault path:

```
sha256/dd/92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8/
sha256/ed/.../
```

`VAULT_OFFLINE` is device-local and is never synced. A pin signals "keep this
blob downloaded on this device" — it does not affect the object's GC lifecycle.
When the GC sweep deletes a hash directory, it removes the corresponding entry
from `VAULT_OFFLINE`.

## VaultRef

Where a document field value is a valid `kmdb-vault://` URI, the Query Layer
represents it as a `VaultRef` wrapper rather than a raw string.

```dart
final class VaultRef {
  /// The full kmdb-vault:// URI.
  final String uri;

  /// Constructs a VaultRef, validating the URI format eagerly.
  /// Throws [FormatException] immediately if the URI is malformed.
  VaultRef(this.uri);

  /// Retrieves the binary file object, triggering on-demand hydration
  /// if the object is a stub.
  Future<Uint8List> getBlob();

  /// Retrieves the manifest metadata for this vault object.
  Future<VaultManifest> getMetadata();

  @override
  String toString() => uri;
}
```

`VaultRef` is immutable. URI format is validated at construction time —
malformed URIs throw `FormatException` immediately rather than at access time.

`KmdbCodec<T>` is responsible for mapping between `VaultRef` and the typed
model. The Query Layer treats `VaultRef` as opaque.

### Secondary Indexes

If a document field containing a vault URI is indexed, the index entry is the
URI string. This supports "find all documents referencing this vault object"
queries. Querying file metadata via an index is out of scope.

### Reactivity

Vault hydration is invisible to the Query Layer. A stub transitioning to fully
hydrated does not emit a `watch()` event. `count()` and `any()` do not access
blob data and are never blocked by stubs.

## Document + Attachment Packaging

Insert, update, backup, restore, import, and export operations involving vault
objects use a Zstandard archive package format.

### Package Layout

```
document.json
vault/
  {subdirN}/
    manifest.json     ← optional; see §24.10.1
    {originalName}    ← file named by originalName, OR
    blob              ← fallback fixed name
```

The subdirectory names under `vault/` are arbitrary labels used only to
separate objects within the package. The vault subsystem does not interpret
them.

The vault subsystem always generates the canonical `manifest.json` for storage.
Any `manifest.json` provided in the package is informational only and is
discarded in favour of the system-generated version.

### File Resolution

For each subdirectory under `vault/` in the package:

1. If a `manifest.json` is present and its `originalName` matches a file in
   that subdirectory, that file is the blob. If `originalName` is present but
   the named file is absent, the import fails.
2. Otherwise, a file named `blob` is used.
3. If neither resolves, the import fails.

The package must not contain any files or directories not described above.

### Upload Manifest Schema

The `manifest.json` supplied in an upload package differs from the vault's
stored manifest — the uploader cannot know all required fields. Only
`schemaVersion` is required. All other fields are optional; if provided they
are validated against the system-computed values and the import is rejected on
mismatch.

| Field | Required | Behaviour if provided |
| :---- | :------- | :-------------------- |
| `schemaVersion` | Yes | Must be `"1"` or the import fails. |
| `sha256` | No | Compared against computed hash; mismatch → fail. |
| `crc32c` | No | Compared against computed CRC32C; mismatch → fail. |
| `size` | No | Compared against computed size; mismatch → fail. |
| `mediaType` | No | Compared against detected media type; mismatch → fail. |
| `originalName` | No | A file with this exact name (case sensitive) must exist in the subdirectory; absent → fail. |

Processes such as export and backup must produce a `manifest.json` that
adheres to the full stored manifest schema.

## CLI

### `insert` and `update`

Both commands gain an `--import` flag accepting a path to a Zstandard package.
`--import` is mutually exclusive with `--value` and `--file`; providing any
combination is an error.

For `insert`: the package `document.json` is inserted and all referenced vault
objects are ingested.

For `update`, the following scenarios apply:

| Package vault dir | Document references | Outcome |
| :---------------- | :------------------ | :------ |
| Empty or absent | No attachments | Document updated |
| Empty or absent | Attachments already in vault | Document updated |
| Empty or absent | Attachments not in vault | Failure |
| Non-empty | All references resolved from package or existing vault | Document updated |
| Non-empty | One or more references unresolvable | Failure |

In all cases, any vault object in the package must be referenced by a field in
`document.json`. Unrelated objects in the package are rejected.

### Backups and Restores

By default, `backup` produces a plain document list (existing behaviour).
`--vault` produces a Zstandard archive:

```
documents.bak          ← existing backup format
vault/
  sha256/...           ← copy of local vault blobs
```

Stubs (objects with no local `blob`) are not resolved. Only locally-present
blobs are included.

### Exports and Imports

By default, `export` produces NDJSON (existing behaviour).
`--vault` produces a Zstandard archive:

```
documents.ndjson       ← existing export format
vault/
  sha256/...           ← vault objects referenced by the exported collection
```

Stubs are not resolved. The vault scan is per-document and is significantly
more expensive than a backup.

### `get`, `search`, `scan`

These commands return results as they do today, displaying vault URIs as
strings. No attempt is made to resolve or stream vault objects.

### `vault get`

```sh
kmdb {db} vault get {uri}
kmdb {db} vault get kmdb-vault://sha256/dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8
```

Retrieves the vault object (triggering on-demand hydration if only a stub is
present) and writes the binary content to stdout. The global `--output`
parameter saves the result to a file instead.
