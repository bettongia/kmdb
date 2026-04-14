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

Documents stored in kmdb can refer to objects in the vault using the
`kmdb-vault` URI scheme with a template of
`kmdb-vault://sha256/{full_hex_hash}`. The document below is an example of a
link in the `photo` property that refers to a file in the vault:

```json
{
  "name": "Fred",
  "photo": "kmdb-vault://sha256/dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8"
}
```

### Design note

There is no implicit semantic link between the property and the vault object -
it is purely a reference. This semantic functionality is not provided by kmdb
directly. Rather, the document will need to encapsulate the relationship and
(presumably) be understood by an application. One such approach is to use
JSON-LD to define a document - though kmdb does not "understand" JSON-LD, it
will happily store the document. An example document based in this approach is
provided below:

```json
{
  "@context": "https://schema.org",
  "@type": "Person",
  "name": "Fred",
  "image": "kmdb-vault://sha256/dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8"
}
```

## 2. The Vault Model (Storage Layout)

Each database instance has no more than 1 vault. The vault lives inside the
database directory as a sub-directory named `vault`. A sub-directory of `vault`
named `blobs` will hold the storage structure for the various files added to the
vault. This additional level allows for future use of the parent `vault`
directory without interfering with the file storage aspect of the service.

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

Each entry (file) in the vault is stored using the SHA256 hash of the file being
stored. For example, say the file `hello.txt` has a hash of
`dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8`, the
directory structure for storing `hello.txt` would appear as:

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

Files are identified by their **SHA-256** hash.

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

The second hash (CRC32C) is utilised in cases where 2 different files have the
same SHA256 hash and file size. In order to determine if 2 files with the same
SHA256 hash are different files, a second hash (CRC32C) is generated and
compared. If the incoming file has a different CRC32C to the one in the vault
then the incoming file is rejected. This avoids possible "corruption" of the
data where a different file overwrites an existing one due to the (immensely
small chance) clash.

As `manifest.json` contains the SHA256, file size (`size` property) and CRC32C
hash value, the file does not need to be loaded from the sync vault in order for
comparisons to take place.

### 2.2 Directory Sharding

**Structure:** `blobs/sha256/{prefix1}/{hash_suffix}/`

**Example:**
`blobs/sha256/dd/92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8/`

As per common practice (e.g. Git) use a 2-char prefix + remaining chars
(suffix).

Design note: A single 2-char prefix is sufficient and simpler for the expected
small-to-medium size of a kmdb database. A further level of sub-directories such
as
`blobs/sha256/dd/92c2/600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8/`was
deemed unnecessary.

### 2.3 Package Encapsulation

Each object (file) is stored in the directory (as per 2.2), in the following
manner:

- `manifest.json`: Technical metadata:
  - Original file name
  - timestamps
  - SHA256 and CRC32C (second hash)
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

The manifest is constructed by kmdb at the time of ingesting the object.

The `manifest.json` file is never mutated. The file is deleted as part of the
clean-up of unreferenced objects.

Below is an example `manifest.json`:

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
    "schemaVersion",
    "sha256",
    "crc32c",
    "size",
    "mediaType",
    "originalName",
    "createdAt"
  ],
  "properties": {
    "schemaVersion": {
      "type": "string",
      "description": "The version of the manifest format.",
      "const": "1"
    },
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

### 2.5 Pinned files

An end-user may elect to "pin" an object so that it is available on the device
even when offline. A pin is marked by the existence of an entry in a file named
`<VAULT_OFFLINE>` located in the top-level directory of the database. The
`<VAULT_OFFLINE>` file consists of a vault path per-line of those objects that
the user has asked to be made available offline.

Example `<VAULT_OFFLINE>` file

```
sha256/dd/92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8/
sha256/ed/.../
```

The pin files are only of interest on the specific device and are not
synchronised.

Pinned objects are deleted when the the object is no longer referenced by a
database document. Keeping them in the vault with no linking documents would
create orphaned files.

## 3. Deletion & Maintenance

### 3.1 Asynchronous Sweep Logic

1. **Reference Counting:** kmdb will know of active links to hashes (objects,
   files) through the use of a reference count.
2. **Tombstoning:** Zero-ref hashes will be marked as `Unreferenced` in their
   `manifest.json`.
3. **Compaction Thread:** Background process verifies unreferenced objects and
   purges the directory storing the file and `manifest.json`.

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

So as to avoid a manifest mutation: when a vault object reaches zero references,
create a `tombstone.json` alongside `manifest.json`. Its presence (not its
content) signals unreferenced state. This is a pure file creation — atomic, and
consistent with the sync design principle. The GC sweep deletes the entire hash
directory only when `tombstone.json` is older than the grace period. To
un-tombstone (a new document references the hash), simply delete
`tombstone.json`. This also gives sync a clean signal: uploading
`tombstone.json` to the sync folder tells peer devices this object is GC
candidates on their side too.

There is no grace period for deletion.

### 3.2 Atomicity and Crash Safety

Proposed ordering that minimises risk:

1. Write blob to a staging path (e.g. `vault/staging/{uuidv4}`)
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

The vault approach requires that functions such as `insert`, `update`,
backup/restore, and import/export will need more than just the JSON defining the
document. As such, a packaging format is required to hold the document data plus
0 or more attachments.

A simple Zstandard-based packaging model approach will be used. The Zstandard
file will contain:

1. A `document.json` file at the root, containing the document itself in JSON
   format
2. A `vault` directory with one or more sub-directories, each housing a file
   attachment and containing:
   1. the `manifest.json` file (plus any additional metadata files required by
      vault)
   2. the file itself.

An example layout of the package is provided below

```
document.json
vault/
  file1/
    manifest.json. # with `"originalName": "mydoc.pdf"`
    mydoc.pdf
  file2/
    blob
  file3/
    manifest.json
    blob
```

The naming of the subdirectories under `vault/` in the package are purely used
to separate the objects being uploaded. No use of the directory name is made by
the vault subsystem.

The vault subsystem must always generate the canonical `manifest.json` that will
be stored in the vault. This will include generation of all required hashes so
as to ensure that the data and metadata is correctly aligned.

An imported package may have one or more `manifest.json` files for the objects
being imported. These are informational only to vault and will be discarded in
favour of the system-generated version.

On import, the vault system will check the Zstandard-based attachments in each
sub-directory under `vault` as per the following:

1. If the `originalName` property in `manifest.json` value matches the name of a
   file in the Zstandard archive, that file will be seen as the object. If a
   file of that name does not exist in the package, the import will fail.
2. If 1 fails (or `manifest.json` is absent), a file named `blob` in the
   Zstandard archive will be used
3. If 1 & 2 fail then the import will fail.

If the package contains any other files or directories it will not be accepted
for processing.

### `manifest.json` schema for uploads

The `manifest.json` file provided in an upload needs to be different to the one
housed in a `vault` as the user uploading the data will not have the ability to
provide all of the required information. As such, an attachment can be
accompanied with no `manifest.json` (the vault subsystem will generate it based
on the file) or a `manifest.json` that provides minimal-to-most metadata.

A minimal `manifest.json` may just have the file name (`originalName`) to
indicate which file is being attached and a `schemaVersion`:

```jsonc
{
  "schemaVersion": 1,
  "originalName": "photo.jpg",
}
```

Note: The minimalist `manifest.json` could just feature the `schemaVersion`
property but that, essentially, is pointless. Provided that the upload package
contains a file named `blob` in the correct location (e.g. `vault/photo/blob`),
the rest can be generated by the vault subsystem.

The schema provided below ("KMDB Vault Manifest - Upload") is based on the one
previously mentioned ("KMDB Vault Manifest"). It is provided here for guidance
regarding the properties within the manifest. Note that kmdb does not currently
support the use of JSON schema - the schema below is used to describe the
structure:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://kmdb.io/schemas/vault-manifest-upload.schema.json",
  "title": "KMDB Vault Manifest - Upload",
  "description": "Metadata for files uploaded to the kmdb_vault system.",
  "type": "object",
  "required": ["schemaVersion", "originalName"],
  "properties": {
    "schemaVersion": {
      "type": "string",
      "description": "The version of the manifest format.",
      "const": "1"
    },
    "sha256": {
      "type": "string",
      "pattern": "^[a-fA-F0-9]{64}$",
      "description": "Hex-encoded SHA-256 hash of the file. If provided, the uploaded file's SHA256 hash will be compared. If there is a mismatch the upload is rejected. If not provided the SHA256 hash will be calculated on your behalf."
    },
    "crc32c": {
      "type": "string",
      "pattern": "^[a-fA-F0-9]{8}$",
      "description": "Hex-encoded CRC32C checksum of the file. If provided, the uploaded file's CRC32C hash will be compared. If there is a mismatch the upload is rejected. If not provided the CRC32C hash will be calculated on your behalf."
    },
    "size": {
      "type": "integer",
      "minimum": 0,
      "description": "File size in bytes. This can be determined by the system."
    },
    "mediaType": {
      "type": "string",
      "pattern": "^[a-zA-Z0-9!#$%^&*_\\-+{}\\|'.`~]+/[a-zA-Z0-9!#$%^&*_\\-+{}\\|'.`~]+$",
      "description": "The MIME type of the file. This can be determined by the system. If the media type provided here does not match the media type of the file (as determined by the system) the upload is rejected."
    },
    "originalName": {
      "type": "string",
      "minLength": 1,
      "description": "The original file name. If provided then a file with this name is expected to also exist in the upload, otherwise the upload is rejected."
    }
  }
}
```

Based on such information:

- If the `version` is anything but "1", fail
- If `sha256` is provided, match it against the SHA256 generated for the file -
  if they don't match, fail
- If `crc32c` is provided, match it against the CRC32C generated for the file -
  if they don't match, fail
- If `size` is provided, match it against the calaculated file size up the
  uploaded file - if they don't match, fail
- If `mediaType` is provided, match it against the Media Type determined by the
  vault subsystem - if they don't match, fail
- If `originalName` is provided, the sub-directory must have a file that matches
  that file name _exactly_ (case senstive). If such a file doesn't exist, fail.

Processes such as export and backup must produce a `manifest.json` file that
adheres to the schema defined as "KMDB Vault Manifest".

### CLI

The `insert` command already has an existing `--file` parameter to allow for
uploading the JSON document and the intent is to not overload this through the
use of a check to see if the value of `--file` points to a JSON or Zstandard
file. Instead, an `--import` parameter will be added to the `insert` command to
allow the user to provide the location of the Zstandard package to be inserted.
If `--import` is provided then `--value` and `--file` are ignored.

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

#### Backups and restores

Databases using the vault will cause backups (dumps) to be more than a simple
output of JSON records.

Presently, the backup facility produces a single output that lists all
documents, using a comment line to indicate the collection:

```json
# collection: notes
{"note":"hello","_id":"019d841000a170f195a41ee863e5aad8"}
```

A full backup of a database that utilises vault storage will need to generate a
Zstandard archive that contains:

- A `documents.bak` file containing the document data currently produced by the
  backup process
- A `vault` directory that contains a copy of the database's vault.

The backup process will make no attempt to resolve "stubs" - only files
currently on the local device will be included in the backup archive.

A `--vault` flag will indicate that the backup output should include vault
objects. By default, the backup process will be purely a backup of the documents
in the database, producing the list of documents to a file or STDOUT.

#### Exports and imports

Much like backups, exports (which are specific to a collection) presently
produces a series of JSON documents, 1-per line (NDJSON):

```json
{ "note": "hello", "_id": "019d841000a170f195a41ee863e5aad8" }
```

The approach to exports will be similar to backups - producing a Zstandard
archive that contains:

- A `documents.ndjson` file containing the document data currently produced by
  the export process
- A `vault` directory that contains a copy of the database's vault, including
  only the objects referenced from that collection

The vault aspect of an export is significantly more expensive than a backup as
each document must be scanned and inspected for any value that points to a vault
object.

By default, exports will not include the vault data and will operate as it does
now: producing an output that consists of a list of documents to a file or
STDOUT

A `--vault` flag will indicate that the export output should not include any
vault objects - it is a conscious request for the effort of collecting the vault
objects for the export archive.

The export process will make no attempt to resolve "stubs" - only files
currently on the local device will be included in the export archive.

### Get, queries and scans

The CLI operations `get`, `search`, `scan` will return results as they currently
do, displaying the vault links as appropriate but making no effort to resolve or
otherwise provide the file object to the user.

A `vault` command will be added to the CLI to allow users to access vault files.
A single sub-command `get` will accept the URI for the vault object:

```sh
kmdb mydb vault get kmdb-vault://sha256/dd92c2600e28b5f44e9c7de81a629e1dd4cfd2eff61a68ddb53777357d3414b8
```

The CLI will access the object (downloading it if there is only a stub) and
stream the output to the user. Use of the `--output` global parameter will allow
the user to elect that the object be saved to the designated output file.

## 6. Storage Workflow

1. **Write Blob:** Stream to vault.
1. **Write Manifest:** Finalize metadata file.
1. **Update DB:** Increment Ref-Count and map logical names to the Vault Path.

## 7. Open Questions

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

### Query Layer Integration questions

> **[Review — missing section]:** The proposal is mostly silent on how the vault
> integrates with the Query Layer (§13). Critical questions:
>
> **Typed codec integration:** A `KmdbCodec<T>` encodes a
> `Map<String, dynamic>`. If a document field contains a `kmdb-vault://` URI,
> the typed model likely needs a wrapper type (e.g. `VaultRef`) rather than a
> raw string. How does `KmdbCodec<T>` express this? Does the Query Layer need to
> understand `VaultRef`, or is it opaque to it?

The `VaultRef` wrapper will be used where the value of a field is a valid vault
URI. The wrapper will provide:

- a `toString` implementation that displays the URI
- a `get` method to obtain the file object
- a `get` method to obtain the metadata (`manifest.json`)

Note that `VaultRef` is immutable - no changes are allowed to the instance.

> **Secondary indexes on vault fields:** If a document field containing a vault
> URI is indexed, the index entry would be the URI string — useful for "find all
> documents referencing this vault object" but not for querying the file's
> metadata. Is that sufficient?

It is sufficient for the index entry to be the URI string.

> **`watch()` and hydration:** If a user `watch()`es a collection and a vault
> field transitions from stub to hydrated, should the stream emit a new event?
> Or is vault hydration invisible to the query layer?

Hydration is invisible to the query layer

> **Count and `any()`:** Queries like `count()` and `any()` do not access blob
> data. Vault stubs should not block these operations.

## 8. Future work

### Encryption at Rest

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

Encryption at rest is out of scope for this proposal.

### Compression Policy

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

Vault will not provide compression features for files stored in the vault.

### Web platform

The web platform is out of scope for this proposal.

The web platform uses OPFS (Origin Private File System) which supports directory
operations but has different performance characteristics than native IO.
Streaming a large file from a remote into OPFS staging needs explicit handling —
the same approach used on native (dart:io) won't work on web (dart:js_interop).
This needs a conditional platform export similar to the existing platform layer
(§19).
