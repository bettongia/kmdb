# Google Drive sync

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

**Implementation model:** Sonnet, after H5 + harness land; the empirical Drive
probe (Phase 4a) is human-run with real credentials.

**Roadmap**: docs/roadmap/0_04.md

**Prerequisites**:
- `plan_sync_cas_atomicity.md` (H5) — defines the `compareAndSwap` atomicity
  contract, the adapter conformance/contention suite, and the
  atomic-CAS capability/gating this adapter must satisfy and declare.
- `plan_harness_mixed_storage.md` — defines per-device adapters, the
  `CloudProfile` abstraction, and the behavioural-cloud-simulation framework
  this package must implement for Drive (so the adapter is tested against
  realistic Drive semantics, not canned responses, with the real service
  reserved for pre-release).

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

### Quota capability interface

A separate optional interface `QuotaAwareAdapter` should be defined alongside
`SyncStorageAdapter` for adapters that operate under service-imposed quotas.
The test harness (and any other caller) checks for this interface before
running and uses it to gate or cap activity:

```dart
abstract interface class QuotaAwareAdapter {
  /// Maximum storage operations (upload + download + list + delete) per minute.
  /// Null means the adapter imposes no rate limit.
  int? get maxOperationsPerMinute;

  /// Maximum bytes uploadable per 24-hour window. Null means unlimited.
  int? get maxUploadBytesPerDay;

  /// Returns an estimate of whether the described workload is likely to
  /// exceed quota. Callers should reject or reduce the workload if this
  /// returns false.
  bool isWithinQuota({
    required int estimatedOperations,
    required Duration testDuration,
    required int estimatedUploadBytes,
  });
}
```

`GoogleDriveAdapter` implements `QuotaAwareAdapter`. `LocalDirectoryAdapter`
and `MemorySyncAdapter` do not — absence of the interface signals no quota
constraint. Default values for `GoogleDriveAdapter` should reflect current
Drive API limits and be documented with a reference to the Google API Console
so they can be updated when limits change.

### Google Drive REST API capabilities

- **Files.list** — list files in a folder by `parents` query; supports
  `orderBy`, `pageToken`, and `fields` projection.
- **Files.get** (media download) — download file bytes; response includes
  `ETag` header (and Drive's own `md5Checksum` field on metadata).
- **Files.create** (multipart/resumable upload) — creates a **new file with a
  new unique ID every time**. Drive identifies files by ID, not name, and
  permits multiple files with the same name in one folder (confirmed:
  <https://developers.google.com/workspace/drive/api/guides/create-file#copy-existing-file>
  — "the `copy` method produces a file with the same name as the original").
  There is therefore **no name-based `If-None-Match: *` precondition** on create;
  the earlier assumption that create can "prevent overwriting an existing file"
  by name does not hold. See the atomicity caveat below.
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

Drive supports conditional requests for **updates to a known file ID**:
- Update (if-match: etag): `Files.update` with `If-Match: <etag>` → `412
  Precondition Failed` on mismatch → return `false`. This is sound.

The **create** case does **not** map cleanly. Because `Files.create` always
mints a new ID and Drive allows duplicate names in a folder (see "Files.create"
above and the cited doc), a name-keyed "create if absent" is **not exclusive** —
two devices can each create a `.consolidation-lease` and both succeed. The
previously-assumed "`409 Conflict` on create means the file already exists" does
not occur for name-based creation. The lease design must not rely on it.

**Atomicity caveat — must be verified, not assumed.** Google Drive permits
**multiple files with the same name in a folder**, so a *name-keyed*
create-if-absent (`If-None-Match: *`) may not be exclusive: two devices could
each create a `.consolidation-lease` and both succeed, defeating the lease. The
consolidation lease's safety therefore hinges on whether Drive genuinely
enforces single-winner create for our addressing scheme. This must be:
1. **Verified empirically** against the behavioural Drive simulator and the real
   service using the H5 contention test from
   `plan_sync_cas_atomicity.md`.
2. **Declared honestly** via the H5 atomic-CAS capability and a `CloudProfile`
   (`atomicConditionalCreate`, `allowsDuplicateNames: true`). If Drive cannot
   guarantee atomic create for the lease, the adapter declares non-atomic CAS and
   the coordinator skips consolidation (loss-free) per H5 — rather than silently
   risking concurrent consolidation. An addressing change (e.g. a fixed file ID
   or app-data single-file lease) may be needed to obtain true atomicity.

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

### Phase 1b — Quota capability interface

- [ ] Define `QuotaAwareAdapter` interface in
  `packages/kmdb/lib/src/sync/quota_aware_adapter.dart`
- [ ] Export `QuotaAwareAdapter` from `lib/kmdb.dart`
- [ ] Implement `QuotaAwareAdapter` on `GoogleDriveAdapter` with Drive API
  default limits documented and linked to the Google API Console reference

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
- [ ] `compareAndSwap(path, bytes, {ifMatchEtag})` — for non-null etag use
  `If-Match: <etag>` on `Files.update` (atomic; `412` → `false`). The **null-etag
  create-if-absent** path must follow the lease design established by Phase 4a
  (name-keyed create is **not** exclusive on Drive — see the atomicity caveat);
  do not assume `If-None-Match: *`/`409` works for create. If no atomic create
  design is found, declare non-atomic CAS (H5) so consolidation is gated.
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

### Phase 4 — Behavioural Drive simulator + tests

The default test backend is a **behavioural Google Drive API simulator**, not
canned responses. It is a fake `http.Client` (the seam below the real
`googleapis` `DriveApi`) implementing the Drive REST endpoints with realistic
behaviour, so the **actual `GoogleDriveAdapter` code is exercised**. It is the
Drive provider's implementation of the simulation framework defined in
`plan_harness_mixed_storage.md`, and ships with a Drive `CloudProfile`
(`allowsDuplicateNames: true`, an `atomicConditionalCreate` value established by
the verification below, eventual-consistency and quota parameters).

#### Phase 4a — Empirical Drive behaviour probe (must run first)

The simulator's fidelity and the lease design both depend on **observed** Drive
behaviour, not assumptions. Build a small, credential-gated probe harness that
records what real Drive actually does, and treat its findings as the
specification the simulator must reproduce:

- [ ] Probe conditional **create** semantics: concurrent `Files.create` of the
  same name in one folder — does Drive reject any, or produce N distinct files?
  What status codes? Does `If-None-Match: *` change anything on create?
- [ ] Probe conditional **update** semantics: concurrent `Files.update` on one
  file ID with `If-Match: <etag>` — confirm exactly one wins, others get `412`.
- [ ] Probe the candidate **ID-addressed lease** design (single well-known file,
  CAS via `If-Match` on its ETag): is it atomic under contention? What is the
  first-time-create race (before any ID exists), and how is it resolved?
- [ ] Probe consistency: time-to-visibility of a newly created/updated/deleted
  file to a second client; whether `Files.list` is read-your-writes consistent.
- [ ] Probe rate-limit/quota responses (429/503 shapes, `Retry-After`).
- [ ] **Record the findings in this plan** (a results table) and derive the
  Drive `CloudProfile` values and the lease design from them.

This probe runs against real Drive (credential-gated, manual/pre-release), but
its **output is captured as fixtures/parameters** so the deterministic simulator
encodes the same behaviour — closing the loop so simulator passes imply real
Drive passes.

- [ ] Implement the behavioural Drive simulator (fake `http.Client`) modelling:
  conditional create/update (`If-None-Match: *` / `If-Match`), **duplicate-name
  creation semantics**, eventual-consistency/propagation delay, 429/503
  rate-limit responses, and resumable upload.
- [ ] Run the **H5 adapter conformance + contention suite**
  (`plan_sync_cas_atomicity.md`) against the real adapter over the simulator —
  including the lease create-contention test that settles the atomicity caveat
  above.
- [ ] Publish the Drive `CloudProfile`; if create is not atomic, declare
  non-atomic CAS so the coordinator gates consolidation.
- [ ] Unit tests for all six `SyncStorageAdapter` methods and back-off/cancel
  behaviour, driven through the simulator.
- [ ] Wire the real-adapter-over-simulator into a `kmdb_harness` mixed-mode
  scenario (per-device adapters; REST + FS-view of one shared backend) and assert
  convergence.
- [ ] **Pre-release integration test** (skipped by default, enabled by env var
  `GOOGLE_DRIVE_TEST_CREDENTIALS`): full `SyncEngine` push/pull cycle and the
  contention test against a **real** Drive folder — confirming the simulator's
  fidelity and the real atomicity behaviour. Not part of per-commit CI.
- [ ] Achieve ≥90% line coverage on the package (via the simulator path).

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

- [ ] Add `docs/spec/NN_google_drive_adapter.md` (next available section number,
  assigned at creation time — see `plans/README.md`) covering auth, folder
  layout, ETag strategy, CAS semantics, and platform notes
- [ ] Record the Phase 4a probe results table in this plan, and register
  **RC-1 (Drive behaviour probe)** and **RC-2 (Drive real-service soak)** in
  the release checklist `docs/spec/28_release_checklist.md`
- [ ] Update `docs/roadmap/0_04.md` to mark Google Drive item done
- [ ] Update `CLAUDE.md` package table with `kmdb_google_drive` entry
- [ ] Add usage example to `packages/kmdb_google_drive/example/`

## Summary

{Dot points highlighting the work undertaken}
