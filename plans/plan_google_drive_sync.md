# Google Drive sync

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

**Roadmap**: docs/roadmap/0_04.md

## Problem statement

KMDB's sync protocol uses `SyncStorageAdapter` as its cloud backend abstraction.
Today only `LocalDirectoryAdapter` and `MemorySyncAdapter` (tests) exist. This
plan implements a `GoogleDriveAdapter` that talks to the Google Drive REST API,
giving users a zero-infrastructure sync location accessible from any device with
a Google account.

The roadmap entry also references a `GcsAdapter` (Google Cloud Storage). These
are distinct products — Drive is a consumer file store; GCS is an object store.
This plan covers **Google Drive only**. GCS is a separate work item.

## Open questions

- [x] **Package location** — new `packages/kmdb_google_drive` package (mirrors
  `betto_zstd` / `kmdb_tokenizer_icu` pattern). Heavy OAuth dependencies stay
  out of core `kmdb`; consumers opt in explicitly.

- [x] **Authentication approach** — the adapter accepts a pre-built `AuthClient`
  (from `googleapis_auth`) and is auth-agnostic. Callers own the OAuth lifecycle.
  The two reference integrations ship as part of this plan:
  - **`kmdb_cli`** — uses `googleapis_auth` local-server redirect flow (opens
    browser, captures callback on `localhost`); tokens persisted to
    `local/google_credentials.json` (never synced).
  - **`kmdb_ui`** — uses `google_sign_in` +
    `extension_google_sign_in_as_googleapis_auth` to produce an `AuthClient`
    from the platform SSO flow.

- [x] **Folder/app-data scope** — use `drive.file` scope. The adapter will
  create a user-visible folder in Drive. This scope is universally supported
  across all platforms (mobile, desktop, web, CLI).

- [x] **Rate limits and quotas** — the adapter implements exponential back-off
  with jitter on 429 / 503 responses (Drive best practice). Each sync operation
  accepts a `CancellationToken` (or `Duration timeout`); back-off respects the
  token and aborts cleanly if cancelled or if the deadline expires. No silent
  infinite retry.

- [x] **Resumable uploads** — all uploads use Drive's resumable upload protocol
  (simpler to implement uniformly than a size threshold). If the sync is
  cancelled mid-upload the resumable session URI is discarded and the incomplete
  upload is abandoned (Drive auto-expires abandoned sessions after 7 days).

- [x] **Web/WASM support** — no stub needed. `googleapis` and `package:http`
  are both web-compatible; the adapter contains no `dart:io`. CLI credential
  storage (`HttpServer` redirect, token file) lives in `kmdb_cli` only. Flutter
  web uses `google_sign_in_web` to produce an `AuthClient` — the adapter is
  unchanged. The spec will note web as a supported target.

## Investigation

### Existing adapter interface

`SyncStorageAdapter` (in `packages/kmdb/lib/src/sync/sync_storage_adapter.dart`)
defines six methods:

| Method | Notes |
|--------|-------|
| `list(dir, {extension})` | Returns bare filenames only |
| `download(path)` | Returns `null` if file absent |
| `upload(path, bytes)` | Overwrites if exists |
| `delete(path)` | No-op if absent |
| `compareAndSwap(path, bytes, {ifMatchEtag})` | `null` etag = if-none-match:\* |
| `getEtag(path)` | Returns `null` if absent |

All ETags are implementation-specific opaque strings. The lease protocol in
`ConsolidationCoordinator` depends entirely on `compareAndSwap` behaving
atomically from the server's perspective.

### Google Drive REST API capabilities

- **Files.list** — list files in a folder by `parents` query; supports
  `orderBy`, `pageToken`, and `fields` projection.
- **Files.get** (media download) — download file bytes; response includes
  `ETag` header (and Drive's own `md5Checksum` field on metadata).
- **Files.create** (multipart/resumable upload) — create new file; supports
  `If-None-Match: *` to prevent overwriting an existing file.
- **Files.update** (media update) — update existing file bytes; supports
  `If-Match: <etag>` for conditional update.
- **Files.delete** — delete a file by ID.
- Drive ETags are stable per-revision and exposed in `ETag` response headers
  and in the file metadata `headRevisionId`. They are suitable for CAS.

### ETag strategy

Drive file metadata includes `md5Checksum` (content hash) and a server-assigned
`ETag` header on every response. The `ETag` header is the cleanest choice: it
changes on every update, matches what the `If-Match` / `If-None-Match` headers
expect, and mirrors how GCS and S3 work.

### compareAndSwap on Drive

Drive supports conditional requests via standard HTTP headers:
- Create (if-none-match: \*): `Files.create` with `If-None-Match: *`
- Update (if-match: etag): `Files.update` with `If-Match: <etag>`

A 412 Precondition Failed response means ETag mismatch → return `false`.
A 409 Conflict on create means file already exists → return `false`.
These map cleanly to the interface semantics.

### Dart packages

| Package | Purpose |
|---------|---------|
| `googleapis` | Generated Drive v3 client (`DriveApi`) |
| `googleapis_auth` | OAuth2 `AuthClient` factory (device flow, service account) |
| `google_sign_in` | Flutter platform SSO (mobile/desktop/web) |
| `http` | Underlying HTTP client (already a transitive dep via `googleapis`) |

### Sync folder layout (unchanged)

The adapter will mirror the same remote layout the rest of the engine expects:

```
{syncRoot}/               ← a Drive folder created on first use
  highwater/              ← subfolder
    {deviceId}.hwm
  sstables/               ← subfolder
    *.sst
  .consolidation-lease
```

Drive folders are just files with `mimeType=application/vnd.google-apps.folder`.
The adapter will cache folder IDs in memory to avoid repeated metadata lookups.

### Package placement decision

Following the `betto_zstd` / `kmdb_tokenizer_icu` pattern, a new
`packages/kmdb_google_drive` package is the right home. It:
- Keeps heavy OAuth deps out of core `kmdb`
- Allows separate versioning and optional inclusion
- Follows the established workspace convention

## Implementation plan

### Phase 1 — Package scaffold

- [ ] Create `packages/kmdb_google_drive/` with standard layout
  (`lib/`, `test/`, `pubspec.yaml`, `README.md`)
- [ ] Add `googleapis`, `googleapis_auth`, `kmdb` dependencies in pubspec
- [ ] Add `kmdb_google_drive` to root workspace `pubspec.yaml`
- [ ] Add license header to all new Dart source files (use `@header_template.txt`)
- [ ] Add `kmdb_google_drive` entry to `melos.yaml` if one exists

### Phase 2 — Core adapter implementation

- [ ] Implement `GoogleDriveAdapter` in
  `lib/src/google_drive_adapter.dart` implementing `SyncStorageAdapter`
- [ ] Constructor accepts `AuthClient` (from `googleapis_auth`) and a
  `syncRoot` folder name; creates the Drive folder hierarchy lazily on first use
- [ ] Implement folder ID cache (`Map<String, String>`) to avoid repeated
  `Files.list` calls per operation — keyed by remote path prefix
- [ ] `list(dir, {extension})` — find the folder ID for `dir`, call
  `Files.list` with `parents in '<id>'` query, filter by extension, return
  bare filenames
- [ ] `download(path)` — resolve file ID for `path`, call `Files.get` with
  media download, return bytes (or `null` if 404)
- [ ] `upload(path, bytes)` — if file exists update with `Files.update`;
  if not create with `Files.create` (multipart); use resumable upload for
  files >5MB
- [ ] `delete(path)` — resolve file ID, call `Files.delete`; swallow 404
- [ ] `compareAndSwap(path, bytes, {ifMatchEtag})` — for null etag use
  `If-None-Match: *` on create; for non-null use `If-Match: <etag>` on
  update; return `false` on 412/409, `true` on success
- [ ] `getEtag(path)` — call `Files.get` (metadata only, no download),
  return the `ETag` header value (or `null` if 404)
- [ ] Expose `GoogleDriveAdapter` as the package's public API via
  `lib/kmdb_google_drive.dart`

### Phase 3 — Auth helpers

- [ ] Add `GoogleDriveAuthHelper` class with static factories:
  - `fromServiceAccount(ServiceAccountCredentials, scopes)` — for testing /
    server-side use
  - `fromUserConsent(ClientId, scopes, {String? credentialsCachePath})` —
    browser or device-flow OAuth for CLI; optionally caches tokens to disk
- [ ] Document which Drive scope to request (`drive.appdata` vs `drive.file`)
  and surface this clearly in the constructor / helper

### Phase 4 — Tests

- [ ] Unit tests with a `FakeHttpClient` / hand-rolled Drive stub that returns
  canned responses — cover all 6 interface methods
- [ ] Tests for `compareAndSwap` edge cases: 412, 409, success with and without
  etag, `LockConflictException` path
- [ ] Integration test (skipped by default, enabled by env var
  `GOOGLE_DRIVE_TEST_CREDENTIALS`) that runs the full `SyncEngine` push/pull
  cycle against a real Drive folder
- [ ] Achieve ≥90% line coverage on the package

### Phase 5 — CLI integration (`kmdb_cli`)

- [ ] Add `kmdb_google_drive` and `googleapis_auth` to `packages/kmdb_cli/pubspec.yaml`
- [ ] Add `remote add-google-drive <name>` sub-command that runs the local-server
  OAuth redirect flow and stores the resulting credentials to
  `local/google_credentials.json` (alongside existing `local/config.json`)
- [ ] Update `remote add` help text to document the Google Drive flow
- [ ] On `sync` for a Google Drive remote, load credentials from
  `local/google_credentials.json`, refresh if expired, construct
  `GoogleDriveAdapter`, and pass it to `SyncEngine`
- [ ] Tests for the credential load/refresh path (using a fake `AuthClient`)

### Phase 6 — Flutter UI integration (`kmdb_ui`)

- [ ] Add `kmdb_google_drive`, `google_sign_in`, and
  `extension_google_sign_in_as_googleapis_auth` to
  `packages/kmdb_ui/pubspec.yaml`
- [ ] Add a "Connect Google Drive" settings screen / dialog that triggers
  `GoogleSignIn().signIn()`, converts the result to an `AuthClient`, and
  persists the sync remote configuration
- [ ] Wire the `AuthClient` into `GoogleDriveAdapter` and `SyncEngine` for
  background sync
- [ ] Handle sign-out and credential revocation (disconnect Google Drive remote)
- [ ] Tests for the sign-in flow using a mocked `GoogleSignIn`

### Phase 7 — Spec and docs

- [ ] Add `26_google_drive_adapter.md` to `docs/spec/` covering auth,
  folder layout, ETag strategy, CAS semantics, and platform notes
- [ ] Update `docs/roadmap/0_04.md` to mark Google Drive item done
- [ ] Update `CLAUDE.md` package table with `kmdb_google_drive` entry
- [ ] Add usage example to `packages/kmdb_google_drive/example/`

## Summary

{Dot points highlighting the work undertaken}
