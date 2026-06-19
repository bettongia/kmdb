# `kmdb_flutter` Add-On Package (Flutter DEK Cache + Native Crypto Acceleration)

**Status**: Investigated

**PR link**: —

## Problem statement

The database encryption plan (`docs/plans/completed/plan_encryption.md`) added
opt-in, value-level AES-256-GCM encryption to `kmdb`. Two Flutter-specific
capabilities were **deliberately deferred** from that plan (see Q3, Q7, and the
"Follow-up: `kmdb_flutter` package" note at the bottom of that plan) because
they cannot live in the pure-Dart `kmdb` package without breaking it:

1. **Persistent DEK session caching.** After a user unlocks an encrypted
   database with their passphrase, the unwrapped Data Encryption Key (DEK)
   should be cached in platform secure storage so the user is **not re-prompted
   for their passphrase on every app launch**. Phase 12 shipped the pure-Dart
   `DekCache` interface and an `InMemoryDekCache` default
   (`packages/kmdb/lib/src/encryption/dek_cache.dart`), but the only concrete
   persistent implementation — backed by `flutter_secure_storage` (Keychain on
   iOS/macOS, Keystore on Android) — has nowhere to live yet. As a result,
   Flutter apps currently fall back to `InMemoryDekCache` and re-prompt every
   session.

2. **Native crypto acceleration.** `kmdb` uses the pure-Dart `cryptography`
   package for AES-256-GCM and Argon2id. The companion `cryptography_flutter`
   plugin registers native platform implementations (iOS Security framework,
   Android Keystore/BoringSSL) that are dramatically faster — the package
   advertises up to ~100× for some operations. Argon2id in particular is
   intentionally CPU-expensive; the pure-Dart path can make passphrase unlock
   noticeably slow on mobile. `cryptography_flutter` is a **drop-in runtime
   accelerator**: a host calls `FlutterCryptography.enable()` once at startup
   and `package:cryptography` transparently routes to the native backend.
   `kmdb`'s crypto works correctly without it — this is purely a performance
   win.

Both belong in a **new, thin, opt-in Flutter add-on package** —
`packages/kmdb_flutter/` — mirroring the existing `kmdb_google_drive` and
`kmdb_icloud` opt-in adapter packages. This plan drafts that package.

### Why a separate package (not in `kmdb`, not a conditional export)

This boundary was analysed and decided in `plan_encryption.md` Q7; restated here
because it is the load-bearing constraint:

- **`kmdb` is pure-Dart.** `packages/kmdb/pubspec.yaml` declares
  `environment: sdk: ^3.12.0` with **no `flutter:` key and no Flutter
  dependencies**. `packages/kmdb_cli/pubspec.yaml` is also pure-Dart and runs
  under plain `dart test`. Adding `flutter_secure_storage` or
  `cryptography_flutter` (both Flutter plugins) to `kmdb` would pull the Flutter
  SDK into the dependency graph, and `dart pub get` / `dart test` for `kmdb` and
  `kmdb_cli` would no longer resolve under plain `dart`. This is the concrete
  regression to avoid.
- **Conditional exports can't express the Flutter boundary.** The
  platform-conditional-export pattern used elsewhere in `kmdb` (§19) switches on
  `dart.library.io` (native) vs `dart.library.js_interop` (web). It **cannot**
  express "Flutter present vs not." A `flutter_secure_storage` import in any
  conditionally-exported file still forces the dependency into `kmdb`'s pubspec.
- **`kmdb_ui` is the wrong home.** `kmdb_ui` is a separate downstream repo
  (`github.com/bettongia/kmdb-ui`), not in this workspace. The DEK cache is a
  capability any Flutter *host* needs, not just the reference UI, so it belongs
  in a workspace package that the UI and other Flutter consumers can both
  depend on.
- **The opt-in add-on pattern is established.** `kmdb_google_drive` and
  `kmdb_icloud` are precedents: small packages depending on `kmdb`, providing a
  platform-specific implementation of a pure-Dart `kmdb` interface.

### Scope

- **In scope:** Flutter hosts — mobile (iOS, Android) and desktop (macOS,
  Windows, Linux) Flutter apps.
- **Out of scope — web.** Per the encryption proposal (§4.3/§6.3) and the
  `DekCache` doc comment, web **re-derives the DEK per session** and does not
  persist it; no secure storage is needed. Flutter web apps should keep using
  `InMemoryDekCache`. `flutter_secure_storage` does have a web implementation,
  but persisting a DEK in browser storage is explicitly **not** the project's
  posture for v1.
- **Out of scope — CLI / headless / tests.** These continue to use
  `InMemoryDekCache` from `kmdb`. They never depend on `kmdb_flutter`.

## Open questions

All five questions are resolved (reviewer pass, 2026-06-19). Decisions and the
evidence behind them are recorded inline; the implementation plan below reflects
them.

- [x] **F1: `flutter_secure_storage` major version.** **Decision: pin
  `flutter_secure_storage: ^10.0.0`** (current stable 10.3.1, 2026-06).
  `kmdb_ui` is a **separate downstream repo**
  (`github.com/bettongia/kmdb-ui`), not part of this workspace, so it cannot
  block resolution here; if it ever locks to 9.x that is the UI repo's
  constraint to reconcile, not this package's. Pinning the current major is the
  right default and matches the "latest stable major that avoids deprecation"
  posture used elsewhere in the repo. Pin `cryptography_flutter: ^2.0.0`
  (current stable 2.3.4) on the same basis. Both are ordinary Flutter-SDK
  dependencies, **not** `betto_*` packages, so they are normal `pubspec.yaml`
  deps and do **not** go in `dependency_overrides`.
- [x] **F2: `dbId` derivation for the secure-storage key.** **Decision: the
  `dbId` is the database directory path — this is already wired in `kmdb` and is
  not a free choice.** Verified against the code:
  - `KmdbDatabase.open(path:)` calls `_runEncryptionBootstrap(store,
    encryptionConfig, path)` (`packages/kmdb/lib/src/query/kmdb_database.dart`
    line ~372), passing the open-time `path` as the `dbId`.
  - The bootstrap then calls `dekCache.store(dbId, dek)` / `dekCache.read(dbId)`
    with that same `path` (lines ~629/645/668).
  - `KmdbDatabase.changePassphrase` clears and re-stores using
    `info.dbDir` (lines ~1092/1094), and `StoreInfo.dbDir ==
    KvStoreImpl._engine.dbDir == the path passed to open()`
    (`kv_store_impl.dart` line ~413). So open-time and change-passphrase agree
    on the same key.

  `FlutterSecureDekCache` therefore must **not invent its own `dbId`** — it
  receives the database path as the `dbId` argument on every call and must key
  storage off it deterministically. Because the raw path contains characters
  that are invalid or awkward in Keychain/Keystore keys (`/`, spaces), the
  implementation must **derive a stable, filesystem/keystore-safe storage key
  from the `dbId`** — `kmdb_dek_<base64Url(utf8(dbId))>` (no padding). base64url
  is reversible, collision-free, and produces a valid key on all platforms;
  hashing is unnecessary and only adds opacity.

  **Accepted limitation (document, do not solve here):** the DEK cache hit
  depends on the database path being byte-identical across launches. On iOS the
  app sandbox container path *can* change (OS restore/migration). If it does,
  `read` returns `null` and the user is re-prompted for their passphrase — a
  graceful degradation, **not** data loss. Stabilising the key across path
  changes is exactly what roadmap 0.07 `PlatformIdStore` is for; this package is
  its first consumer and intentionally does not pre-empt it. Record this caveat
  in the doc comment and in §31's Flutter subsection.
- [x] **F3: Where does `FlutterCryptography.enable()` get called?** **Decision:
  option (a) — an explicit `KmdbFlutter.initialize()` the host calls in
  `main()` after `WidgetsFlutterBinding.ensureInitialized()` and before
  `runApp()`.** This is host-owned, matches `cryptography_flutter`'s documented
  usage, and lets a host enable native acceleration independently of whether it
  uses the DEK cache. `initialize()` must be idempotent: guard a static
  `bool _initialized` and return early on repeat calls, *and* `enable()` itself
  is safe to call more than once (it re-assigns the `Cryptography.instance`
  singleton). **Implementer note:** the exact entry point in
  `cryptography_flutter` is `FlutterCryptography.enable()` (per
  `docs/proposals/encryption.md` §5.2/§6.2); confirm the precise method name and
  signature against the pinned `^2.0.0` API at implementation time and adjust if
  the package has renamed it.
- [x] **F4: `flutter_secure_storage` platform configuration surface.**
  **Decision: hard-code secure defaults, and accept caller-supplied
  `IOSOptions`/`AndroidOptions`/`MacOsOptions` overrides via optional
  constructor parameters.** The DEK is highly sensitive, so the defaults must
  be:
  - iOS/macOS: `accessibility: KeychainAccessibility.first_unlock_this_device`
    (available after first unlock, **never** synced to iCloud Keychain — set the
    "this device" variant explicitly so the DEK never leaves the device).
  - Android: `AndroidOptions(encryptedSharedPreferences: true)` (use the
    EncryptedSharedPreferences backend, not plain prefs).

  Confirm the exact enum/option names against the pinned `^10.0.0` API at
  implementation time (10.x reworked the options surface; e.g. accessibility
  enum member names may differ). The override parameters let a host tighten
  further (e.g. biometric-gated access) without this package re-rolling the
  options model.
- [x] **F5: Testing strategy without a device.** **Decision: two layers.**
  1. **Automated (in-suite):** unit-test `FlutterSecureDekCache` against
     `flutter_secure_storage`'s mock surface
     (`FlutterSecureStorage.setMockInitialValues({})` plus the
     `flutter_test` `TestWidgetsFlutterBinding`) — this is sufficient to cover
     key namespacing/derivation, base64 encode/decode of the DEK, defensive-copy
     on `read`, `clear` removal, and multi-`dbId` isolation, because the mock
     intercepts the platform channel. Unit-test `KmdbFlutter.initialize()`
     idempotency by asserting it can be called twice without throwing (the
     native channel is mocked/absent under `flutter_test`, so assert it
     degrades/guards rather than that native crypto is actually installed).
     These tests live under `packages/kmdb_flutter/test/` and run via
     `flutter test` (this package is **outside** the Dart workspace — see F-pkg
     below — so it is not picked up by `melos test_dart`; it runs in the
     Flutter-capable CI lane alongside `kmdb_icloud`).
  2. **Release checklist (cannot run headless):** the real-device round-trip —
     store DEK → kill app → relaunch → `read` returns the DEK without
     re-prompting; plus verifying native crypto acceleration is actually active
     on a real device — go to `docs/spec/28_release_checklist.md` as **RC-17**
     (next free number; latest is RC-16). Per `docs/plans/README.md` item 4.

- [x] **F-pkg (raised during review): the package is NOT a workspace member.**
  The plan's Phase 1 said `resolution: workspace`. **That is wrong** and
  contradicts the root `pubspec.yaml`, which **explicitly excludes Flutter
  packages from the Dart workspace** ("kmdb_icloud and kmdb_icloud/example are
  Flutter plugins and are NOT part of the Dart workspace … `flutter: sdk:
  flutter` … requires the Flutter SDK — something Dart-only CI runners do not
  have"). `kmdb_flutter` pulls `flutter: sdk: flutter` (transitively via
  `flutter_secure_storage`/`cryptography_flutter`) for the **same reason** and
  must follow the `kmdb_icloud` model, not the `kmdb_google_drive` model:
  - **No** `resolution: workspace`.
  - **Not** added to the root `pubspec.yaml` `workspace:` list.
  - `kmdb` (and `kmdb_harness` if used) referenced via **path deps**
    (`kmdb: { path: ../kmdb }`).
  - **Mirror** the root `dependency_overrides` block (the `betto_*`,
    `meta`/`uuid`/`cbor`/`web` pins, plus `kmdb: { path: ../kmdb }`) so
    transitive `betto_*` deps resolve to the same versions as the rest of the
    repo, exactly as `kmdb_icloud/pubspec.yaml` does.
  - Like `kmdb_icloud`, it is bootstrapped separately when Flutter is available
    (the Flutter-capable CI job / local dev with Flutter), not by the Dart-only
    `dart pub get`/`melos bootstrap` on Linux/Windows runners.

## Investigation

> Reviewer pass complete (2026-06-19). F1–F5 are resolved above, plus a new
> F-pkg correction (the package is NOT a workspace member). The encryption
> plan's Q3/Q7 did the architectural investigation for the boundary; this pass
> grounded the `dbId` contract, the pubspec shape, and the testing split in the
> current code. Status: `Investigated`.

### Prior art and dependencies

- **`packages/kmdb/lib/src/encryption/dek_cache.dart`** — the interface to
  implement. `DekCache` has three methods: `Future<void> store(String dbId,
  Uint8List dek)`, `Future<Uint8List?> read(String dbId)`, `Future<void>
  clear(String dbId)`. Its doc comment already names `kmdb_flutter` and
  `FlutterSecureDekCache` as the expected home — this plan fulfils that
  contract. `InMemoryDekCache` (same file) is the default/fallback and stays in
  `kmdb`.
- **`packages/kmdb/lib/src/encryption/encryption_config.dart`** —
  `EncryptionConfig` accepts an optional `DekCache` via the constructor
  parameter **`dekCache`** (default `InMemoryDekCache`; confirmed in code at
  lines ~77/108/166). A Flutter host constructs
  `EncryptionConfig(..., dekCache: FlutterSecureDekCache())`.
- **`dbId` is the database path (confirmed in code).** The encryption bootstrap
  passes `KmdbDatabase.open(path:)` straight through as the `dbId` to
  `DekCache.store`/`read`, and `changePassphrase` uses the identical
  `StoreInfo.dbDir`. `FlutterSecureDekCache` consumes this value; it does not
  derive its own identifier. See F2 for the full trace and the base64url
  key-derivation rule.
- **`packages/kmdb_icloud/pubspec.yaml`** — the correct precedent to mirror: a
  Flutter-SDK-bearing package that is **deliberately NOT a workspace member**
  (no `resolution: workspace`, not in the root `workspace:` list; uses `kmdb:
  { path: ../kmdb }` and a mirrored `dependency_overrides` block). The root
  `pubspec.yaml` documents why: `flutter: sdk: flutter` requires the Flutter SDK,
  which Dart-only CI runners lack. `kmdb_flutter` has the same constraint — see
  F-pkg. (Note: `kmdb_flutter` is **not** itself a platform plugin — it has no
  native code of its own; it only *depends on* `flutter_secure_storage` and
  `cryptography_flutter`, which are the plugins. So it does **not** need the
  `flutter: plugin:` block `kmdb_icloud` has.)
- **`packages/kmdb_google_drive/pubspec.yaml`** — a pure-Dart workspace add-on
  (`resolution: workspace`). **Do NOT mirror this one** for the workspace/pubspec
  shape: it is Dart-only and therefore a workspace member, which `kmdb_flutter`
  cannot be (F-pkg). It remains a useful reference only for the general add-on
  layout (`version`, `publish_to: none`).
- **External packages (latest stable as of 2026-06):**
  `flutter_secure_storage` 10.3.1, `cryptography_flutter` 2.3.4. Both are
  Flutter-SDK packages (not Bettongia `betto_*` packages), so they are added as
  ordinary `pubspec.yaml` dependencies, **not** to the workspace
  `dependency_overrides`.
- **SPM support — confirmed (2026-06-19).** Both dependencies ship
  `Package.swift` manifests and are fully SPM-native; a host app that adds
  `kmdb_flutter` will **not** receive a CocoaPods deprecation warning from
  either plugin. Specifically:
  - `flutter_secure_storage` 10.x delegates its Apple implementation to the
    federated `flutter_secure_storage_darwin` 0.3.2, which ships a single shared
    `darwin/flutter_secure_storage_darwin/Package.swift` covering iOS 12+ and
    macOS 10.14+ (`swift-tools-version: 5.9`, no Flutter framework dependency
    declared — self-contained Swift).
  - `cryptography_flutter` 2.3.4 ships per-platform `ios/cryptography_flutter/
    Package.swift` and `macos/cryptography_flutter/Package.swift`
    (`swift-tools-version: 5.9`).
  This was verified by fetching the packages locally and inspecting their
  directory trees. No action required — noted here so the implementer does not
  need to re-investigate.

### Affected specs / docs

- **`docs/spec/31_encryption.md`** — add a "Flutter integration" subsection: how
  to wire `FlutterSecureDekCache` and `KmdbFlutter.initialize()`. The platform-
  notes section that currently says Flutter hosts *should* inject a secure DEK
  cache can now point at the concrete package. (Take care not to renumber — edit
  in place.)
- **`docs/spec/28_release_checklist.md`** — add **RC-17** (next free number;
  latest is RC-16): the real-device DEK round-trip verification (store → kill →
  relaunch → read without re-prompt) plus, given F3's explicit init,
  confirmation that native crypto acceleration is active on a real device. Use
  the existing RC entry format (Area / Validates / Why not automated / Applies
  when / Prerequisites / Steps / Expected result / Related).
- **`CLAUDE.md`** — repository-layout `kmdb_flutter` entry already added (this
  worktree). Confirm it reflects the final package shape on completion.
- **`docs/roadmap/0_07.md`** — cross-reference: `PlatformIdStore` is slated to
  subsume this package's `DekCache` consumption and device-ID storage. Note
  this package as the first `DekCache` consumer so the 0.07 work has a concrete
  refactor target. (Do not implement `PlatformIdStore` here — deferred per
  `plan_encryption.md` Q3.)

### Non-goals (v1)

- Web DEK persistence (web re-derives per session).
- A general `PlatformIdStore` abstraction (deferred to roadmap 0.07; this
  package's `DekCache` usage becomes its first consumer).
- Native crypto on web (`cryptography_flutter` is mobile/desktop only;
  pure-Dart `cryptography` continues to serve web).
- Biometric-gated DEK release (could be a future enhancement layered on
  `flutter_secure_storage`'s biometric options).

## Implementation plan

> **Note:** do not begin implementation until this plan reaches `Investigated`
> status (F1–F5 resolved by the reviewer).

### Phase 1 — Package skeleton

- [ ] Create `packages/kmdb_flutter/` with `pubspec.yaml`, modelled on
      `packages/kmdb_icloud/pubspec.yaml` (the Flutter-bearing, **non-workspace**
      precedent — see F-pkg):
      - `name: kmdb_flutter`, `version: 0.1.0`, `publish_to: none`.
      - `environment: sdk: ^3.12.0`, `flutter: ">=3.29.0"` (match `kmdb_icloud`).
      - **No `resolution: workspace`** and **do not** add this package to the
        root `pubspec.yaml` `workspace:` list (F-pkg).
      - dependencies: `flutter: { sdk: flutter }`, `kmdb: { path: ../kmdb }`,
        `flutter_secure_storage: ^10.0.0` (F1), `cryptography_flutter: ^2.0.0`
        (F1).
      - dev_dependencies: `flutter_test: { sdk: flutter }`, `lints: ^6.0.0`,
        `flutter_lints` (as appropriate).
      - `dependency_overrides`: **mirror the root `pubspec.yaml` block**
        (`kmdb: { path: ../kmdb }`, `meta`, `uuid`, `cbor`, `web`, and the
        `betto_*` dev pins) exactly as `kmdb_icloud/pubspec.yaml` does, so
        transitive `betto_*` versions match the rest of the repo.
      - **No `flutter: plugin:` block** — this package ships no native code of
        its own (unlike `kmdb_icloud`, which is itself a plugin); it only
        *depends on* the `flutter_secure_storage` / `cryptography_flutter`
        plugins.
- [ ] Add the license header to every Dart file (per `header_template.txt`,
      `{{.Year}}` → 2026).
- [ ] `packages/kmdb_flutter/lib/kmdb_flutter.dart` — barrel export of
      `FlutterSecureDekCache` and `KmdbFlutter`.

### Phase 2 — `FlutterSecureDekCache`

- [ ] `packages/kmdb_flutter/lib/src/flutter_secure_dek_cache.dart`:
      `final class FlutterSecureDekCache implements DekCache` over
      `FlutterSecureStorage`.
- [ ] Derive the secure-storage key deterministically from the `dbId`
      argument (which is the database directory path — F2):
      `kmdb_dek_<base64Url(utf8(dbId))>` without padding. Do **not** invent a
      `dbId`; use the one passed to `store`/`read`/`clear`. Store the DEK
      base64-encoded (the storage API is `String`-valued); decode on `read`.
      Document the path-stability caveat from F2 in the class doc comment
      (path change ⇒ cache miss ⇒ re-prompt, not data loss).
- [ ] Return a defensive copy from `read` (mirror `InMemoryDekCache`).
- [ ] Apply secure-default `IOSOptions`/`AndroidOptions`/`MacOsOptions` (per
      F4): iOS/macOS `accessibility: first_unlock_this_device` (no iCloud
      Keychain sync); Android `encryptedSharedPreferences: true`. Accept
      optional constructor overrides for each so a host can tighten further.
      Confirm exact option/enum names against the pinned `^10.0.0` API.
- [ ] `clear` deletes the entry (invoked by `kmdb encryption change-passphrase`
      via the `DekCache.clear` contract).

### Phase 3 — `KmdbFlutter.initialize()`

- [ ] `packages/kmdb_flutter/lib/src/kmdb_flutter_init.dart`: `KmdbFlutter`
      with a static `initialize()` that calls `FlutterCryptography.enable()`
      (idempotent — safe to call more than once, per F3).
- [ ] Document the call site: host calls it in `main()` before `runApp()`,
      after `WidgetsFlutterBinding.ensureInitialized()`.

### Phase 4 — Tests

- [ ] Unit tests (`flutter_test`) for `FlutterSecureDekCache` against the
      `flutter_secure_storage` mock surface (per F5 — `setMockInitialValues({})`
      + `TestWidgetsFlutterBinding.ensureInitialized()`): store→read round-trip,
      read-miss returns null, clear removes, defensive copy on `read`,
      multi-`dbId` isolation, and base64url key derivation for a path containing
      `/` and spaces.
- [ ] Unit test that `KmdbFlutter.initialize()` is idempotent (callable twice
      without throwing under `flutter_test`).
- [ ] These tests run under `flutter test --coverage` in the Flutter-capable CI
      lane (alongside `kmdb_icloud`), **not** `melos test_dart` — this package
      is outside the Dart workspace (F-pkg).
- [ ] **Coverage gate: ≥ 90% line coverage is the hard minimum; ≥ 95% is the
      target.** This matches the project-wide quality bar (see `make_cicd.mk`
      `cicd_linux_base` which enforces ≥ 90% across the Dart workspace). Because
      `kmdb_flutter` is small (two classes, ~100 lines of Dart), reaching ≥ 95%
      is realistic and expected. The `cicd_flutter` Makefile target (Phase 6)
      enforces this threshold via `lcov --summary` the same way `cicd_linux_base`
      does. Do **not** ship this package with coverage below 90%.
- [ ] Add the real-device round-trip + native-acceleration verification to
      `docs/spec/28_release_checklist.md` as **RC-17** (cannot run headless).
- [ ] Confirm `kmdb` and `kmdb_cli` `dart test` still resolve and pass on a
      Dart-only runner — i.e. adding `kmdb_flutter` to the repo did **not** leak
      the Flutter dependency into the pure-Dart packages or the Dart workspace
      (the whole point of the separate, non-workspace package).

### Phase 5 — Docs

- [ ] Update `docs/spec/31_encryption.md` with the Flutter integration wiring.
- [ ] Add an `example/` showing `KmdbFlutter.initialize()` +
      `EncryptionConfig(dekCache: FlutterSecureDekCache())`.
- [ ] Cross-reference roadmap 0.07 (`PlatformIdStore`) as the future home of
      this `DekCache` consumer.
- [ ] Update CLAUDE.md if the final package shape differs from the entry added
      in the encryption worktree.

### Phase 6 — Makefile / CI alignment

`kmdb_flutter` is outside the Dart workspace and requires Flutter, so it needs
the same treatment `kmdb_icloud` gets: explicit bootstrap in `make prepare` and
its own `cicd_flutter` CI target in `make_cicd.mk`.

- [ ] **`Makefile` `prepare` target** — extend the Flutter detection block to
      also bootstrap `kmdb_flutter` (and its `example/` once one exists):
      ```makefile
      @if command -v flutter >/dev/null 2>&1; then \
          echo "Flutter found — bootstrapping Flutter packages..."; \
          ( cd packages/kmdb_icloud && flutter pub get ); \
          ( cd packages/kmdb_icloud/example && flutter pub get ); \
          ( cd packages/kmdb_flutter && flutter pub get ); \
      else \
          echo "Flutter not found — skipping Flutter packages (iOS/macOS/Android only)"; \
      fi
      ```
- [ ] **`make_cicd.mk` — add `cicd_flutter` target** modelled on `cicd_icloud`,
      with an added coverage gate (≥ 90% hard minimum, ≥ 95% target):
      ```makefile
      # ── kmdb_flutter package ──────────────────────────────────────────────────
      #
      # Verifies the kmdb_flutter add-on package: bootstraps, format-checks Dart
      # sources, analyzes, runs unit tests with coverage, and enforces the ≥ 90%
      # line-coverage threshold (≥ 95% is the target for this small package).
      # Requires the Flutter SDK — run on macOS only (same lane as cicd_icloud).
      cicd_flutter:
          cd packages/kmdb_flutter && flutter pub get
          dart format --output=none --set-exit-if-changed \
              packages/kmdb_flutter/lib packages/kmdb_flutter/test
          cd packages/kmdb_flutter && flutter analyze
          cd packages/kmdb_flutter && flutter test --coverage
          @pct=$$(lcov --summary packages/kmdb_flutter/coverage/lcov.info 2>&1 \
            | grep 'lines\.\.\.\.' | grep -oE '[0-9]+\.[0-9]+' | head -1); \
          echo "kmdb_flutter line coverage: $${pct:-unknown}%"; \
          if [ -z "$$pct" ]; then \
            echo "ERROR: could not parse line coverage"; exit 1; \
          fi; \
          awk -v p="$$pct" \
            'BEGIN { if (p+0 < 90) { printf "FAIL: %.1f%% < 90%% minimum\n", p+0; exit 1 } }'; \
          awk -v p="$$pct" \
            'BEGIN { if (p+0 < 95) { printf "WARN: %.1f%% is below the 95%% target\n", p+0 } }'
      .PHONY: cicd_flutter
      ```
- [ ] **`make_cicd.mk` format scope** — `dart format` can run on Flutter
      packages without the Flutter SDK. Add `packages/kmdb_flutter` to the
      `dart format` invocation in `cicd_linux_base` alongside `kmdb_google_drive`
      so format divergence is caught in the Linux CI lane, not just in
      `cicd_flutter`:
      ```makefile
      dart format --output=none --set-exit-if-changed \
          packages/kmdb packages/kmdb_cli packages/kmdb_harness \
          packages/kmdb_google_drive packages/kmdb_flutter
      ```
      (Analysis and tests still require Flutter and stay in `cicd_flutter`.)
- [ ] Confirm the GitHub Actions workflow (`.github/workflows/cicd.yml`) has a
      macOS job that calls `make cicd_flutter`, paralleling the existing
      `cicd_icloud` job. If `cicd_icloud` already runs on macOS and is the right
      lane, add `make cicd_flutter` as a step there (or a sibling job).

## Summary

{To be completed on implementation.}
