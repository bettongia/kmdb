# §29 Google Drive Adapter

The `kmdb_google_drive` package provides `GoogleDriveAdapter`, a
`SyncStorageAdapter` implementation backed by the Google Drive REST API (v3).
It enables zero-infrastructure sync for users with a Google account.

## Package placement

`GoogleDriveAdapter` lives in `packages/kmdb_google_drive/`, a separate pub
workspace member — **not** under `packages/kmdb/lib/src/sync/cloud/` as the
0_03 roadmap draft proposed.  The Drive adapter pulls in `googleapis`,
`googleapis_auth`, and `http` (>3 MB of generated code); these heavy OAuth
dependencies must not enter the core `kmdb` library.  The established
`betto_zstd` / `betto_onnxrt` pattern of a separate package with
optional inclusion is the right model here.

## Authentication

The adapter is **auth-agnostic**: it accepts a pre-built `AuthClient` (from
`package:googleapis_auth`) and never manages the OAuth lifecycle itself.
Callers own credential acquisition:

- **CLI** — `GoogleDriveAuthHelper.fromUserConsent` runs the local-server
  OAuth redirect flow (opens a browser, captures the callback on `localhost`),
  then persists the resulting `AccessCredentials` to
  `{dbDir}/local/google_credentials.json`.  Credentials are loaded and
  refreshed automatically by `adapterFor` in `kmdb_cli`.
- **Flutter / mobile / web** — use `google_sign_in` +
  `extension_google_sign_in_as_googleapis_auth` to obtain an `AuthClient` from
  the platform SSO flow, then pass it directly to `GoogleDriveAdapter`.

## Drive scope

The adapter requires the **`drive.file`** scope
(`https://www.googleapis.com/auth/drive.file`).  This scope grants access only
to files that the app itself created or opened, making it the narrowest
sufficient scope for KMDB sync.

The `drive.appdata` scope is **not** used.  Any future decision to move to
`drive.appdata` would be a separate, explicitly-scoped change.

## Sync folder layout

The adapter creates and maintains the following folder hierarchy in the user's
My Drive:

```
{syncRoot}/                   ← top-level Drive folder (created on first use)
  highwater/                  ← subfolder
    {deviceId}.hwm
  sstables/                   ← subfolder
    *.sst
  .consolidation-lease
```

`{syncRoot}` is the value of `GoogleDriveRemoteConfig.syncRoot` (configured at
`remote add` time).

## ETag strategy

Drive exposes an `ETag` HTTP response header on individual file metadata
requests (`GET /drive/v3/files/{id}?alt=json`).  `GoogleDriveAdapter` retrieves
this header via a raw HTTP request and uses it as the opaque ETag token for
`getEtag` and `compareAndSwap`.  The ETag changes on every content update and
is stable for a given content revision.

## Conditional writes (CAS)

Drive's CAS support is split across the two operation types:

| Operation | Method | Atomic? |
|-----------|--------|---------|
| Create a file that may not exist (`ifMatchEtag == null`) | `Files.create` (raw) | **No** |
| Update an existing file by ID (`ifMatchEtag != null`)    | PATCH with `If-Match` | **Yes** |

### Create-if-absent: non-atomic

Drive identifies files by server-assigned ID, not by name, and permits multiple
files with the same name in a folder.  Two concurrent `Files.create` calls with
the same name both succeed, yielding two distinct Drive files.  There is no
`If-None-Match: *`-style exclusive-create for name-keyed files.

`GoogleDriveAdapter.providesAtomicCas` therefore returns **`false`**.
`ConsolidationCoordinator` reads this getter and skips consolidation (H5),
so KMDB accumulates more un-consolidated SSTables rather than risking a
split-lease data-loss event.  This is a loss-free posture.

### Update-if-match: atomic

`Files.update` with `If-Match: <etag>` on a known file ID IS atomic from the
Drive server's perspective: at most one concurrent caller observes success;
others receive `412 Precondition Failed`.  The lease protocol therefore works
correctly once a lease file has been created and its Drive file ID is known.

### Phase 4a probe results

The table below records the observed Drive behaviour that the
`DriveSimulator` encodes.  It was produced by a credential-gated probe using
the H5 contention tests from `runSyncAdapterConformance`.

| Behaviour | Observed |
|-----------|----------|
| Concurrent `Files.create` same name → both succeed | Yes |
| `Files.update` + `If-Match` → only one winner | Yes |
| Read-your-writes consistency | Yes (for issuing client) |
| Other-client propagation delay | Up to ~30 s (conservative estimate) |
| 429 on quota exceeded | Yes (`Retry-After` header present) |

These values are encoded in `kGoogleDriveProfile` (in
`packages/kmdb_google_drive/lib/src/google_drive_profile.dart`).

## Folder ID caching

Folder IDs are cached in memory in a `Map<String, String>` to avoid repeated
`Files.list` calls on every operation.  The cache is keyed by logical path
(e.g. `__folder__:sstables`).

### Duplicate-name resolution rule

Because Drive allows duplicate names, when a folder or file lookup returns
multiple same-named items the adapter applies a **deterministic selection
rule**:

> Choose the item with the **oldest `createdTime`**; break ties by the
> **lexicographically-lowest file ID**.

This rule is applied consistently so that different devices operating on the
same remote bind to the same physical Drive object.

## Resumable upload protocol

**All uploads** use Drive's resumable upload protocol regardless of file size
(no size threshold).  This simplifies the implementation (one code path) and is
consistent with Drive best practices for binary content.

If a sync is cancelled mid-upload, the resumable session URI is discarded.
Drive auto-expires abandoned sessions after 7 days.

## Rate limiting and back-off

The adapter retries on HTTP **429** (quota exceeded) and **503** (service
unavailable) using exponential back-off with full jitter
(`RetryConfig.defaultConfig`: up to 5 attempts, initial delay 1 s, max 32 s).
All back-off loops respect a `CancellationToken`; if set, the next sleep
boundary throws `DriveOperationCancelledException`.

## Web / WASM support

`googleapis` and `http` are both web-compatible.  `GoogleDriveAdapter` contains
no `dart:io`.  The CLI-only `GoogleDriveAuthHelper` uses `dart:io` for the
local-server redirect flow and the credentials file; it is **native-only**.
Flutter web callers use `google_sign_in_web` to produce an `AuthClient`
and pass it directly to the adapter — the adapter is unchanged.

## Test infrastructure

### Behavioural Drive simulator

`DriveSimulator` (in `packages/kmdb_google_drive/test/support/`) is a fake
`http.Client` that intercepts all Drive v3 REST calls from `GoogleDriveAdapter`
(both the `googleapis` generated client and raw `AuthClient.send` calls).  It
models:

- `Files.list`, `Files.get`, `Files.create`, `Files.update`, `Files.delete`
- Resumable upload sessions
- Duplicate-name creation (multiple files with the same name succeed)
- Atomic update-if-match (`If-Match` → 412 on mismatch)
- Rate-limit injection (optional)

All production `GoogleDriveAdapter` code runs against the simulator unchanged.

### Conformance suite export

The H5 `runSyncAdapterConformance` suite is exported from
`package:kmdb/test_support.dart` (previously under `test/` only), so
downstream packages can run it.  The three in-package call sites were updated to
import from the new path.

### QuotaAwareAdapter

The `SimulatorQuotaAdapter` (test tree, `kmdb_harness` dependency) wraps
`GoogleDriveAdapter` and implements `kmdb_harness`'s `QuotaAwareAdapter`.  The
production `GoogleDriveAdapter` does **not** implement `QuotaAwareAdapter` —
keeping it free of the harness dependency.

## CLI integration

`GoogleDriveRemoteConfig` (config-only, in core `kmdb`) holds `syncRoot` and
`credentialsPath`.  The CLI's `adapterFor` (now `async`) constructs the
adapter by loading/refreshing credentials from
`{dbDir}/local/{credentialsPath}`.

```
kmdb <db> remote add myremote --type google-drive \
  --folder kmdb-sync \
  --client-id <oauth-client-id> \
  --client-secret <secret>
```

This command runs the local-server OAuth redirect flow and writes credentials
to `{dbDir}/local/google_credentials.json` (never synced).

## Flutter UI integration (separate repo)

`kmdb_ui` (in `https://github.com/bettongia/kmdb-ui`) handles the Drive
integration for Flutter desktop/mobile/web:

1. Add `kmdb_google_drive`, `google_sign_in`, and
   `extension_google_sign_in_as_googleapis_auth` to `kmdb_ui/pubspec.yaml`.
2. Add a "Connect Google Drive" settings screen that calls
   `GoogleSignIn().signIn()`, converts the result to an `AuthClient` via the
   extension package, and calls `SyncEngine` with the resulting
   `GoogleDriveAdapter`.
3. Handle sign-out and revocation.

This work is deferred to the `kmdb_ui` repo and is not tracked here.

## Release checklist items

Two checks that cannot run in automated CI are registered in
`docs/spec/28_release_checklist.md` as **RC-1** and **RC-2**.
