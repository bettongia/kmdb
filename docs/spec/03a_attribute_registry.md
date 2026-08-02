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
| `device_id` | Identifier | Device-local (sole store) | `DEVICE_ID` file (db root, never synced) | File: No | **[full entry](#device_id)** |
| `index:{ns}:{path}` | Secondary-index state | Device-local | **`$$indexstate`** (local-only) | Yes | WI-11 |
| `fts:{ns}:{field}` | FTS index state | Device-local | **`$$ftsstate`** (local-only) | Yes | WI-11 |
| `vec:{ns}:{field}` | Vec index state | Device-local | **`$$vecstate`** (local-only) | Yes | WI-11 |
| `gc:tombstoneFloor` | Watermark (HLC) | Device-local | **`$$gcstate`** (local-only) | Yes | **[full entry](#gctombstonefloor)** |
| `gen:{ns}` | Generation counter | **Undecided** `⚠` | `$meta` — `⚠` classification pending WI-13 | Yes | WI-13 |
| `dirty` | Dirty-open flag | Device-local | **`$$dirtystate`** (local-only) | Yes | WI-14 |
| `enc:blob` | Key material (wrapped DEK) | Replicated | `$meta` | **No — raw CBOR** (one of two bootstrap exemptions; must be read before the DEK exists) | summary |
| `schema:{collection}` + `schema:__registry__` | Schema contract | Replicated | `$meta` | Yes | summary |
| `version:config:{collection}` | Retention policy | Replicated | `$meta` | Yes | summary |
| `namespaces` | Namespace registry | Replicated | `$meta` | Yes | summary |
| `formatVersion` | Format-version marker | Replicated | `$meta` | **No — raw** (second bootstrap exemption, same non-circularity reason as `enc:blob`) | summary |

> The four device-local index/floor rows were moved out of `$meta` by
> [WI-11](../roadmap/0_10_01.md) (the SC-10/SC-15 fix); `device_id` was fully
> retired from `$meta` by WI-12 (this entry); the dirty-open flag was moved to
> `$$dirtystate` by WI-14. `gen:{ns}` (WI-13) is the remaining mid-change
> entry.
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
| **Format** | 8-char lowercase hex — truncated UUIDv4 (`DeviceId.generate`, `device_id.dart`) |
| **Scope** | Device-local. The `DEVICE_ID` file is the **sole** store — `device_id` never touches `$meta` (read or write). |
| **Storage** | A plaintext `DEVICE_ID` file in the db root (`{dbDir}/DEVICE_ID`), outside `sst/` → never uploaded by `SyncEngine`. |
| **Encrypted at rest** | **No** — plaintext (`id.codeUnits`), read with no DEK. |
| **Mutability** | Set once at first launch; changed only by `reassignDeviceId`, which rewrites the `DEVICE_ID` file **and** renames every SSTable (the manifest then records the new filenames). |
| **CLI** | `kmdb new-device-id` (see below) |
| **Introduced** | [`plan_deviceid.md`](../plans/completed/plan_deviceid.md) (§04); the `DEVICE_ID` file landed later in `2c6971c` ("Fix device ID corruption when syncing copied databases"); the `$meta` copy was fully retired by [WI-12](../plans/completed/plan_0_10_01_device_id_meta_retire.md) (SC-5). |
| **Status** | ✅ Complete — WI-12 retired the `$meta` copy entirely (read and write); no legacy fallback remains (greenfield project, no released databases to migrate). |

**Role.** Two jobs. (1) **Naming:** every SSTable is
`{deviceId}-{minHlc}-{maxHlc}.sst`, and the manifest records those filenames —
so `device_id` is load-bearing for the on-disk layout (§08). (2) **Sync
identity:** per-device high-water marks are keyed by it, consolidation fencing is
per-`deviceId`, and `SyncEngine` uses it to *exclude self* when pulling peers.

**Lifecycle.** Resolved on open by `ensureDeviceId` (`kv_store_impl.dart`,
surfaced as `KmdbDatabase.ensureDeviceId`, `kmdb_database.dart`): read the
`DEVICE_ID` file; if absent or invalid, generate a fresh id via
`DeviceId.generate()` (a pure generator with no persistence side effect) and
write it to the file. `$meta` is never consulted — a lost or missing file
always yields a new identity and a one-time SSTable re-upload (identity churn),
which is safer than the removed `$meta` fallback (that fallback could silently
adopt a peer's identity — the SC-5 defect this plan closes). An un-`ensure`d
store reports the `'00000000'` **open-time param default** (`kv_store_impl.dart`)
— distinct from a resolved identity, and not what `DeviceId.generate` returns.
`KvStoreImpl.storeInfo()` reads the **running engine's** `deviceId` directly
(not the file), because the engine's value is what SSTable filenames actually
use in every production path.

**CLI.** `kmdb new-device-id` mints a fresh identity for a **copied** database —
two copies sharing a `device_id` would write colliding SSTable filenames and
clobber each other's high-water marks in a shared sync folder. It calls
`reassignDeviceId`, which rewrites the `DEVICE_ID` file and renames the
SSTables; if remotes are configured it warns on stderr to delete the stale
`highwater/{oldDeviceId}.hwm`. Emits `{"oldDeviceId":…, "newDeviceId":…}` — an
integrator can exercise the attribute without touching Dart.

**Tensions.**

- **SC-5 is fully closed, not just mitigated.** Before WI-12, the authoritative
  identity was the local file but a `$meta` copy also replicated (inert on read,
  since every device preferred its own file) — a hygiene/confidentiality leak,
  not a wrong-identity bug. WI-12 removed the `$meta` path entirely (read *and*
  write), so a device can no longer even theoretically resolve a peer's identity
  via `$meta` Last-Write-Wins.
- **§08's rationale is substantially already honoured.** §08 says `device_id`
  "must not be stored inside the database itself to avoid circular dependency
  during bootstrap" — the `DEVICE_ID` file is outside `sst/`, so there is no
  bootstrap circularity and no DEK dependency. §08's "platform secure storage
  (Keychain…)" is a stronger, still-unbuilt form — tracked separately as a
  spec-vs-code correction by WI-2 (this entry does not speak to Keychain/OPFS
  durability claims; that prose lives in §04/§08).
- **Durability trade-off (documented, not fixed here).** Post-WI-12, the
  identity's durability equals the `DEVICE_ID` file's: a plain file on native
  (survives app updates/normal backup, not a data-clear or
  uninstall-without-restore) or OPFS on web (per-origin, persistent, but cleared
  with site data and evictable under storage pressure absent
  `navigator.storage.persist()`). A lost file yields a fresh id and a one-time
  SSTable re-upload — correct and *safer* than the removed `$meta` fallback, but
  still churn. Durable platform-native storage (Keychain / persistent OPFS) is
  the §08 enhancement that would close this gap; it is a separate, larger
  design (crosses into `kmdb_flutter` and the platform layer) and remains
  out of scope here.

**Code coordinates.** *(Verify by symbol, not line.)*

| Concern | Location |
| :--- | :--- |
| Resolve on open (file-only) | `kv_store_impl.dart` (`ensureDeviceId`), surfaced `kmdb_database.dart` (`ensureDeviceId`) |
| The `DEVICE_ID` file | `kv_store_impl.dart` (`kDeviceIdFilename`) |
| Pure id generator | `device_id.dart` (`DeviceId.generate`) |
| `storeInfo()` resolution (engine, not file) | `kv_store_impl.dart` (`storeInfo`) |
| Reassign (file + SSTable rename) | `lsm_engine.dart` (`reassignDeviceId`), `kv_store_impl.dart` (`reassignDeviceId`) |
| `'00000000'` open-time default | `kv_store_impl.dart` (`open`'s `deviceId` param), `kmdb_database.dart` |
| CLI | `new_device_id_command.dart` (`NewDeviceIdCommand`) |
| Consumed — SSTable naming / manifest | §08 (`{deviceId}-…`), manifest `add.filename` |
| Consumed — sync | `sync_engine.dart` (exclude self), `highwater.dart` |

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
