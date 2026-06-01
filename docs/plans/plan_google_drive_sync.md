# Google Drive sync

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

**Implementation model:** Sonnet, **after the harness plan lands** (see the
hard gate below); the empirical Drive probe (Phase 4a) is human-run with real
credentials.

**Roadmap**: docs/roadmap/0_03.md

**Prerequisites**:

- ✅ `plan_sync_cas_atomicity.md` (H5) — **COMPLETE** (now in
  `docs/plans/completed/`). Landed: the `providesAtomicCas` getter on
  `SyncStorageAdapter`, `ConsolidationCoordinator` gating on it, and the
  reusable `runSyncAdapterConformance({required factory, required
  expectAtomicCas})` suite at
  `packages/kmdb/test/support/sync_adapter_conformance.dart`. This adapter must
  pass that suite and declare its atomicity via `providesAtomicCas`. **Note:**
  H5's D4 deferred the *public export path* of the conformance suite to the
  first downstream consumer — that is this plan (see Q-S6 / Phase 4
  prerequisite).
- ✅ **`plan_harness_mixed_storage.md` — COMPLETE (PR #34, branch
  `20260601_plan_harness_mixed_storage`).** Landed: `CloudProfile`
  (`atomicConditionalCreate`, `allowsDuplicateNames`, `consistency`,
  `quota`) at
  `packages/kmdb/lib/src/test_cloud/cloud_profile.dart`; the per-device
  adapter factory (`HarnessConfig.syncAdapterFactory`) and
  `SharedCloudBackend` / `SharedBackendAdapter` / `CloudSemanticsAdapter`
  exported via `package:kmdb/kmdb_test_cloud_support.dart`; atomicity-field
  decision settled (see Q-S2). The Phase 4 gate is cleared.

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
      `betto_zstd` / `kmdb_tokenizer_icu` pattern). Heavy OAuth dependencies
      stay out of core `kmdb`; consumers opt in explicitly.

- [x] **Authentication approach** — the adapter accepts a pre-built `AuthClient`
      (from `googleapis_auth`) and is auth-agnostic. Callers own the OAuth
      lifecycle. The two reference integrations ship as part of this plan:
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
      with jitter on 429 / 503 responses (Drive best practice). Each sync
      operation accepts a `CancellationToken` (or `Duration timeout`); back-off
      respects the token and aborts cleanly if cancelled or if the deadline
      expires. No silent infinite retry.

- [x] **Resumable uploads** — all uploads use Drive's resumable upload protocol
      (simpler to implement uniformly than a size threshold). If the sync is
      cancelled mid-upload the resumable session URI is discarded and the
      incomplete upload is abandoned (Drive auto-expires abandoned sessions
      after 7 days).

- [x] **Web/WASM support** — no stub needed. `googleapis` and `package:http` are
      both web-compatible; the adapter contains no `dart:io`. CLI credential
      storage (`HttpServer` redirect, token file) lives in `kmdb_cli` only.
      Flutter web uses `google_sign_in_web` to produce an `AuthClient` — the
      adapter is unchanged. The spec will note web as a supported target.

## Investigation

### Existing adapter interface

`SyncStorageAdapter` (in `packages/kmdb/lib/src/sync/sync_storage_adapter.dart`)
defines six methods:

| Method                                       | Notes                          |
| -------------------------------------------- | ------------------------------ |
| `list(dir, {extension})`                     | Returns bare filenames only    |
| `download(path)`                             | Returns `null` if file absent  |
| `upload(path, bytes)`                        | Overwrites if exists           |
| `delete(path)`                               | No-op if absent                |
| `compareAndSwap(path, bytes, {ifMatchEtag})` | `null` etag = if-none-match:\* |
| `getEtag(path)`                              | Returns `null` if absent       |

All ETags are implementation-specific opaque strings. The lease protocol in
`ConsolidationCoordinator` depends entirely on `compareAndSwap` behaving
atomically from the server's perspective.

### Quota capability interface (RESOLVED — Q-B1)

> **Decision (review 2, 2026-06-01):** Adopt the **existing** `QuotaAwareAdapter`
> as-is. Do **not** define a new interface in core `kmdb`. The richer
> `maxOperationsPerMinute` / `maxUploadBytesPerDay` / `isWithinQuota(...)` shape
> proposed in the original draft below is **dropped** — it is not load-bearing,
> and defining it would either duplicate the landed type or silently break
> `TestManager`.

`QuotaAwareAdapter` **already exists** at
`packages/kmdb_harness/lib/src/test_manager.dart` (exported from
`kmdb_harness.dart`). It is a minimal marker interface with a single member:

```dart
abstract interface class QuotaAwareAdapter {
  /// Maximum safe number of storage operations for a single harness run.
  int get safeOperationThreshold;
}
```

`TestManager._validateQuota` already consumes it (`adapter is QuotaAwareAdapter`
→ rejects a run when `estimatedOps > adapter.safeOperationThreshold`).

**Consequences for this plan:**

- `QuotaAwareAdapter` lives in `kmdb_harness`, **not** core `kmdb`. Implementing
  it on `GoogleDriveAdapter` means `kmdb_google_drive` must take a dependency on
  `kmdb_harness`. That is undesirable — a production adapter should not depend on
  a test-harness package. **Therefore `GoogleDriveAdapter` does NOT implement
  `QuotaAwareAdapter` directly.** Instead, the Drive **simulator** (which lives
  in the test tree and already depends on `kmdb_harness` per Phase 4) implements
  `QuotaAwareAdapter` and reports a `safeOperationThreshold` derived from the
  Drive `CloudProfile` quota knobs. This keeps the marker interface in the test
  layer where the harness consumes it, and keeps the production adapter free of
  the harness dependency.
- Runtime quota handling on the real adapter is **reactive only**: exponential
  back-off with jitter on 429/503 (see the rate-limit Open question). No rich
  predictive quota interface is needed on the production type.
- The original richer-interface draft (struck through below) is **not** part of
  this plan.

<details><summary>Superseded original draft (do not implement)</summary>

> ~~A separate optional interface `QuotaAwareAdapter` should be defined alongside
> `SyncStorageAdapter` … with `maxOperationsPerMinute` / `maxUploadBytesPerDay` /
> `isWithinQuota(...)`.~~ Superseded — see decision above.

</details>

### Google Drive REST API capabilities

- **Files.list** — list files in a folder by `parents` query; supports
  `orderBy`, `pageToken`, and `fields` projection.
- **Files.get** (media download) — download file bytes; response includes `ETag`
  header (and Drive's own `md5Checksum` field on metadata).
- **Files.create** (multipart/resumable upload) — creates a **new file with a
  new unique ID every time**. Drive identifies files by ID, not name, and
  permits multiple files with the same name in one folder (confirmed:
  <https://developers.google.com/workspace/drive/api/guides/create-file#copy-existing-file>
  — "the `copy` method produces a file with the same name as the original").
  There is therefore **no name-based `If-None-Match: *` precondition** on
  create; the earlier assumption that create can "prevent overwriting an
  existing file" by name does not hold. See the atomicity caveat below.
- **Files.update** (media update) — update existing file bytes; supports
  `If-Match: <etag>` for conditional update.
- **Files.delete** — delete a file by ID.
- Drive ETags are stable per-revision and exposed in `ETag` response headers and
  in the file metadata `headRevisionId`. They are suitable for CAS.

### ETag strategy

Drive file metadata includes `md5Checksum` (content hash) and a server-assigned
`ETag` header on every response. The `ETag` header is the cleanest choice: it
changes on every update, matches what the `If-Match` / `If-None-Match` headers
expect, and mirrors how GCS and S3 work.

### compareAndSwap on Drive

Drive supports conditional requests for **updates to a known file ID**:

- Update (if-match: etag): `Files.update` with `If-Match: <etag>` →
  `412 Precondition Failed` on mismatch → return `false`. This is sound.

The **create** case does **not** map cleanly. Because `Files.create` always
mints a new ID and Drive allows duplicate names in a folder (see "Files.create"
above and the cited doc), a name-keyed "create if absent" is **not exclusive** —
two devices can each create a `.consolidation-lease` and both succeed. The
previously-assumed "`409 Conflict` on create means the file already exists" does
not occur for name-based creation. The lease design must not rely on it.

**Atomicity caveat — must be verified, not assumed.** Google Drive permits
**multiple files with the same name in a folder**, so a _name-keyed_
create-if-absent (`If-None-Match: *`) may not be exclusive: two devices could
each create a `.consolidation-lease` and both succeed, defeating the lease. The
consolidation lease's safety therefore hinges on whether Drive genuinely
enforces single-winner create for our addressing scheme. This must be:

1. **Verified empirically** against the behavioural Drive simulator and the real
   service using the H5 contention test from `plan_sync_cas_atomicity.md`.
2. **Declared honestly** via the H5 `providesAtomicCas` getter (per-instance, on
   the `SyncStorageAdapter` interface — confirmed landed) and the Drive
   `CloudProfile`. If Drive cannot guarantee atomic create for the lease, the
   adapter returns `providesAtomicCas == false` and `ConsolidationCoordinator`
   skips consolidation (loss-free) per H5 — rather than silently risking
   concurrent consolidation. An addressing change (e.g. a fixed/known file ID
   lease *inside the `drive.file` sync folder*) may be needed to obtain true
   atomicity.

> **Scope constraint (RESOLVED — Q-S3).** The lease design is constrained to
> operate **within the `drive.file` sync folder** — an `If-Match`-on-known-ID
> lease file, not a `drive.appdata` single-file lease. This keeps the scope
> decision closed at `drive.file` (the Open question's choice) and avoids
> requiring the broader `drive.appdata` scope. The Phase 4a probe therefore
> probes the **ID-addressed lease inside the sync folder**, not an app-data
> lease. If — and only if — Phase 4a empirically shows that no atomic
> create/CAS lease is achievable under `drive.file`, the adapter declares
> `providesAtomicCas == false` (consolidation gated off, loss-free); it does
> **not** silently escalate to `drive.appdata`. Any future move to `drive.appdata`
> would be a separate, explicitly-scoped decision.

> **Relationship to `CloudProfile` (RESOLVED — defer to harness plan).** The
> codebase already expresses CAS-create atomicity as the single bool
> `SyncStorageAdapter.providesAtomicCas`, and the H5 conformance suite is
> parameterised by `expectAtomicCas`. This plan must **not** introduce a second,
> differently-named atomicity field. Whether `CloudProfile` carries an atomicity
> bool at all (and, if so, that it must equal `adapter.providesAtomicCas`) is a
> decision **owned by `plan_harness_mixed_storage.md` (its open item #3)** and
> must be settled there before this plan implements Phase 4. This plan consumes
> whatever `CloudProfile` shape that plan lands; it derives the Drive atomicity
> claim from `providesAtomicCas`, full stop.

### Dart packages

| Package           | Purpose                                                            |
| ----------------- | ------------------------------------------------------------------ |
| `googleapis`      | Generated Drive v3 client (`DriveApi`)                             |
| `googleapis_auth` | OAuth2 `AuthClient` factory (device flow, service account)         |
| `google_sign_in`  | Flutter platform SSO (mobile/desktop/web)                          |
| `http`            | Underlying HTTP client (already a transitive dep via `googleapis`) |

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

> **Deliberate divergence from the roadmap (RESOLVED — Q-S1).** `0_03.md` says
> "Each adapter lives under `lib/src/sync/cloud/`." This plan **overrides** that
> note: the OAuth/`googleapis` dependency surface is too heavy to pull into core
> `kmdb`, so the Drive adapter ships as its own package. This is an intentional
> deviation, not an oversight. Phase 7 includes a step to have the architect
> update the `0_03.md` note (the `lib/src/sync/cloud/` convention may still hold
> for dependency-light adapters such as a future GCS adapter, but not for Drive).

## Implementation plan

### Phase 1 — Package scaffold

- [ ] Create `packages/kmdb_google_drive/` with standard layout (`lib/`,
      `test/`, `pubspec.yaml`, `README.md`)
- [ ] Add `googleapis`, `googleapis_auth`, `kmdb` dependencies in pubspec
- [ ] Add `kmdb_google_drive` to root workspace `pubspec.yaml`
- [ ] Add license header to all new Dart source files (use
      `@header_template.txt`)
- [ ] Add `kmdb_google_drive` entry to `melos.yaml` if one exists

### Phase 1b — Quota capability (RESOLVED — no new interface)

> Per Q-B1: **no new interface is defined and `GoogleDriveAdapter` does not
> implement `QuotaAwareAdapter`.** The existing `kmdb_harness`
> `QuotaAwareAdapter` (single member `safeOperationThreshold`) is reused, and it
> is the **Drive simulator** (test tree) that implements it.

- [ ] In the Drive simulator (Phase 4), implement `kmdb_harness`'s
      `QuotaAwareAdapter` and compute `safeOperationThreshold` from the Drive
      `CloudProfile` quota knobs. Document the Drive API limits the value is
      derived from, with a link to the Google API Console reference so it can be
      updated when limits change.
- [ ] Confirm `kmdb_google_drive` (the production package) takes **no**
      dependency on `kmdb_harness`.

### Phase 2 — Core adapter implementation

- [ ] Implement `GoogleDriveAdapter` in `lib/src/google_drive_adapter.dart`
      implementing `SyncStorageAdapter`
- [ ] Constructor accepts `AuthClient` (from `googleapis_auth`) and a `syncRoot`
      folder name; creates the Drive folder hierarchy lazily on first use
- [ ] Implement folder ID cache (`Map<String, String>`) to avoid repeated
      `Files.list` calls per operation — keyed by remote path prefix. When
      resolving a folder name that has **multiple** matches (Drive allows
      duplicate names), apply the deterministic rule from Phase 4a/Q-S5: select
      the oldest `createdTime`, tie-broken by lowest file ID, and cache **that**
      ID. Never bind the cache to "first listed".
- [ ] `list(dir, {extension})` — find the folder ID for `dir`, call `Files.list`
      with `parents in '<id>'` query, filter by extension, return bare filenames
- [ ] `download(path)` — resolve file ID for `path`, call `Files.get` with media
      download, return bytes (or `null` if 404)
- [ ] `upload(path, bytes)` — if file exists update with `Files.update`; if not
      create with `Files.create`. **All uploads use Drive's resumable upload
      protocol** (per the "Resumable uploads" Open question — uniform path, no
      size threshold). The earlier ">5MB threshold" wording is withdrawn.
- [ ] `delete(path)` — resolve file ID, call `Files.delete`; swallow 404
- [ ] `compareAndSwap(path, bytes, {ifMatchEtag})` — for non-null etag use
      `If-Match: <etag>` on `Files.update` (atomic; `412` → `false`). The
      **null-etag create-if-absent** path must follow the lease design
      established by Phase 4a (name-keyed create is **not** exclusive on Drive —
      see the atomicity caveat); do not assume `If-None-Match: *`/`409` works
      for create. If no atomic create design is found, declare non-atomic CAS
      (H5) so consolidation is gated.
- [ ] `getEtag(path)` — call `Files.get` (metadata only, no download), return
      the `ETag` header value (or `null` if 404)
- [ ] `bool get providesAtomicCas` — implement the H5 capability getter. Its
      value is **set by the Phase 4a finding** (whether the `drive.file` lease
      CAS is atomic under contention). Default to `false` until Phase 4a proves
      atomicity; this is the loss-free posture.
- [ ] Expose `GoogleDriveAdapter` as the package's public API via
      `lib/kmdb_google_drive.dart`

### Phase 3 — Auth helpers

- [ ] Add `GoogleDriveAuthHelper` class with static factories:
  - `fromServiceAccount(ServiceAccountCredentials, scopes)` — for testing /
    server-side use
  - `fromUserConsent(ClientId, scopes, {String? credentialsCachePath})` —
    browser or device-flow OAuth for CLI; optionally caches tokens to disk
- [ ] Request the **`drive.file`** scope (RESOLVED — Q-S3; see the scope note in
      the CAS section). Do **not** offer `drive.appdata`. Surface the scope
      constant clearly in the helper.

### Phase 4 — Behavioural Drive simulator + tests

The default test backend is a **behavioural Google Drive API simulator**, not
canned responses. It is a fake `http.Client` (the seam below the real
`googleapis` `DriveApi`) implementing the Drive REST endpoints with realistic
behaviour, so the **actual `GoogleDriveAdapter` code is exercised**. It is the
Drive provider's implementation of the simulation framework defined in
`plan_harness_mixed_storage.md` (now landed — see prerequisites).

The simulator ships a Drive `CloudProfile` using the **concrete field set now
in code** at `packages/kmdb/lib/src/test_cloud/cloud_profile.dart` (exported
via `package:kmdb/kmdb_test_cloud_support.dart`):

```dart
// Drive CloudProfile — preliminary values; atomicConditionalCreate and
// consistency parameters are finalised by the Phase 4a empirical probe.
CloudProfile(
  consistency: EventualConsistency(
    maxPropagationDelayMs: /* Phase 4a result */,
    jitterMs: /* Phase 4a result */,
  ),
  atomicConditionalCreate: false, // safe default; override to true only if
                                  // Phase 4a proves atomic create under
                                  // drive.file scope
  allowsDuplicateNames: true,     // confirmed Drive behaviour
  quota: QuotaProfile(
    maxOpsPerMinute: /* Drive API limit from API Console */,
    maxUploadBytesPerDay: null,   // or Drive daily upload cap if enforced
  ),
)
```

**Atomicity-field resolution (Q-S2):** `CloudProfile.atomicConditionalCreate`
IS the atomicity field. `CloudSemanticsAdapter.providesAtomicCas` is
`profile.atomicConditionalCreate` — they are the same value. The Drive adapter
sets `providesAtomicCas` from the Phase 4a finding; this plan does **not**
invent a second field. The conformance suite is parameterised by
`expectAtomicCas: adapter.providesAtomicCas` — no new contract is needed.

#### Phase 4 prerequisite — settle the conformance-suite export path (Q-S6)

> **Decision (review 2, 2026-06-01):** H5's D4 deferred the public export shape
> of the conformance suite "until the first downstream package needs it."
> `kmdb_google_drive` is that first package, so this plan settles it. The suite
> currently lives at `packages/kmdb/test/support/sync_adapter_conformance.dart`
> — under `test/`, which a separate package **cannot** import.

- [ ] Expose the conformance suite from `kmdb`'s `lib/` so downstream packages
      can run it. Move `sync_adapter_conformance.dart` into a published
      test-support library — recommended: `lib/src/test_support/` re-exported via
      a dedicated `lib/test_support.dart`, imported downstream as
      `package:kmdb/test_support.dart`. (It depends on `package:test`; keep that
      dependency confined to this library and document that `test_support.dart`
      is for test use only.) Update the three existing in-package call sites
      (`memory_sync_adapter_test.dart`, `local_directory_adapter_test.dart`) to
      import the new path. This is a small `kmdb` refactor that lands as part of
      this plan, since this plan is the first external consumer.

#### Phase 4a — Empirical Drive behaviour probe (must run first)

The simulator's fidelity and the lease design both depend on **observed** Drive
behaviour, not assumptions. Build a small, credential-gated probe harness that
records what real Drive actually does, and treat its findings as the
specification the simulator must reproduce:

- [ ] Probe conditional **create** semantics: concurrent `Files.create` of the
      same name in one folder — does Drive reject any, or produce N distinct
      files? What status codes? Does `If-None-Match: *` change anything on
      create?
- [ ] Probe conditional **update** semantics: concurrent `Files.update` on one
      file ID with `If-Match: <etag>` — confirm exactly one wins, others get
      `412`.
- [ ] Probe the candidate **ID-addressed lease** design (single lease file
      *inside the `drive.file` sync folder*, CAS via `If-Match` on its ETag): is
      it atomic under contention? What is the first-time-create race (before any
      ID exists), and how is it resolved?
- [ ] Probe **concurrent folder creation** (Q-S5): have two clients
      simultaneously lazy-create the same `sstables/` (or `highwater/`) subfolder
      under the sync root. Does Drive produce duplicate same-named folders? This
      is the **same duplicate-name hazard as the lease**, applied to the folder
      hierarchy the adapter bootstraps on first use. Record the observed
      behaviour. **Resolution rule (to encode in the adapter and simulator):** on
      `list`/resolve, if multiple folders share a name under a parent, the
      adapter deterministically selects the one with the **oldest `createdTime`,
      tie-broken by lexicographically-lowest file ID**, and ignores the rest.
      The in-memory folder-ID cache (Phase 2) must bind to this
      deterministically-chosen ID, never to whichever happened to be listed
      first. Document whether a one-time pre-provisioned folder hierarchy is
      preferable to lazy create for production setups.
- [ ] Probe consistency: time-to-visibility of a newly created/updated/deleted
      file to a second client; whether `Files.list` is read-your-writes
      consistent.
- [ ] Probe rate-limit/quota responses (429/503 shapes, `Retry-After`).
- [ ] **Record the findings in this plan** (a results table) and derive the
      Drive `CloudProfile` values and the lease design from them.

This probe runs against real Drive (credential-gated, manual/pre-release), but
its **output is captured as fixtures/parameters** so the deterministic simulator
encodes the same behaviour — closing the loop so simulator passes imply real
Drive passes.

- [ ] Implement the behavioural Drive simulator (fake `http.Client`) modelling:
      conditional create/update (`If-None-Match: *` / `If-Match`),
      **duplicate-name creation semantics for both files and folders** (Q-S5),
      eventual-consistency/propagation delay, 429/503 rate-limit responses, and
      resumable upload.
- [ ] Run the **H5 adapter conformance + contention suite**
      (`runSyncAdapterConformance({required factory, required expectAtomicCas})`,
      now landed at `packages/kmdb/test/support/sync_adapter_conformance.dart` —
      see Q-S6 for the export path this plan must establish) against the real
      adapter over the simulator — including the lease create-contention test
      that settles the atomicity caveat above.
- [ ] Publish the Drive `CloudProfile` instance (using the field set the harness
      plan lands); set `GoogleDriveAdapter.providesAtomicCas` from the Phase 4a
      finding. If the lease create/CAS is not atomic under `drive.file`, the
      adapter returns `providesAtomicCas == false` so `ConsolidationCoordinator`
      gates consolidation off (loss-free).
- [ ] Unit tests for all six `SyncStorageAdapter` methods and back-off/cancel
      behaviour, driven through the simulator.
- [ ] Wire the real-adapter-over-simulator into a `kmdb_harness` mixed-mode
      scenario (per-device adapters; REST + FS-view of one shared backend) and
      assert convergence.
- [ ] **Pre-release integration test** (skipped by default, enabled by env var
      `GOOGLE_DRIVE_TEST_CREDENTIALS`): full `SyncEngine` push/pull cycle and
      the contention test against a **real** Drive folder — confirming the
      simulator's fidelity and the real atomicity behaviour. Not part of
      per-commit CI.
- [ ] Achieve ≥90% line coverage on the package (via the simulator path).

### Phase 5 — CLI integration (`kmdb_cli`) (RESOLVED — Q-B2)

> **Decision (review 2, 2026-06-01):** model the Drive remote with a new
> **`GoogleDriveRemoteConfig`** sealed subtype in **core `kmdb`** (config only,
> no adapter construction), and build the adapter in the **CLI's** `adapterFor`,
> which is the only layer that depends on both `kmdb` and `kmdb_google_drive`.
> `adapterFor` becomes **async** because token load/refresh is async. The
> credentials live in `local/google_credentials.json` and are referenced (not
> inlined) by the config.

**Verified seam (2026-06-01):**

- `RemoteConfig` is a `sealed` class in
  `packages/kmdb/lib/src/config/remote_config.dart` (exported via
  `kmdb_config.dart`); `RemoteConfig.fromJson` dispatches on a `type` string;
  only `LocalRemoteConfig` exists today.
- `adapterFor(RemoteConfig)` in
  `packages/kmdb_cli/lib/src/config/remote_config.dart` is an **exhaustive**
  `switch` over the sealed subtypes returning a `SyncStorageAdapter`
  synchronously.
- `adapterFor` is called only from `sync_command.dart` (line 93),
  `push_command.dart` (line 101), and `pull_command.dart` (line 96) — **all
  already `async`** and `await` the surrounding sync, so awaiting `adapterFor`
  is a non-breaking change.
- `remote add` (`remote_command.dart` line 95) already has a `--type` dispatch
  (currently `local` only) and persists via `KmdbConfig.addRemote` / `save`.
  `_list` (line 199) and the `add` switch are exhaustive over the sealed type,
  so the new subtype forces both to gain a Drive branch (compiler-enforced).

**Steps:**

- [ ] **Core `kmdb`:** add `final class GoogleDriveRemoteConfig extends
      RemoteConfig` in `packages/kmdb/lib/src/config/remote_config.dart` with
      `type == 'google-drive'`. Fields: `syncRoot` (the Drive folder name) and
      `credentialsPath` (relative path under `local/`, default
      `google_credentials.json`). Implement `toJson` / `fromJson` and add the
      `'google-drive'` branch to `RemoteConfig.fromJson`. **No adapter
      construction here** — core `kmdb` cannot depend on `kmdb_google_drive`.
      Update the `RemoteConfig` doc comment's "Adding a new remote type" list if
      needed. Add unit tests for round-trip serialisation and the unknown-field
      cases (mirror `LocalRemoteConfig` tests).
- [ ] **CLI:** add `kmdb_google_drive` and `googleapis_auth` to
      `packages/kmdb_cli/pubspec.yaml`.
- [ ] **CLI:** make `adapterFor` **async**
      (`Future<SyncStorageAdapter> adapterFor(RemoteConfig remote, {required
      String dbDir})`). Add the `GoogleDriveRemoteConfig` case: resolve
      `<dbDir>/local/<credentialsPath>`, load the cached OAuth credentials,
      refresh if expired (persist the refreshed token back), build an
      `AuthClient`, and return `GoogleDriveAdapter(authClient, syncRoot:
      remote.syncRoot)`. The `dbDir` is already available at every call site via
      `storeInfo()`. Update the three call sites to `await adapterFor(remote,
      dbDir: dbDir)`.
- [ ] **CLI:** extend `remote add --type google-drive <name>` to run the
      local-server OAuth redirect flow (`googleapis_auth`'s
      `obtainAccessCredentialsViaUserConsent` + a transient `HttpServer` on
      `localhost`), write the resulting credentials to
      `local/google_credentials.json`, and persist a `GoogleDriveRemoteConfig`
      (with `syncRoot` from a `--folder` flag, default e.g. `kmdb-sync`) via
      `KmdbConfig.addRemote`. Add the Drive branch to the `remote add` `--type`
      switch and to `_list`'s exhaustive switch.
- [ ] **CLI:** update `remote add` help text to document the Google Drive flow
      and the required `--folder` / OAuth client-id inputs.
- [ ] Tests for: `adapterFor` Drive branch with a fake `AuthClient` / fake
      credentials file (expired → refreshed → persisted), and the
      `remote add --type google-drive` flow with the OAuth step stubbed.
      `local/google_credentials.json` must never be synced (it lives under
      `local/`, which `SyncEngine` already ignores — assert it is not uploaded).

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
- [ ] Record the Phase 4a probe results table in this plan, and register **RC-1
      (Drive behaviour probe)** and **RC-2 (Drive real-service soak)** in the
      release checklist `docs/spec/28_release_checklist.md`
- [ ] Update `docs/roadmap/0_03.md` to mark the Google Drive item done (the
      item lives in `0_03.md`, not `0_04.md`)
- [ ] Update `CLAUDE.md` package table with `kmdb_google_drive` entry
- [ ] Add usage example to `packages/kmdb_google_drive/example/`

## Review (kmdb-plan-reviewer, 2026-06-01)

**Verdict: Not yet `Investigated`. Status reverted to `Questions`.** The
investigation and high-risk reasoning (the atomicity caveat, duplicate-name
behaviour, the probe-then-simulate loop, the gate-via-H5 fallback) are genuinely
strong and well-grounded — this is the right shape for a Drive adapter. But three
factual misalignments with the *landed* codebase and one unresolved
cross-package seam would force a Sonnet implementer to make architecture
decisions on the fly. They must be resolved before this is mechanically
implementable.

### Strengths (keep these)

- The Phase 4a empirical-probe-then-encode-into-simulator loop is exactly right
  and honest about Drive's duplicate-name behaviour. The decision to fall back to
  H5's "declare non-atomic CAS → coordinator skips consolidation (loss-free)"
  rather than risk a split lease is the correct safety posture and aligns with
  the landed `providesAtomicCas` gate.
- Package placement (`packages/kmdb_google_drive`, auth-agnostic `AuthClient`
  constructor) is consistent with the workspace convention and keeps OAuth deps
  out of core.
- Prerequisite sequencing (H5 → harness mixed-storage → this) is correctly
  identified and matches what those plans say.

### Blocking issues

**B1 — `QuotaAwareAdapter` already exists, with a different shape and home.**
The plan (Investigation §"Quota capability interface" and Phase 1b) proposes to
*define* `QuotaAwareAdapter` in `packages/kmdb/lib/src/sync/quota_aware_adapter.dart`
with members `maxOperationsPerMinute`, `maxUploadBytesPerDay`, and
`isWithinQuota(...)`. That type **already exists** in
`packages/kmdb_harness/lib/src/test_manager.dart` (exported from
`kmdb_harness.dart`) as a minimal marker interface with a **single** member:
`int get safeOperationThreshold`. The harness's `TestManager` already consumes it
(`adapter is QuotaAwareAdapter` → compares `safeOperationThreshold`). The
prerequisite harness plan even states the harness is "already
`QuotaAwareAdapter`-aware." So Phase 1b as written would either (a) create a
duplicate type, or (b) silently break `TestManager`'s existing contract.

The plan must decide one of:
  - **Adopt the existing interface as-is** (implement `safeOperationThreshold` on
    `GoogleDriveAdapter`) and delete Phase 1b's "define a new interface" step and
    the richer Investigation block. Simplest; recommended unless the richer
    quota model is actually needed by the back-off logic.
  - **Move + extend the interface into core `kmdb`** as a deliberate, separately
    justified change — in which case this becomes a refactor of `kmdb_harness`
    (which must then import it from `kmdb`), with its own migration step, and the
    harness plan's "already aware" assumption must be reconciled. This is real
    scope, not a drive-by.
  Either way, the back-off/cancellation logic (Open question on rate limits) does
  not depend on the *rich* quota shape — it reacts to 429/503 at runtime — so the
  richer interface is not obviously load-bearing. Justify it or drop it.

**B2 — CLI integration ignores the `RemoteConfig` seam, which is the actual
hard part.** Phase 5 describes a `remote add-google-drive` command and a
credentials file, but says nothing about how a Drive remote is *modelled* and
*constructed*. CLI sync remotes are a **sealed `RemoteConfig`** in core `kmdb`
(`packages/kmdb/lib/src/config/remote_config.dart`, exported via
`kmdb_config.dart`), dispatched by a `type` string in `RemoteConfig.fromJson`;
the CLI's `adapterFor(RemoteConfig)` switches the sealed subtypes to build a
`SyncStorageAdapter`. Adding Drive therefore requires:
  - a new `GoogleDriveRemoteConfig` subtype + `fromJson`/`toJson` + `type` string
    in core `kmdb`, and
  - an `adapterFor` branch that builds the Drive adapter.
  But `GoogleDriveAdapter` lives in a **separate package that core `kmdb` cannot
  depend on**, and `adapterFor` is in the CLI package (which *can* depend on
  `kmdb_google_drive`). The sealed-class `switch` in `adapterFor` is exhaustive,
  so a new subtype in core forces the CLI factory to handle it. The plan must
  spell out: where the subtype lives, how `adapterFor` constructs the Drive
  adapter (it can, since the CLI depends on both packages), how credentials are
  threaded from `local/google_credentials.json` into adapter construction (the
  factory currently takes only a `RemoteConfig`, not an `AuthClient`), and
  whether `adapterFor` becomes async (token refresh is async). This is the
  single biggest mechanical-readiness gap.

**B3 — Roadmap target is wrong.** The Google Drive item lives in
`docs/roadmap/0_03.md` (the plan header correctly cites 0_03), but Phase 7's
checklist says "Update `docs/roadmap/0_04.md` to mark Google Drive item done."
Fix to `0_03.md`. (GCS is correctly deferred — it sits in `0_07.md`/`9_99.md`,
so the plan's "GCS is a separate work item" claim is accurate.)

### Secondary issues

**S1 — Roadmap says `lib/src/sync/cloud/`; plan says a separate package.**
`0_03.md` states "Each adapter lives under `lib/src/sync/cloud/`." The plan
overrides this with a separate `kmdb_google_drive` package — a reasonable call
(OAuth deps), and probably the better one, but it is a deliberate deviation from
the roadmap note. Call it out explicitly in the plan (and have the architect
update the roadmap note) so the discrepancy is intentional, not an oversight.

**S2 — `CloudProfile` is not yet code.** The plan leans on `CloudProfile`
(`atomicConditionalCreate`, `allowsDuplicateNames`, consistency/quota knobs) as
though it exists. It does **not** — it is only described in
`plan_harness_mixed_storage.md`, which is still `Investigated` (not landed) and
whose decisions D1–D5 are still unchecked. This plan's Phase 4 hard-depends on
that type and the per-device-adapter harness factory existing. That dependency
is stated, which is good, but the plan should not be implemented until the
harness plan lands, and the checklist should not present `CloudProfile`
publication as if the type were already available. Make the dependency a gating
precondition, not an inline assumption.

**S3 — `drive.file` vs `drive.appdata` inconsistency.** The Open question
settles on `drive.file` (user-visible folder, universal support) — good. But
Phase 3's auth-helper step still says "Document which Drive scope to request
(`drive.appdata` vs `drive.file`)", reopening a closed decision. And Phase 4a's
ID-addressed-lease probe contemplates an "app-data single-file lease," which
implies `drive.appdata`. Resolve the tension: if the lease design might require
`drive.appdata`, the scope decision is **not** actually closed and depends on the
Phase 4a outcome — say so. Otherwise commit to `drive.file` everywhere.

**S4 — `upload` resumable threshold contradicts the Open question.** Phase 2's
`upload` step says "use resumable upload for files >5MB", but the Open question
"Resumable uploads" decided **all** uploads use resumable for uniformity. Pick
one and make Phase 2 match the decision. (SSTables routinely exceed L0 flush
size; either path must be tested regardless, but the spec must be internally
consistent.)

**S5 — Folder-ID cache + duplicate names interact dangerously.** The adapter
caches folder IDs by path prefix, and Drive allows duplicate names. If two
`sstables/` folders ever exist (e.g. a racy lazy-create of the hierarchy on
first use from two devices), the cache could bind to either, silently splitting
the remote. The lazy folder-hierarchy creation is itself a create-if-absent
problem with the *same* duplicate-name hazard as the lease. The plan addresses
the lease but is silent on folder creation. Add a probe item (does concurrent
folder create produce duplicates?) and a resolution (e.g. pick lowest-ID /
oldest `createdTime` deterministically, or treat folder bootstrap as a
one-time pre-provisioned step).

**S6 — Conformance-suite import path is unsettled upstream.** Phase 4 runs the
H5 `runSyncAdapterConformance` suite against the Drive adapter. H5's D4 left the
export shape of `test/support/sync_adapter_conformance.dart` as "finalised when
the first downstream package needs it" — and `kmdb_google_drive` is that first
downstream package. So this plan must *settle* that export decision (e.g. a
`package:kmdb/test_support/...` path), not merely consume it. Add an explicit
step.

### Implementation-readiness summary

The golden-path adapter methods (Phase 2) are mostly concrete. The gaps that
would force on-the-fly design decisions are: B1 (which quota interface), B2 (how
the CLI models/constructs the remote across the package boundary), S1 (package
vs `cloud/` placement is a real divergence), S3/S4 (contradictory scope/upload
decisions an implementer can't silently resolve), S5 (folder-create race), and
S6 (conformance export shape). B2 and B1 in particular are not "fill in the
blanks" — they require design choices the implementer should not be inventing.

## Review (kmdb-plan-reviewer, 2026-06-01 — pass 2)

**Verdict: still `Questions`, but for a single, well-understood upstream reason —
not for any Drive-specific gap.** All eight Drive-owned questions from pass 1 are
now resolved with concrete, code-grounded decisions written into the plan. The
one remaining blocker (Q-S2) is an *external* dependency this plan cannot close
on its own.

### What changed since pass 1 (all verified against landed code)

- **H5 is COMPLETE**, not a pending prerequisite. `providesAtomicCas` is a
  per-instance getter on `SyncStorageAdapter`; `ConsolidationCoordinator` gates
  on it; `runSyncAdapterConformance({required factory, required expectAtomicCas})`
  exists at `packages/kmdb/test/support/sync_adapter_conformance.dart`. The plan
  header and prerequisites were corrected to reflect this. The atomicity posture
  the plan relies on is therefore real and landed, which strengthens the design.

- **Q-B1 (quota) resolved by adopting the existing minimal interface and keeping
  it in the test layer.** The richer interface is dropped. Crucially, the
  production `kmdb_google_drive` package takes **no** `kmdb_harness` dependency —
  the simulator implements `QuotaAwareAdapter`. This is cleaner than either pass-1
  option.

- **Q-B2 (CLI seam) fully specified.** Verified the seam against the source:
  `RemoteConfig` is sealed in core `kmdb`; `adapterFor` is an exhaustive switch in
  the CLI; all three call sites (sync/push/pull) are already async, so making
  `adapterFor` async is non-breaking. Config-in-core / construction-in-CLI is the
  only arrangement that respects the package dependency direction, and the plan
  now spells out subtype fields, the `type` string, credential threading, and the
  exhaustive-switch sites that the compiler will force.

- **Q-S3/S4 contradictions removed; Q-S5 folder-race closed** with a
  deterministic oldest-`createdTime`/lowest-ID resolution rule applied to both the
  adapter cache and the simulator; **Q-S6 conformance export** settled as
  `package:kmdb/test_support.dart` (this plan owns that small `kmdb` refactor as
  the first downstream consumer); **Q-S1/B3** corrected.

### The one remaining blocker — Q-S2 (upstream)

`plan_harness_mixed_storage.md` is **still `Questions`** and unimplemented. It
owns, in code that does not yet exist:

- `CloudProfile` (and the unsettled decision of whether it carries an atomicity
  field or derives it from `providesAtomicCas` — that decision is *its* open
  item #3, not this plan's to make);
- the per-device adapter factory and `SharedCloudBackend` the Drive simulator
  must plug into;
- the eventual-consistency reconciliation model the mixed-mode convergence test
  asserts against.

**Phase 4 of this plan hard-depends on all of the above.** Until that plan reaches
`Investigated` and lands, a Sonnet implementer attempting Phase 4 would have to
invent the simulation framework's shape — exactly the on-the-fly design decision
the `Investigated` bar forbids. Phases 1–3 and 5 are mechanically ready in
isolation, but the plan as a whole is not, because its realistic-testing phase
(the one that validates the highest-risk atomicity caveat) is blocked.

### Path to `Investigated` — COMPLETE

`plan_harness_mixed_storage.md` landed (PR #34). The placeholder text in Phase 4
was replaced with the concrete `CloudProfile` field names, the
atomicity-field rule was confirmed (`atomicConditionalCreate` =
`providesAtomicCas`), and Q-S2 was checked off. **Status promoted to
`Investigated`.**

## Open questions

- [x] **Q-B1 — `QuotaAwareAdapter` reconciliation.** RESOLVED: adopt the
      existing minimal `kmdb_harness` interface as-is; drop the richer shape; the
      Drive **simulator** (not the production adapter) implements it so
      `kmdb_google_drive` keeps no dependency on `kmdb_harness`. Investigation
      block + Phase 1b rewritten.
- [x] **Q-B2 — CLI `RemoteConfig` integration.** RESOLVED: `GoogleDriveRemoteConfig`
      (config-only) in core `kmdb` with `type == 'google-drive'`; `adapterFor`
      becomes async and constructs the adapter in the CLI (the only both-package
      layer), loading/refreshing credentials from
      `local/google_credentials.json`. Phase 5 rewritten with the verified seam.
- [x] **Q-B3 — Roadmap target.** RESOLVED: Phase 7 now updates
      `docs/roadmap/0_03.md`.
- [x] **Q-S1 — Package vs `lib/src/sync/cloud/`.** RESOLVED: separate package
      deliberately overrides the roadmap note (heavy OAuth deps); Phase 7
      flags `0_03.md` for the architect to update.
- [x] **Q-S2 — Harness dependency gate.** RESOLVED: `plan_harness_mixed_storage.md`
      landed (PR #34). `CloudProfile` (fields: `consistency`, `atomicConditionalCreate`,
      `allowsDuplicateNames`, `quota`) is now in code at
      `packages/kmdb/lib/src/test_cloud/cloud_profile.dart`, exported via
      `package:kmdb/kmdb_test_cloud_support.dart`. Atomicity-field decision
      settled: `CloudProfile.atomicConditionalCreate` is the field;
      `CloudSemanticsAdapter.providesAtomicCas => profile.atomicConditionalCreate`.
      Phase 4 placeholder text updated with the concrete field names and a
      preliminary Drive `CloudProfile` template (Phase 4a fills in the
      propagation delay and confirms atomicity). Gate cleared.
- [x] **Q-S3 — Drive scope.** RESOLVED: commit to `drive.file` everywhere; the
      lease is constrained to an ID-addressed file *inside the `drive.file` sync
      folder* (not `drive.appdata`). If Phase 4a finds no atomic lease is
      possible under `drive.file`, the adapter declares `providesAtomicCas ==
      false` (loss-free) rather than escalating scope.
- [x] **Q-S4 — Resumable upload uniformity.** RESOLVED: Phase 2 `upload` now uses
      resumable for all uploads; the >5MB threshold is withdrawn.
- [x] **Q-S5 — Folder-create duplicate-name race.** RESOLVED: Phase 4a probes
      concurrent folder creation; deterministic resolution rule (oldest
      `createdTime`, tie-broken by lowest file ID) added to Phase 2 cache and
      Phase 4a, plus simulator modelling of duplicate folders.
- [x] **Q-S6 — Conformance-suite export shape.** RESOLVED: this plan exposes the
      suite from `kmdb`'s `lib/` as `package:kmdb/test_support.dart` (moving it
      out of `test/`) and updates the in-package call sites; added as a Phase 4
      prerequisite step.

## Summary

{Dot points highlighting the work undertaken}
