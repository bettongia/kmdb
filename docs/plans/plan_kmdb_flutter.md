# `kmdb_flutter` Add-On Package (Flutter DEK Cache + Native Crypto Acceleration)

**Status**: Open

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

- [ ] **F1: `flutter_secure_storage` major version.** The encryption plan brief
  referenced `^9.x`, but the current stable is **10.3.1** (10.x changed
  platform options / Android encrypted-shared-preferences handling). Pin
  `^10.x` (latest stable) unless a downstream Flutter consumer (e.g. `kmdb_ui`)
  is locked to 9.x. Confirm against `kmdb_ui`'s constraints before pinning.
- [ ] **F2: `dbId` derivation for the secure-storage key.** `DekCache` keys on a
  `String dbId` that must be **stable across app launches** for the same
  database (otherwise the cached DEK is never found and the user is re-prompted
  anyway). What is the canonical `dbId`? Candidates: the device ID
  (`KvStoreImpl.ensureDeviceId` / `DEVICE_ID` file), a hash of the absolute
  database path, or a value the caller supplies explicitly. Needs a decision so
  `FlutterSecureDekCache` and the encryption bootstrap agree. (Note: device ID
  is per-device, not per-database — if one app opens multiple encrypted DBs,
  path-hash or caller-supplied id is safer. Cross-reference roadmap 0.07
  `PlatformIdStore`, which is slated to unify device-ID and DEK-cache storage.)
- [ ] **F3: Where does `FlutterCryptography.enable()` get called?** Options:
  (a) an explicit `KmdbFlutter.initialize()` the host calls in `main()` before
  `runApp()` (most conventional for Flutter plugins; matches
  `cryptography_flutter`'s documented usage); (b) lazily on first
  `FlutterSecureDekCache` construction. Recommend (a) — explicit, host-owned,
  and lets the host enable native crypto even when not using the DEK cache.
  Confirm idempotency (calling `enable()` twice must be safe).
- [ ] **F4: `flutter_secure_storage` platform configuration surface.** Should
  `FlutterSecureDekCache` expose `IOSOptions` / `AndroidOptions` (e.g.
  `accessibility: first_unlock`, `encryptedSharedPreferences`) for the host to
  tune, or hard-code secure defaults? Recommend exposing them with secure
  defaults (DEK is highly sensitive — default to "this device only, after first
  unlock" accessibility, no iCloud Keychain sync of the DEK).
- [ ] **F5: Testing strategy without a device.** `flutter_secure_storage`
  requires platform channels / a running engine; it cannot be exercised in a
  pure unit test. Decide the split: unit-test the pure logic (key namespacing,
  defensive copies, clear-on-change semantics) against the platform interface's
  mock/`setMockInitialValues` test surface, and record the real-device
  round-trip (store DEK → kill app → relaunch → read DEK) as a **release
  checklist** item in `docs/spec/28_release_checklist.md` (per
  `docs/plans/README.md` item 4 — tests that cannot run in the automated suite
  go to the release checklist). Confirm whether `flutter_test` +
  `flutter_secure_storage`'s `setMockInitialValues` is sufficient for the unit
  layer.

## Investigation

> This section is intentionally light — the plan is `Open`. The encryption
> plan's Q3/Q7 already did the architectural investigation for the boundary.
> The reviewer (`kmdb-plan-reviewer`) should drive this to `Investigated` by
> resolving F1–F5 and confirming the package skeleton below against the current
> `kmdb_google_drive` / `kmdb_icloud` conventions.

### Prior art and dependencies

- **`packages/kmdb/lib/src/encryption/dek_cache.dart`** — the interface to
  implement. `DekCache` has three methods: `Future<void> store(String dbId,
  Uint8List dek)`, `Future<Uint8List?> read(String dbId)`, `Future<void>
  clear(String dbId)`. Its doc comment already names `kmdb_flutter` and
  `FlutterSecureDekCache` as the expected home — this plan fulfils that
  contract. `InMemoryDekCache` (same file) is the default/fallback and stays in
  `kmdb`.
- **`packages/kmdb/lib/src/encryption/`** — `EncryptionConfig` accepts an
  optional `DekCache` (default `InMemoryDekCache`). A Flutter host constructs
  `EncryptionConfig(..., dekCache: FlutterSecureDekCache())`. Confirm the exact
  `EncryptionConfig` constructor parameter name during investigation.
- **`packages/kmdb_icloud/pubspec.yaml`** — the closest precedent for a
  Flutter-plugin-bearing workspace package: `environment.flutter`, a `flutter:`
  SDK dependency, `resolution: workspace`, `publish_to: none`. (Note:
  `kmdb_flutter` is **not** itself a platform plugin — it has no native code of
  its own; it only *depends on* `flutter_secure_storage` and
  `cryptography_flutter`, which are the plugins. So it does **not** need the
  `flutter: plugin:` block `kmdb_icloud` has.)
- **`packages/kmdb_google_drive/pubspec.yaml`** — precedent for a pure
  workspace add-on (`kmdb:` workspace dep, `kmdb_harness:` dev dep). Mirror its
  `version`, `publish_to: none`, `resolution: workspace` conventions.
- **External packages (latest stable as of 2026-06):**
  `flutter_secure_storage` 10.3.1, `cryptography_flutter` 2.3.4. Both are
  Flutter-SDK packages (not Bettongia `betto_*` packages), so they are added as
  ordinary `pubspec.yaml` dependencies, **not** to the workspace
  `dependency_overrides`.

### Affected specs / docs

- **`docs/spec/31_encryption.md`** — add a "Flutter integration" subsection: how
  to wire `FlutterSecureDekCache` and `KmdbFlutter.initialize()`. The platform-
  notes section that currently says Flutter hosts *should* inject a secure DEK
  cache can now point at the concrete package. (Take care not to renumber — edit
  in place.)
- **`docs/spec/28_release_checklist.md`** — add the real-device DEK
  round-trip verification (F5) and, if F3 lands on explicit init, a note that
  native crypto acceleration is verified on a real device.
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

- [ ] Create `packages/kmdb_flutter/` with `pubspec.yaml`:
      `name: kmdb_flutter`, `publish_to: none`, `resolution: workspace`,
      `environment: sdk: ^3.12.0`, `flutter: ">=3.29.0"` (match `kmdb_icloud`);
      dependencies `flutter: { sdk: flutter }`, `kmdb:`,
      `flutter_secure_storage: ^10.x` (pending F1),
      `cryptography_flutter: ^2.x`; dev_dependencies `flutter_test: { sdk:
      flutter }`, `lints`, `flutter_lints` (as appropriate). **No `flutter:
      plugin:` block** — this package ships no native code of its own.
- [ ] Add the license header to every Dart file (per `header_template.txt`,
      `{{.Year}}` → 2026).
- [ ] `packages/kmdb_flutter/lib/kmdb_flutter.dart` — barrel export of
      `FlutterSecureDekCache` and `KmdbFlutter`.

### Phase 2 — `FlutterSecureDekCache`

- [ ] `packages/kmdb_flutter/lib/src/flutter_secure_dek_cache.dart`:
      `final class FlutterSecureDekCache implements DekCache` over
      `FlutterSecureStorage`.
- [ ] Namespace the secure-storage key (e.g. `kmdb_dek_<dbId>`) so multiple
      databases coexist (per F2 resolution); store the DEK base64-encoded (the
      storage API is `String`-valued).
- [ ] Return a defensive copy from `read` (mirror `InMemoryDekCache`).
- [ ] Expose secure-default `IOSOptions`/`AndroidOptions` (per F4); ensure the
      DEK is **not** synced to iCloud Keychain.
- [ ] `clear` deletes the entry (invoked by `kmdb encryption change-passphrase`
      via the `DekCache.clear` contract).

### Phase 3 — `KmdbFlutter.initialize()`

- [ ] `packages/kmdb_flutter/lib/src/kmdb_flutter_init.dart`: `KmdbFlutter`
      with a static `initialize()` that calls `FlutterCryptography.enable()`
      (idempotent — safe to call more than once, per F3).
- [ ] Document the call site: host calls it in `main()` before `runApp()`,
      after `WidgetsFlutterBinding.ensureInitialized()`.

### Phase 4 — Tests

- [ ] Unit tests (flutter_test) for `FlutterSecureDekCache` against the
      `flutter_secure_storage` mock surface (per F5): store→read round-trip,
      read-miss returns null, clear removes, defensive copy, multi-`dbId`
      isolation.
- [ ] Unit test that `KmdbFlutter.initialize()` is idempotent.
- [ ] Add the real-device round-trip (store DEK → relaunch → read) to
      `docs/spec/28_release_checklist.md` (cannot run headless).
- [ ] Confirm `kmdb` and `kmdb_cli` `dart test` still resolve and pass —
      i.e. the Flutter dependency did **not** leak into the pure-Dart packages
      (the whole point of the separate package).

### Phase 5 — Docs

- [ ] Update `docs/spec/31_encryption.md` with the Flutter integration wiring.
- [ ] Add an `example/` showing `KmdbFlutter.initialize()` +
      `EncryptionConfig(dekCache: FlutterSecureDekCache())`.
- [ ] Cross-reference roadmap 0.07 (`PlatformIdStore`) as the future home of
      this `DekCache` consumer.
- [ ] Update CLAUDE.md if the final package shape differs from the entry added
      in the encryption worktree.

## Summary

{To be completed on implementation.}
