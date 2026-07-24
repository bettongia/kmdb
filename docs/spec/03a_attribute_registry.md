# The attribute registry {.unnumbered}

This section is the single **authoritative, code-anchored home** for KMDB's
cross-cutting *attributes* — `$meta` entries, `device_id`, and the like: where
each is stored, whether it is device-local or replicated, whether it is
encrypted, how it is exercised from the CLI, and its `file:symbol` code
coordinates.

It exists because the alternative — describing each fact wherever it happens to
come up — drifts. The 2026-07-18 review repeatedly found the same design fact
stated in several sections, stale in some and authoritative in none.

**How to use it.** Every section that mentions an attribute links *into* its
entry here rather than re-describing its storage/sync/encryption facts; each
entry links back *out* to the sections that define or consume it. A reader lands
on the attribute from wherever they were; an agent resolving "where does
`device_id` live and is it synced?" has one place to look, anchored to code it
can verify rather than prose it must trust.

For the entry template, the granularity rule, and the maintenance discipline,
see the [spec-authoring guide](README.md). Two conventions matter while reading:

- **`⚠ today → target`** marks an attribute whose storage is *mid-change* (a work
  item is moving it): the row shows both its current and target state. The `⚠` is
  dropped when the moving work item lands.
- The **glossary (§99)** stays the first stop for *vocabulary* ("what does this
  term mean"); this registry owns the *implementation facts*. Glossary entries for
  registry attributes link in here.

## The `$meta` register

Every `$meta` entry family. `$meta` is a system namespace that **replicates**
(it is single-`$`, uploaded in regular SSTables); a device-local fact stored
there is a latent bug, which is why several rows below were moved to `$$`
local-only namespaces (`isLocalOnly` matches `$$` only; those land in
`.local.sst` and never upload). "Encrypted" is whether the stored value is
`EncryptionEnvelope`-wrapped on an encrypted database. Every `$meta` value is
wrapped **except two bootstrap exemptions** — `enc:blob` and `formatVersion` —
which must be readable before the DEK is available and so are stored raw.

| Attribute | Kind | Scope | Storage | Encrypted | Detail |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `device_id` | Identifier | Device-local (authoritative); an inert `$meta` copy still syncs | `DEVICE_ID` file (db root, never synced) **+** legacy `$meta` copy — `⚠` WI-12 retires the copy | File: No · `$meta`: yes | **[full entry](#device_id)** |
| `index:{ns}:{path}` | Secondary-index state | Device-local | **`$$indexstate`** (local-only) | Yes | WI-11 |
| `fts:{ns}:{field}` | FTS index state | Device-local | **`$$ftsstate`** (local-only) | Yes | WI-11 |
| `vec:{ns}:{field}` | Vec index state | Device-local | **`$$vecstate`** (local-only) | Yes | WI-11 |
| `gc:tombstoneFloor` | Watermark (HLC) | Device-local | **`$$gcstate`** (local-only) | Yes | **[full entry](#gctombstonefloor)** |
| `gen:{ns}` | Generation counter | **Undecided** `⚠` | `$meta` — `⚠` classification pending WI-13 | Yes | WI-13 |
| `dirty` | Dirty-open flag | Device-local `⚠` (currently syncs) | `$meta` — `⚠` WI-14 moves it to `$$` | Yes | WI-14 |
| `enc:blob` | Key material (wrapped DEK) | Replicated | `$meta` | **No — raw CBOR** (one of two bootstrap exemptions; must be read before the DEK exists) | summary |
| `schema:{collection}` + `schema:__registry__` | Schema contract | Replicated | `$meta` | Yes | summary |
| `version:config:{collection}` | Retention policy | Replicated | `$meta` | Yes | summary |
| `namespaces` | Namespace registry | Replicated | `$meta` | Yes | summary |
| `formatVersion` | Format-version marker | Replicated | `$meta` | **No — raw** (second bootstrap exemption, same non-circularity reason as `enc:blob`) | summary |

> The four device-local index/floor rows were moved out of `$meta` by
> [WI-11](../roadmap/0_10_01.md) (the SC-10/SC-15 fix); `gen:{ns}` (WI-13),
> `device_id` (WI-12) and `dirty` (WI-14) are the remaining mid-change entries.
> The registry generalises beyond `$meta` — the HLC, the DEK/`EncryptionBlob`,
> and the SSTable filename fields are each families that would get their own
> register in the same shape; this seed scopes to `$meta`, the family most
> recently put under the microscope.

## `device_id`

> The stable per-installation identity of a KMDB client. Names every SSTable
> this device writes and is the device's handle in the sync protocol.

| Field | Value |
| :--- | :--- |
| **Kind** | Identifier (opaque) |
| **Format** | 8-char lowercase hex — truncated UUIDv4 (`DeviceId.load`, `device_id.dart:64`) |
| **Scope** | Device-local. The **authoritative** store is a local file that is never synced; a legacy `$meta` copy *does* replicate but is read **second** and is inert on read (SC-5). |
| **Storage** | **Authoritative:** a plaintext `DEVICE_ID` file in the db root (`{dbDir}/DEVICE_ID`), outside `sst/` → never uploaded. **Legacy:** a `$meta` `device_id` copy, written on first open via the fallback (and on every `reassignDeviceId`); it lands in a syncable `.sst` and replicates, but `ensureDeviceId` prefers the file. `⚠` **WI-12** retires the inert copy. |
| **Encrypted at rest** | **File: No** — plaintext (`id.codeUnits`), read with no DEK. **`$meta` copy:** `EncryptionEnvelope`-wrapped (plaintext only when the DB is unencrypted). |
| **Mutability** | Set once at first launch; changed only by `reassignDeviceId`, which rewrites the `DEVICE_ID` file **and** the `$meta` copy **and** renames every SSTable (the manifest then records the new filenames). |
| **CLI** | `kmdb new-device-id` (see below) |
| **Introduced** | [`plan_deviceid.md`](../plans/completed/plan_deviceid.md) (§04); the `DEVICE_ID` file landed later in `2c6971c` ("Fix device ID corruption when syncing copied databases"). |
| **Status** | 🔧 WI-12 retires the legacy `$meta` copy (low-risk cleanup, before the `0.1.0` freeze) |

**Role.** Two jobs. (1) **Naming:** every SSTable is
`{deviceId}-{minHlc}-{maxHlc}.sst`, and the manifest records those filenames —
so `device_id` is load-bearing for the on-disk layout (§08). (2) **Sync
identity:** per-device high-water marks are keyed by it, consolidation fencing is
per-`deviceId`, and `SyncEngine` uses it to *exclude self* when pulling peers.

**Lifecycle.** Resolved on open by `ensureDeviceId` (`kv_store_impl.dart:407`,
surfaced as `KmdbDatabase.ensureDeviceId`, `kmdb_database.dart:781`): read the
`DEVICE_ID` file **first**; if absent, fall back to `DeviceId.load`
(`device_id.dart:53` — reads the `$meta` copy, or generates a fresh UUIDv4 and
writes it to `$meta`); then write the file so subsequent opens skip `$meta`. An
un-`ensure`d store reports the `'00000000'` **open-time param default**
(`kv_store_impl.dart:120`) — distinct from a resolved identity, and not what
`DeviceId.load` returns.

**CLI.** `kmdb new-device-id` mints a fresh identity for a **copied** database —
two copies sharing a `device_id` would write colliding SSTable filenames and
clobber each other's high-water marks in a shared sync folder. It calls
`reassignDeviceId`, which rewrites **both** the `DEVICE_ID` file and the `$meta`
copy and renames the SSTables; if remotes are configured it warns on stderr to
delete the stale `highwater/{oldDeviceId}.hwm`. Emits
`{"oldDeviceId":…, "newDeviceId":…}` — an integrator can exercise the attribute
without touching Dart.

**Tensions.**

- **SC-5's bite is smaller than "it syncs" implies.** The authoritative identity
  is the local file; the synced `$meta` copy is **inert on read** (every device
  prefers its own file). SC-5's real exposure is **hygiene/confidentiality** — the
  copy leaks each peer's `device_id` into the sync folder and is dead weight — not
  a wrong-identity correctness bug. WI-12 = stop writing it.
- **§08's rationale is substantially already honoured.** §08 says `device_id`
  "must not be stored inside the database itself to avoid circular dependency
  during bootstrap" — the `DEVICE_ID` file is outside `sst/`, so there is no
  bootstrap circularity and no DEK dependency. §08's "platform secure storage
  (Keychain…)" is a stronger, still-unbuilt form; `device_id.dart:37-39`'s "for
  now `$meta` is the sole persistence mechanism" is now **stale** (the file
  superseded it) — a spec-vs-code correction tracked by WI-2.
- **The encryption tension is moot on the primary path.** The file is plaintext,
  read with no DEK; only the `$meta` fallback is wrapped.

**Code coordinates.** *(Verify by symbol, not line.)*

| Concern | Location |
| :--- | :--- |
| Resolve on open (file-first) | `kv_store_impl.dart:407` (`ensureDeviceId`), surfaced `kmdb_database.dart:781` |
| The `DEVICE_ID` file | `kv_store_impl.dart:439` (`kDeviceIdFilename`) |
| `$meta` fallback + generation | `device_id.dart:53` (`DeviceId.load`), `:64` (UUIDv4) |
| `$meta` read / write / key | `meta_store.dart:207` (`getDeviceId`), `:217` (`putDeviceId`), `:204` (`deviceIdKey`) — both `EncryptionEnvelope`-wrapped |
| Stale "sole persistence" note | `device_id.dart:37-39` |
| Reassign (file + `$meta` + SSTable rename) | `lsm_engine.dart:1428` (`reassignDeviceId`), `kv_store_impl.dart:326` |
| `'00000000'` open-time default | `kv_store_impl.dart:120`, `kmdb_database.dart:303` |
| CLI | `new_device_id_command.dart:47` (`NewDeviceIdCommand`) |
| Consumed — SSTable naming / manifest | §08 (`{deviceId}-…`), manifest `add.filename` |
| Consumed — sync | `sync_engine.dart:365` (exclude self), `highwater.dart:270` |

**Spec cross-refs.** §04 (identity — definitional home), §08 (SSTable naming),
§12 (sync).

## `gc:tombstoneFloor`

> The highest HLC horizon at which *this device* has already garbage-collected
> (GC'd) tombstones. A recipient-side guard that stops already-collected
> deletions from being resurrected by an incoming SSTable.

| Field | Value |
| :--- | :--- |
| **Kind** | Monotonic watermark (HLC) |
| **Format** | 64-bit HLC, big-endian uint64 (physical + logical) |
| **Scope** | Device-local |
| **Storage** | `$$gcstate` (`MetaStore.kGcStateNamespace`) — local-only, lands in `.local.sst`, never uploaded. |
| **Encrypted at rest** | Yes, when the DB is encrypted — `EncryptionEnvelope`-wrapped in `setTombstoneFloor`/`getTombstoneFloor`. |
| **Mutability** | Monotonic — only ever raised (`max`), never lowered, under correct operation. |
| **CLI** | None — managed automatically by compaction/ingest (no integrator-facing surface). |
| **Introduced** | [`plan_tombstone_gc_ingest_floor.md`](../plans/completed/plan_tombstone_gc_ingest_floor.md) (H4-FU3, durability hardening v0.02.01); moved to `$$gcstate` by [WI-11](../plans/completed/plan_0_10_01_index_predicate_trust.md). |
| **Status** | Stable |

**Role.** After a compaction drops at least one tombstone at horizon *H*, the
floor advances to *H*. On ingest, `LsmEngine.ingestAt0` rejects any incoming
SSTable whose `maxHlc <= floor` with `StaleSstableIngestException` — the file
covers an HLC range this device has already collected, so re-ingesting it would
resurrect deleted rows. It is a defence-in-depth backstop to the sync horizon.

**Lifecycle.** Absent on a fresh DB → `getTombstoneFloor` returns `Hlc(0,0)`
(accepts everything). Raised by `setTombstoneFloor` after each tombstone-dropping
`_compactAll`. Reset only by the explicit `resetTombstoneFloor` path.

**History.** The floor is device-local by design but originally lived in synced
`$meta` — a latent bug (finding Q-D). Because `$meta` is Last-Write-Wins by HLC
and keeps the *most-recent* write rather than the *maximum* floor, a peer's
later-HLC write could **lower** this device's floor, re-opening the exact
tombstone-resurrection window the floor exists to close. WI-11 moved it to the
local-only `$$gcstate`, making that structurally impossible (the value never
leaves the device, so no peer can overwrite it).

**Code coordinates.**

| Concern | Location |
| :--- | :--- |
| Namespace | `meta_store.dart:361` (`kGcStateNamespace` = `$$gcstate`) |
| Read / write | `meta_store.dart:397` (`getTombstoneFloor`), `:423` (`setTombstoneFloor`) |
| Enforced (ingest guard) | `LsmEngine.ingestAt0` — rejects `maxHlc <= floor` |
| Advanced | `LsmEngine._compactAll` (after a tombstone-dropping compaction) |
| Reset | `kv_store_impl.dart:371` (`resetTombstoneFloor`) |

**Spec cross-refs.** §06 (compaction & the floor), §12 (sync horizon).
