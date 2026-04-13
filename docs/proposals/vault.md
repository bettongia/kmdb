# Technical Proposal: Content-Addressable Object Storage System

## 1. Overview

This proposal defines a robust, distributed, and deduplicated storage
architecture for long-term archival of files. It utilizes Content-Addressable
Storage (CAS), manifest-driven metadata, and asynchronous maintenance.

The design is informed by object storage systems (e.g. AWS S3) and the Postgres
TOAST system.

The primary goal of the proposal is to discuss the addition of an object storage
facility within the database structure. The kmdb database is presently stored in
a directory structure and it is proposed that the object store would sit in a
subdirectory (`vault`).

The object store targets the use case for which the user wishes to attach files
to a record (much like a BLOB field in an RDBMS). Storage of files in the
storage engine is unlikely to be an effective approach.

## 2. The Vault Model (Storage Layout)

Each database instance has no more than 1 vault. The vault lives inside the
database directory as a sub-directory named `vault`. A sub-directory of `vault`
named `blobs` will hold the storage structure for the various files added to the
vault. This additional level allows for future use of the parent `vault`
directory without interfering with the file storage aspect of the service.

Each entry (file) in the vault is stored using the SHA256 hash of the file being
stored. For example, say the file `hello.txt` has a hash of
`dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8`,

The hashing name (`sha256`) will be used as the name of the subdirectory under
`blobs`. This allows for easier adoption of alternative hashing methods at a
later date.

The SHA256 of the file to be added to the vault is then generated and, similar
to Git, the first 2-characters form the next sub-directory down, followed by the
remainder of the hash (the suffix) as a further sub-directory.

Barring a clash in the hash (discussed in a later section), a `manifest.json`
contains metadata about the file (discussed later) and is stored under that
sub-directory based on the hash suffix. The uploaded file itself is always
stored with the file name `blob`.

The directory structure for storing `hello.txt` would appear as:

```
{local-db-dir}/
   ...
   vault/
      blobs/
         sha256/
            dd/
               92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8/
                  manifest.json
                  blob
```

### 2.1 Content-Addressable Identity

Files are identified by **SHA-256**.

Verification uses the **ISS Pattern** (Identity-Size-Secondary):

1. **Primary Hash:** SHA-256
2. **File Size:** Exact byte count.
3. **Secondary Hash:** CRC32C (stored in `manifest.json`).

The approach here will allow for de-duplication in the vault as the same file
won't be stored multiple times.

The approach provides de-duplication cross-collection and cross-document
(relating to cross-database-document, not the file attachment itself). Two
documents attaching the exact same file share one vault object. This has privacy
implications in a multi-user scenario, but kmdb is a local-first, single-user
database and this is fine.

### 2.2 Directory Sharding

**Structure:** `blobs/sha256/{prefix1}/{hash_suffix}/`

**Example:**
`blobs/sha256/dd/92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8/`

As per common practice (e.g. Git) uses a 2-char prefix + remaining chars
(suffix).

Design note: A single 2-char prefix is sufficient and simpler for the expected
small-to-medium size of a kmdb database.

### 2.3 Package Encapsulation

Each object (file) is stored in the directory (as per 2.2), in the following
manner:

- `manifest.json`: Technical metadata:
  - Original names
  - timestamps
  - CRC32C (second hash)
  - media type
- `blob`: The actual data/file.

As `manifest.json` holds metadata such as the original file name and media type,
the system can easily reconstitute the details when presenting the file to the
user.

The system will determine the media type through the use of file signatures
(magic numbers) and various means beyond just accepting the file extension. A
library will be added to the system to perform this and won't need to be
developed here.

> **[Review]:** Name the library candidates now (e.g. `mime`, `file_magic`, or a
> custom magic-number table) so the dependency decision is made deliberately and
> not at implementation time.

Response: let's use an interface for now. I will bring in the code before we
start any implementation work.

### 2.4 Manifest Schema

Below is an example `manifest.json`

```jsonc
{
  "schemaVersion": 1,
  "sha256": "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8",
  "size": 12345,
  "crc32c": "a1b2c3d4",
  "mediaType": "image/jpeg",
  "originalName": "photo.jpg",
  "createdAt": "2026-04-08T...", // HLC
}
```

The schema provided below is for guidance regarding the properties within the
manifest. Note that kmdb does not currently support the use of JSON schema - the
schema below is used to describe the structure:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://kmdb.io/schemas/vault-manifest.schema.json",
  "title": "KMDB Vault Manifest",
  "description": "Metadata for files stored within the kmdb_vault system.",
  "type": "object",
  "required": [
    "sha256",
    "crc32c",
    "size",
    "mediaType",
    "originalName",
    "createdAt"
  ],
  "properties": {
    "sha256": {
      "type": "string",
      "pattern": "^[a-fA-F0-9]{64}$",
      "description": "Hex-encoded SHA-256 hash of the file."
    },
    "crc32c": {
      "type": "string",
      "pattern": "^[a-fA-F0-9]{8}$",
      "description": "Hex-encoded CRC32C checksum of the file."
    },
    "size": {
      "type": "integer",
      "minimum": 0,
      "description": "File size in bytes."
    },
    "mediaType": {
      "type": "string",
      "pattern": "^[a-zA-Z0-9!#$%^&*_\\-+{}\\|'.`~]+/[a-zA-Z0-9!#$%^&*_\\-+{}\\|'.`~]+$",
      "description": "The MIME type of the file."
    },
    "originalName": {
      "type": "string",
      "minLength": 1
    },
    "createdAt": {
      "type": "string",
      "format": "date-time",
      "description": "HLC timestamp of creation."
    }
  }
}
```

**[Follow-up — HLC source]:** `manifest.json` is written by the vault subsystem,
which lives outside the KV store. The HLC clock lives inside `LsmEngine`. The
vault writer will need a way to read the current HLC at write time — either by
being passed the clock value from the caller, or by reading it from the KV store
after the fact. Passing the HLC at call time is cleaner. Define this in the
vault write API (§7).

A pin is marked by an entry in the `pinnedBy` property. When a user pins an
object they are requesting that it be made available offline. As such, a pin
blocks the object from being deleted even if the object is no longer referenced
by a database document. This will require that a user can force deletion of an
object if required - for example, the device that holds the pin is no longer in
use. Such deletion is only possible if no references still exist for the object.

## 3. Deletion & Maintenance

### 3.1 Asynchronous Sweep Logic

1. **Reference Counting:** kmdb will know of active links to hashes (objects,
   files) through the use of a reference count.
2. **Tombstoning:** Zero-ref hashes will be marked as `Unreferenced` in their
   `manifest.json`.
3. **Grace Period:** Configurable (e.g., 30 days) before actual deletion.
4. **Compaction Thread:** Background process verifies "Safe-to-Kill" and purges
   the directory storing the file and `manifest.json`.

Write-time reference tracking is used to maintain a reference count in a
separate `$vault` system namespace, incremented/decremented at write time
(similar to how `$index` works). The write-time approach is consistent with how
KMDB already maintains `$index` and `$cache` namespaces, and avoids periodic
O(n) full scans. The mechanics are well-understood from how `$index` works: the
Query Layer intercepts every `put`/`delete` via `writeBatchInternal`, diffs the
old and new document's vault URIs, and adjusts counters atomically in the same
`WriteBatch`. Zero extra I/O on reads; GC sweep is a cheap scan of `$vault:*`
for zero-valued entries. Crash safety comes for free — the counter and the
document land in the same WAL record and are replayed together.

> **[Review]:** Mutating `manifest.json` in-place to set
> `status = "unreferenced"` breaks the "file creation is the atomic primitive"
> design principle from the sync protocol (§12). How does an in-place manifest
> mutation sync correctly to other devices? Consider an append-only tombstone
> file alongside the manifest rather than mutating it.

So as to avoid a manifest mutation: when a vault object reaches zero references,
create a `tombstone.json` alongside `manifest.json`. Its presence (not its
content) signals unreferenced state. This is a pure file creation — atomic, and
consistent with the sync design principle. The GC sweep deletes the entire hash
directory only when `tombstone.json` is older than the grace period. To
un-tombstone (a new document references the hash), simply delete
`tombstone.json`. This also gives sync a clean signal: uploading
`tombstone.json` to the sync folder tells peer devices this object is GC
candidates on their side too.

> Q: What happens if the device is offline for longer than the grace period and
> then comes back online? Is there a risk of a file being deleted on one device
> while another device is still referencing it?

Investigate: This should be protected through the last-write-wins approach. We
need to determine what happens when a device tries to sync with a really old
copy of the data too.

> **[Follow-up — offline grace period]:** With the `tombstone.json` approach
> above, `unreferencedAt` lives in `tombstone.json` (written once, never
> mutated). The offline deletion risk is real but manageable: the $vault
> reference counter in the KV store is the authoritative source. Before the GC
> sweep deletes a directory it should re-verify the counter is still zero — not
> just check the tombstone age. A device coming back online after a long absence
> would sync new documents first, which increments counters; the GC sweep
> running afterwards would then skip any object whose counter had been restored.

### 3.2 Atomicity and Crash Safety

Proposed ordering that minimises risk:

1. Write blob to a staging path (e.g. `vault/staging/{uuid}`)
2. Verify hash
3. Rename/move to final path (atomic on local filesystems)
4. Write `manifest.json`
5. Update KV Store

On open/recovery, any orphaned staging files and any vault paths with a manifest
but no corresponding KV reference should be swept. This is analogous to how WAL
replay and orphan SSTable deletion work today (§17).

## 4. Distributed Sync & Lazy Hydration

### 4.1 Metadata-First Replication

The existing sync protocol (§12) is SSTable-based. Vault objects are not
SSTables and cannot travel through the existing `sstables/` sync folder. The
vault subsystem will provide its own sync engine. The vault replicates the files
(`blob`) asynchronously as some files may be large. This will require 2 stages
to sync:

1. Synchronise the `manifest.json` file and other metadata files first
2. Upload files to the sync folder

Files are only downloaded on demand - such as when they are pinned or
specifically requested.

There a single shared vault in the sync folder that all devices read from/write
to How does the `.hwm` mechanism extend to vault objects. Unlike SSTables (which
are device-scoped and never shared), vault objects are content-addressed and
identical across all devices. This means a **single shared vault directory** in
the sync folder makes sense — any device can write a vault object and all
devices read from the same path. There are no conflicts because two devices
writing the same SHA-256 produce identical bytes.

The `.hwm` mechanism does not extend to vault objects. A device knows whether it
has a vault object locally by checking whether the `blob` exists in the local
hash directory. No separate progress tracking is needed.

A `VaultStorageAdapter` interface will provide two new methods:
`uploadVaultObject` and `downloadVaultObject`. Whilst these could be provided
via the `SyncStorageAdapter`, the preference is to maintain abstraction for the
vault subsystem. Note, however, that most implementations are expected to
provide for both interfaces and an approach that allows synchronisation to be
split across two locations (e.g. SSTables in Google Drive and vault in Google
Cloud Storage) is not considered in this proposal. The 2 storage methods are
simpler than SSTable sync — no HLC ordering, no high-water marks, just existence
checks and file transfer. The SHA256 hash will be used to validate that the file
has been successfully downloaded to the device and uploaded to the sync vault.

### 4.2 On-Demand Hydration (Stubs)

Devices will store "Stubs" (Metadata only), with files being downloaded
"on-demand".

The ability for a user to configure the system to download all vault objects is
out of scope and will be considered in a later proposal/plan.

For those using the "on-demand" approach, the following process takes place

- **Request:** User clicks a file in an app ui or requests the file via the CLI.
- **Hydrate:** Stream from the remote to a staging location for verification
  (check the SHA etc).
- **Verify:** Hash incoming data; move to local vault on success.
- **Pinning:** Users can select "Make Available Offline" to prevent the file
  being stubbed locally.

The "stubbing" could be due to a configuration item that removes files
(excluding those explicitly requested to be available offline) that haven't been
accessed for `n` days.

A "Stub" on disk is actually represented by the absence of the `blob` file. The
directory structure will be present and stores the `manifest.json` file. Absence
of the requested `blob` file will trigger the need to download the file from the
sync vault.

As such, the object directory in the vault can be in one of three states:

- Hash directory + `manifest.json` + `blob` → **fully hydrated**
- Hash directory + `manifest.json` only → **stub** (known to exist, not
  downloaded)
- Hash directory absent → **unknown** (not yet seen by this device)

`VaultStore.get()` checks for `blob` presence; if absent and a sync remote is
configured, it triggers on-demand hydration. This requires no sentinel file and
falls out naturally from the staged write approach in §3.2 (a crashed write
leaves `manifest.json` without `blob`, which is exactly the stub state —
recovery just cleans up the staging directory).

Note that files attached from a specific device should already exist in the
vault. The file will only be removed (leaving the stub behind) when explicitly
requested by the user (perhaps seeking to reduce local storage use). The vault
system will check that the file exists in the sync vault before removing the
local file. If the remote copy does not exist the user will need to sync the
vault before being allowed to delete the file. For kmdb instances that have no
remote configured for sync the user is not able to delete files from the vault
via kmdb.

As kmdb stores data in a file system, it is susceptible to users deleting files
directly using standard tools such as Finder or the `rm` command. No effort will
be made by kmdb to rectify such actions and the database will be in an unstable
state. The `verify` command in the CLI should report missing files.

## 5. Document + attachment packaging

The vault approach requires that functions such as `insert`, `update` and
import/export will need more than just the JSON defining the document. As such,
a packaging format is required to hold the document data plus 0 or more
attachments.

A simple ZIP-based packaging model approach will be used. The Zip file will
contain:

1. A `document.json` file at the root, containing the document itself in JSON
   format
2. A `vault` directory with one or more sub-directories, each housing a file
   attachment and containing:
   1. the `manifest.json` file (plus any additional metadata files required by
      vault)
   2. the file itself.

On imports, the vault system will check the Zip-based attachments as per the
following:

1. If the `originalName` property value matches the name of a file in the Zip
   archive, that file will be seen as the object
2. If 1 fails, a file named `blob` in the Zip archive will be used
3. If 1 & 2 fail then the import will fail.

### `manifest.json` schema for uploads

### CLI

The `insert` command already has an existing `--file` parameter to allow for
uploading the JSON document and the intent is to not overload this through the
use of a check to see if the value of `--file` points to a JSON or Zip file.
Instead, an `--import` parameter will be added to the `insert` command to allow
the user to provide the location of the Zip package to be inserted. If
`--import` is provided then `--value` and `--file` are ignored.

The `update` command will also provide an `--import` parameter. The command will
need to handle handle the following scenarios:

1. The package contains no attachments (i.e. no `vault` directory or an empty
   `vault` directory) and:
   1. The update doesn't reference any attachments -> the document is updated
   2. The update references attachments but they already exist in the `vault` ->
      the document is updated
   3. The update references attachments that are not present in the package and
      do not exist in the `vault` -> Failure
2. The package contains attachments (i.e. a non-empty `vault` directory) and:
   1. The updated properties references attachments that are either in the
      package or already exist in the vault -> the document is updated
   2. The updated properties do not reference one or more of those attachments
      -> Failure

For Item 2.1 above, an update may point an existing property to a new vault
item, leaving the previously referenced item with no more references.

In both the `insert` and `update` cases, the system must ensure that the
attached objects are actually referenced in the package so as to avoid the user
being able to upload unrelated files. If the imported package does not contain
the expected package contents and the files linked from properties in
`document.json`, this will cause an error and no change to the database will
occur.

### Backups and restores

Backup will need to output

## 6. Storage Workflow

1. **Write Blob:** Stream to vault.
1. **Write Manifest:** Finalize metadata file.
1. **Update DB:** Increment Ref-Count and map logical names to the Vault Path.

### 6.1 Large File Streaming

> **[Review — missing section]:** Streaming is mentioned in §7 but not designed.
> Questions to address:
>
> - What is the maximum in-memory buffer size during a vault write?
> - How does the stream interact with the staging-then-rename approach proposed
>   in §3.2? The hash cannot be known until the full stream is consumed.
> - For files that are too large to buffer, the SHA-256 must be computed
>   incrementally (a streaming SHA-256 digest). Confirm the chosen library
>   supports incremental hashing.
> - At what file size does streaming become mandatory vs. in-memory read?

### 6.2 Secondary-Usage Promotion Threshold

> **[Review — missing section]:** §1 describes auto-promotion of large document
> fields to vault. This needs a concrete trigger condition:
>
> - Is there a configurable byte threshold (e.g. fields > 64KB)?
> - Is promotion opt-in (user annotates the field) or automatic?
> - If automatic, how does the Query Layer handle a document where a field is a
>   vault stub — can you filter on a promoted field's value? Can a secondary
>   index be maintained on a vault-stored field?
>
> This is a significant complication to the query pipeline. Recommend deferring
> auto-promotion to a separate proposal and limiting v1 to explicit vault
> references via `kmdb-vault://` URIs.

## 7. Other considerations

1. We need to consider the vault API - it's likely the standard S3-style of get,
   put, delete etc

1. The insertion ergonomics need to be considered:
   1. Some SQL-based databases allow raw bytes for the attachment
   2. SQLite has a `readfile` function in the CLI
   3. Postgres has `pg_read_binary_file` and `lo_import`
   4. Very large files likely need to be streamed
   5. We could consider a zip file that contains the JSON document plus the
      files being inserted. The Frictionless Data Package could be of interest
      here.

1. We need to consider how a document can reference objects in the vault. One
   approach could be to use a URI (`kmdb-vault://`) as the value of a field,
   indicating that the record is pointing to a file in the vault.

> **[Review]:** The `kmdb-vault://` URI scheme needs a formal definition.
> Proposed format: `kmdb-vault://sha256/{full_hex_hash}` — the hash alone is
> sufficient to locate the object in the vault tree. Including the filename or
> media type in the URI would create redundancy with the manifest. Define
> whether the URI is validated at write time (vault object must exist) or is a
> lazy reference (validated at read time).

## 8. Encryption at Rest

> **[Review — missing section]:** The proposal does not address encryption. The
> KV Store stores CBOR-encoded documents; vault blobs are raw binary. For users
> storing sensitive files (documents, photos), at-rest encryption is a
> reasonable expectation. Questions to address:
>
> - Is encryption in scope for v1?
> - If yes: key management strategy (per-device key, per-vault key,
>   user-supplied passphrase)?
> - How does encryption interact with de-duplication? Two devices encrypting the
>   same file with different keys will produce different ciphertexts and
>   therefore different SHA-256 hashes — de-duplication breaks. This is a known
>   trade-off in encrypted CAS systems.
> - How does encryption interact with the sync folder? Cloud providers may
>   already encrypt at rest — is a second layer necessary?

## 9. Compression Policy

> **[Review — missing section]:** KMDB already applies Zstd (native) or Deflate
> (web) compression to KV values (§5). Vault blobs need a separate, explicit
> compression policy:
>
> - Already-compressed formats (JPEG, MP4, PDF, ZIP, PNG) must **not** be
>   re-compressed — the result will be larger than the input.
> - Text-based formats (plain text, source code, HTML, XML) compress well and
>   should be compressed.
> - The media type detection from §2.3 should inform the compression decision.
> - Consider storing whether the blob is compressed in `manifest.json` so the
>   read path knows whether to decompress.

## 10. Query Layer Integration

> **[Review — missing section]:** The proposal is mostly silent on how the vault
> integrates with the Query Layer (§13). Critical questions:
>
> **Typed codec integration:** A `KmdbCodec<T>` encodes a
> `Map<String, dynamic>`. If a document field contains a `kmdb-vault://` URI,
> the typed model likely needs a wrapper type (e.g. `VaultRef`) rather than a
> raw string. How does `KmdbCodec<T>` express this? Does the Query Layer need to
> understand `VaultRef`, or is it opaque to it?
>
> **Secondary indexes on vault fields:** If a document field containing a vault
> URI is indexed, the index entry would be the URI string — useful for "find all
> documents referencing this vault object" but not for querying the file's
> metadata. Is that sufficient?
>
> **`watch()` and hydration:** If a user `watch()`es a collection and a vault
> field transitions from stub to hydrated, should the stream emit a new event?
> Or is vault hydration invisible to the query layer?
>
> **Count and `any()`:** Queries like `count()` and `any()` do not access blob
> data. Vault stubs should not block these operations.

## 11. Open Questions

Questions marked ✅ are resolved. Remaining questions must be answered before
this proposal moves to a plan.

1. **Scope of v1:** Primary usage (explicit file attachments) only, or does v1
   also include secondary usage (auto-promotion of large document fields)?

2. **Reference counting strategy:** Write-time `$vault` namespace is recommended
   (see §3.1 follow-up). Confirm.

3. **Sync folder structure:** Single shared `vault/` directory in the sync
   folder, with `uploadVaultObject`/`downloadVaultObject` on `CloudAdapter`.
   Confirm and define the method signatures.

4. **Stub representation on disk:** `manifest.json` present + `blob` absent =
   stub. Confirm (contingent on §2.3 blob-naming decision).

5. **Encryption:** In scope or deferred?

6. ✅ **Secondary hash algorithm:** CRC32C.

7. **Atomicity model:** Staging-then-rename confirmed in principle (§3.2).
   Confirm crash recovery sweeps `vault/staging/` on `open()`.

8. **`kmdb-vault://` URI formal spec:** `kmdb-vault://sha256/{hex}` proposed.
   Eager or lazy validation?

9. **Web/OPFS:** Is vault supported on web in v1, or native-only?

10. **Compression:** Opt-in per object, automatic based on media type, or always
    off?

11. **Blob naming in hash directory:** `obj/<originalName>` (current proposal)
    vs. fixed name `blob` (see §2.3 follow-up). Decide before schema is
    finalised.

12. **`pinnedBy` semantics:** Pin blocks deletion indefinitely, or extends grace
    period? Recommendation: blocks indefinitely (see §2.4 follow-up).

13. **Directory sharding depth:** Two prefix levels (current) vs. single prefix
    (recommended). Decide before directory layout is finalised.

## 12. Future work

### Web platform

The web platform is out of scope for this proposal.

The web platform uses OPFS (Origin Private File System) which supports directory
operations but has different performance characteristics than native IO.
Streaming a large file from a remote into OPFS staging needs explicit handling —
the same approach used on native (dart:io) won't work on web (dart:js_interop).
This needs a conditional platform export similar to the existing platform layer
(§19).
