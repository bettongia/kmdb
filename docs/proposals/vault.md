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

The object store would serve the following scenarios:

1. Primary usage: The user wishes to attach files to a record (much like a BLOB
   field in an RDBMS). Storage of files in the storage engine is unlikely to be
   an effective approach.
2. Secondary usage: The user submits a very large JSON document. The database
   may choose to store the whole document in the object store rather than in the
   KV Store. Alternatively, if one or more specific object properties are very
   large (e.g. a field named "full-text" may have a full copy of a large
   text-based media such as a book) it might be possible to just store those
   larger fields.

> **[Review]:** The secondary usage (auto-promoting large fields to vault) is a
> substantially more complex feature than the primary usage, with significant
> Query Layer implications (see §10). Consider scoping a v1 to primary usage
> only and treating secondary usage as a follow-on feature. Mixing both in the
> same proposal makes it hard to reason about the scope of work.

> **[Review]:** The proposal doesn't address the local directory layout. Where
> does `vault/` sit in relation to the existing `sst/`, `local/`, `MANIFEST-*`
> files? Propose:
>
> ```
> {local-db-dir}/
>   ...
>   vault/
>     blobs/
>       sha256/
>         5e/88/5e884898.../
>           manifest.json
>           obj/
>             hello.txt
> ```
>
> Confirm whether the vault lives _inside_ the database directory or alongside
> it.

Response: The vault lives inside the database directory - you are correct with
the example directory tree.

## 2. The Vault Model (Storage Layout)

### 2.1 Content-Addressable Identity

Files are identified by **SHA-256**.

Verification uses the **ISS Pattern** (Identity-Size-Secondary):

1. **Primary Hash:** SHA-256
2. **File Size:** Exact byte count.
3. **Secondary Hash:** ~~MD5~~ CRC32C (stored in sidecar).

> **[Review]:** MD5 is cryptographically broken and collisions can be
> constructed deliberately. For a secondary integrity check (not
> authentication), consider replacing MD5 with **CRC32C** (hardware-accelerated,
> collision-resistant for accidental corruption) or **BLAKE3** (fast, secure).
> MD5 was relevant in the 2000s but introduces a known-weak primitive into the
> integrity model.

Response: Agreed, let's use CRC32C

The approach here will allow for de-duplication in the vault as the same file
won't be stored multiple times.

> **[Review]:** De-duplication is cross-collection and cross-document. Two
> documents attaching the same file share one vault object. This has privacy
> implications in a multi-user scenario, but for a local-first, single-user
> database this is fine. Document this assumption explicitly so it doesn't
> surprise future multi-tenancy work.

Response: agreed, the single-user model is at the heart of the architecture.

### 2.2 Directory Sharding

**Structure:** `blobs/sha256/{prefix1}/{prefix2}/{full_hash}/`

**Example:** `blobs/sha256/5e/88/4898.../`

> **[Review]:** The `{full_hash}` segment — is this the full 64-character hex
> digest, or is it the remaining 60 characters after the two 2-character
> prefixes? Common practice (e.g. Git) uses 2-char prefix + remaining chars.
> Clarify.

Response: go with the common practice

> **[Review]:** What's the directory entry limit that this sharding is designed
> to avoid? Most modern filesystems handle tens of thousands of entries per
> directory without issue, so two levels of sharding (256 × 256 = 65,536 leaf
> slots) may be over-engineered for a local-first database. A single 2-char
> prefix (256 buckets) is likely sufficient and simpler.

> **[Follow-up]:** No response yet. Recommend dropping to a single 2-char
> prefix for v1 (`blobs/sha256/5e/5e884898.../`). The structure can be
> deepened later without breaking existing vaults — the vault path is stored
> in `manifest.json` and the KV store, so a migration tool can be written if
> needed. Fewer directory levels also means fewer syscalls on every read.

### 2.3 Package Encapsulation

Each object (file) is stored in the directory (as per 2.2), in the following
manner:

- `manifest.json`: Technical metadata (Original names, timestamps, second-hash,
  media type).
- `obj/`: Subdirectory for the binary blob (the file).
  - `<filename.ext>`: The actual data/file.

> **[Review]:** Why the `obj/` indirection? The hash directory already
> unambiguously identifies the content. Storing the file directly in the hash
> directory as `<filename.ext>` simplifies reads and avoids an extra directory
> traversal. The `obj/` wrapper would only be useful if multiple blobs per
> manifest were supported — is that intended?

Response: because we don't want to clash file names with something the user
uploaded (e.g. if the uploaded file is named `manifest.json`). The user may
"insert" multiple files but the vault would store 1 file per directory (i.e.
`sha256/5e/....../obj/mydoc.pdf` - there would be no other file in that
directory). I'm open to other ideas here.

> **[Follow-up]:** The naming clash problem can be solved without `obj/` by
> storing the blob under a **fixed internal name** (e.g. `blob`) rather than
> the original filename. The original name is already in `manifest.json`
> (`originalName` field) — it doesn't need to be in the path. This gives:
>
> ```
> sha256/5e/5e884898.../
>   manifest.json
>   blob              ← always this name, regardless of what the user uploaded
> ```
>
> Benefits: no extra directory level, no clash possible, the read path always
> knows the blob filename without listing the directory. The stub state (§4.2)
> also becomes trivially detectable: `blob` absent = not yet hydrated.
> Worth deciding between `obj/<originalName>` and `blob` before the schema
> is finalised.

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

> **[Review]:** The `manifest.json` schema is never defined. Propose a concrete
> schema before implementation begins — it is the contract between the write
> path, the GC sweep, and the sync protocol. A starting point:

```jsonc
{
  "schemaVersion": 1,
  "sha256": "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8",
  "size": 12345,
  "crc32c": "a1b2c3d4", // secondary hash (replacing MD5)
  "mediaType": "image/jpeg", // from magic-number detection
  "originalName": "photo.jpg", // the name at upload time
  "createdAt": "2026-04-08T...", // HLC or ISO-8601?
  "status": "referenced", // "referenced" | "unreferenced"
  "unreferencedAt": null, // ISO-8601 timestamp when status became unreferenced
  "pinnedBy": [], // list of device IDs that have pinned this object
}
```

Response: that's a good start - I agree, we need to keep thinking on this.

> Questions: Should `createdAt` use HLC (consistent with the rest of KMDB) or
> wall-clock ISO-8601? How does `pinnedBy` interact with the GC grace period —
> does a pin indefinitely block deletion or just extend the grace period?

Response: I like your idea of the HLC as it matches the approach to syncing

> **[Follow-up — HLC source]:** `manifest.json` is written by the vault
> subsystem, which lives outside the KV store. The HLC clock lives inside
> `LsmEngine`. The vault writer will need a way to read the current HLC at
> write time — either by being passed the clock value from the caller, or by
> reading it from the KV store after the fact. Passing the HLC at call time is
> cleaner. Define this in the vault write API (§7).
>
> **[Follow-up — `pinnedBy` semantics]:** Still unresolved: does a pin
> **indefinitely block** deletion, or does it just extend the grace period?
> Recommendation: a pin blocks deletion entirely until explicitly removed by
> the pinning device. This matches the "Make Available Offline" UX — the user
> has made an explicit promise about this file. An extending-grace-period
> model would silently delete something the user pinned if the grace period
> expired while offline.

## 3. Deletion & Maintenance

### 3.1 Asynchronous Sweep Logic

1. **Reference Counting:** kmdb will know of active links to hashes (objects,
   files) through a scan of documents in the database.
2. **Tombstoning:** Zero-ref hashes will be marked as `Unreferenced` in their
   `manifest.json`.
3. **Grace Period:** Configurable (e.g., 30 days) before actual deletion.
4. **Compaction Thread:** Background process verifies "Safe-to-Kill" and purges
   the directory storing the file and `manifest.json`.

> **[Review]:** "A scan of documents" is expensive. What's the scan strategy?
> Options to consider:
>
> - **Full scan:** Walk every document in the KV store looking for
>   `kmdb-vault://` URIs. Cost is O(total documents). How often does this run?
> - **Write-time reference tracking:** Maintain a reference count in a separate
>   `$vault` system namespace, incremented/decremented at write time (similar to
>   how `$index` works). Cheaper GC but requires correctness during crash
>   recovery.
>
> The write-time approach is more consistent with how KMDB already maintains
> `$index` and `$cache` namespaces, and avoids periodic O(n) full scans.

> **[Follow-up — recommend $vault namespace]:** No response yet.
> Strongly recommend the write-time `$vault` approach. The mechanics are
> well-understood from how `$index` works: the Query Layer intercepts every
> `put`/`delete` via `writeBatchInternal`, diffs the old and new document's
> vault URIs, and adjusts counters atomically in the same `WriteBatch`. Zero
> extra I/O on reads; GC sweep is a cheap scan of `$vault:*` for zero-valued
> entries. Crash safety comes for free — the counter and the document land in
> the same WAL record and are replayed together.

> **[Review]:** Mutating `manifest.json` in-place to set
> `status = "unreferenced"` breaks the "file creation is the atomic primitive"
> design principle from the sync protocol (§12). How does an in-place manifest
> mutation sync correctly to other devices? Consider an append-only tombstone
> file alongside the manifest rather than mutating it.

> **[Follow-up — tombstone file]:** A concrete approach that avoids manifest
> mutation: when a vault object reaches zero references, create a
> `tombstone.json` alongside `manifest.json`. Its presence (not its content)
> signals unreferenced state. This is a pure file creation — atomic, and
> consistent with the sync design principle. The GC sweep deletes the entire
> hash directory only when `tombstone.json` is older than the grace period. To
> un-tombstone (a new document references the hash), simply delete
> `tombstone.json`. This also gives sync a clean signal: uploading
> `tombstone.json` to the sync folder tells peer devices this object is GC
> candidates on their side too.

> **[Review]:** The grace period countdown — where is the `unreferencedAt`
> timestamp persisted? In `manifest.json` (which requires mutation) or in a
> separate file? What happens if the device is offline for longer than the grace
> period and then comes back online? Is there a risk of a file being deleted on
> one device while another device is still referencing it?

> **[Follow-up — offline grace period]:** With the `tombstone.json` approach
> above, `unreferencedAt` lives in `tombstone.json` (written once, never
> mutated). The offline deletion risk is real but manageable: the $vault
> reference counter in the KV store is the authoritative source. Before the GC
> sweep deletes a directory it should re-verify the counter is still zero — not
> just check the tombstone age. A device coming back online after a long
> absence would sync new documents first, which increments counters; the GC
> sweep running afterwards would then skip any object whose counter had been
> restored.

### 3.2 Atomicity and Crash Safety

> **[Review — missing section]:** The 4-step write workflow in §6 (Write Blob →
> Write Sidecar → Write Manifest → Update DB) has no atomicity guarantee across
> steps. Failure scenarios to address:
>
> - Crash after blob is written but before `manifest.json` is created: orphaned
>   blob with no manifest.
> - Crash after `manifest.json` is written but before the KV Store is updated:
>   vault object exists with no document referencing it (immediately
>   zero-reference).
> - Crash after the KV store is updated but the document points to a vault path
>   whose blob is corrupt or incomplete.
>
> Proposed ordering that minimises risk:
>
> 1. Write blob to a staging path (e.g. `vault/staging/{uuid}`)
> 2. Verify hash
> 3. Rename/move to final path (atomic on local filesystems)
> 4. Write `manifest.json`
> 5. Update KV Store
>
> On open/recovery, any orphaned staging files and any vault paths with a
> manifest but no corresponding KV reference should be swept. This is analogous
> to how WAL replay and orphan SSTable deletion work today (§17).

## 4. Distributed Sync & Lazy Hydration

### 4.1 Metadata-First Replication

kmdb replicates asynchronously for instant search/visibility of the document
record but the file may take time to be replicated. The system will be
eventually consistent.

> **[Review]:** The existing sync protocol (§12) is SSTable-based. Vault objects
> are not SSTables and cannot travel through the existing `sstables/` sync
> folder. This section needs to define a vault sync folder structure, analogous
> to:
>
> ```
> {sync-root}/
>   vault/
>     blobs/
>       sha256/
>         5e/88/{full_hash}/
>           manifest.json
>           obj/
>             photo.jpg
> ```
>
> Key questions: Does each device upload its own vault objects (like SSTables)?
> Or is there a single shared vault in the sync folder that all devices write
> to? How does the `.hwm` mechanism extend to vault objects — does a device need
> to track which vault objects it has downloaded, separately from its SSTable
> high-water mark?

> **[Follow-up — vault sync is simpler than SSTable sync]:** No response yet.
> Unlike SSTables (which are device-scoped and never shared), vault objects are
> content-addressed and identical across all devices. This means a **single
> shared vault directory** in the sync folder makes sense — any device can
> write a vault object and all devices read from the same path. There are no
> conflicts because two devices writing the same SHA-256 produce identical
> bytes.
>
> The `.hwm` mechanism does not extend to vault objects. A device knows whether
> it has a vault object locally by checking whether `blob` (or `obj/<name>`)
> exists in the local hash directory. No separate progress tracking is needed.
>
> The `CloudAdapter` interface will need two new methods: `uploadVaultObject`
> and `downloadVaultObject`. These are simpler than SSTable sync — no HLC
> ordering, no high-water marks, just existence checks and file transfer.

### 4.2 On-Demand Hydration (Stubs)

Devices will store "Stubs" (Metadata only) unless the user configures the system
to download all vault objects.

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

> **[Review]:** A "Stub" on disk — what does it look like? Options:
>
> - The hash directory exists with `manifest.json` only (no `obj/`).
> - A sentinel file (e.g. `obj/.stub`) signals the blob is not local.
> - The hash directory is absent entirely and the manifest is only in the sync
>   folder.
>
> The representation affects how `VaultStore.get()` distinguishes "not
> downloaded yet" from "never existed". Define this clearly.

> **[Follow-up — recommend manifest-only stub]:** If the `blob` fixed-name
> approach is adopted (see §2.3 follow-up), the stub state resolves cleanly:
>
> - Hash directory + `manifest.json` + `blob` → **fully hydrated**
> - Hash directory + `manifest.json` only → **stub** (known to exist, not
>   downloaded)
> - Hash directory absent → **unknown** (not yet seen by this device)
>
> `VaultStore.get()` checks for `blob` presence; if absent and a sync remote
> is configured, it triggers on-demand hydration. This requires no sentinel
> file and falls out naturally from the staged write approach in §3.2 (a
> crashed write leaves `manifest.json` without `blob`, which is exactly the
> stub state — recovery just cleans up the staging directory).

> **[Review]:** Web/OPFS consideration: The web platform uses OPFS (Origin
> Private File System) which supports directory operations but has different
> performance characteristics than native IO. Streaming a large file from a
> remote into OPFS staging needs explicit handling — the same approach used on
> native (dart:io) won't work on web (dart:js_interop). This needs a conditional
> platform export similar to the existing platform layer (§19).

## 5. Import/Export

### 5.1 The Manifest Standard

Uses **Frictionless Data Package** (JSON + ZIP) for transfers.

> **[Review]:** Frictionless Data Package is designed primarily for tabular data
> (CSV, JSON Tables). Evaluate whether it is genuinely suited for binary blob
> transfer or whether a simpler ZIP-with-manifest approach is more appropriate.
> If Frictionless is retained, justify why and link to the specific profile
> being used. If it's just a ZIP of documents + blob files + a JSON index, name
> it as that directly.

## 6. Storage Workflow

1. **Write Blob:** Stream to vault.
2. **Write Sidecar:** Persist technical metadata.
3. **Write Manifest:** Finalize publication metadata.
4. **Update DB:** Increment Ref-Count and map logical names to the Vault Path.

> **[Review]:** Steps 2 and 3 both sound like writing metadata — what's the
> distinction between "sidecar" and "manifest"? The earlier sections only
> mention `manifest.json`. Clarify whether there are one or two metadata files,
> and rename accordingly.

> **[Review]:** "Increment Ref-Count" — where is the ref count stored? In
> `manifest.json` (requiring mutation) or in the KV store (e.g. `$vault` system
> namespace)? This needs to be consistent with the approach chosen in §3.1.

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

2. **Reference counting strategy:** Write-time `$vault` namespace is
   recommended (see §3.1 follow-up). Confirm.

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
