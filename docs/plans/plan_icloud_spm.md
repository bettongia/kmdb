# Add Swift Package Manager Support to `kmdb_icloud`

**Status**: Investigated

**PR link**: —

## Problem statement

Flutter is deprecating CocoaPods as the primary dependency manager for Flutter
plugins on Apple platforms, replacing it with Swift Package Manager (SPM).
Running `flutter pub get` in the `kmdb_icloud` package now emits a warning:

```
The following plugins do not support Swift Package Manager for macos:
  - kmdb_icloud
This will become an error in a future version of Flutter.
```

The `kmdb_icloud` plugin currently has no `Package.swift` manifest for either
iOS or macOS — only CocoaPods `.podspec` files. This plan adds SPM support to
eliminate the warning before Flutter makes it a hard error. CocoaPods support
is retained simultaneously: both managers resolve to the same Swift source
files (no duplicate copies).

## Open questions

All three questions raised by the plan review (2026-06-19) are now resolved via
inspection of real-world Flutter plugins in the pub cache. See below.

- [x] **Q1 — Verify the `Package.swift` content against Flutter's actual SPM
  plugin template.**
  **Answer (2026-06-19):** Verified against `url_launcher_macos-3.2.5`,
  `cryptography_flutter-2.3.4`, and our own `betto_onnxrt_ios-0.1.0-dev.1` in
  the pub cache, plus Flutter's own `integration_test_macos` plugin in the SDK.
  The correct pattern differs substantially from the original plan:
  - `Package.swift` goes at `<platform>/<plugin_name>/Package.swift`
    (e.g. `macos/kmdb_icloud/Package.swift`), NOT at `macos/Package.swift`.
  - The `dependencies:` array is **empty** — Flutter's build system injects the
    Flutter framework at Xcode build time via build settings; no explicit
    `FlutterMacOS`/`Flutter` product dependency is declared in the manifest.
  - SPM resolves sources from `Sources/<plugin_name>/` by default (no `path:`
    needed). Both podspec and SPM can share the SAME source directory,
    eliminating `Classes/`.
  - Podspecs must be updated to reference the new source location:
    `s.source_files = 'kmdb_icloud/Sources/kmdb_icloud/**/*'`.
  - Product name convention: hyphens replace underscores (`"kmdb-icloud"`).
  - Platform syntax: string form `.macOS("10.15")` / `.iOS("13.0")`.
  - Verified manifests are recorded verbatim in the Implementation plan below.
- [x] **Q2 — `.gitignore` for SPM build artefacts.**
  **Answer:** With `Package.swift` at `macos/kmdb_icloud/Package.swift`, SPM
  artefacts (`.build/`, `.swiftpm/`) appear inside `macos/kmdb_icloud/` and
  `ios/kmdb_icloud/`. Since `dependencies: []`, no `Package.resolved` is
  generated. Add a `.gitignore` in each SPM package subdirectory ignoring
  `.build/` and `.swiftpm/`. The `example/.gitignore` already covers both;
  the plugin package root has none today.
- [x] **Q3 — Does the verification step actually exercise the change?**
  **Answer:** The example app has only `example/macos/` (confirmed; no
  `example/ios/`). The macOS `Package.swift` is exercised by `flutter pub get`
  in the example and by CI (`make cicd_icloud` on `macos-latest`). The iOS
  `Package.swift` is NOT exercised by any automated check. Phase 3 is updated
  to be explicit; the iOS SPM path goes to the release checklist as RC-17.

## Investigation

### Current structure

```
packages/kmdb_icloud/
  ios/
    Classes/ICloudSyncPlugin.swift  ← real file (not a symlink; 28528 bytes)
    kmdb_icloud.podspec             ← s.source_files = 'Classes/**/*'
  macos/
    Classes/ICloudSyncPlugin.swift  ← identical content to ios/Classes/
    kmdb_icloud.podspec             ← s.source_files = 'Classes/**/*'
  pubspec.yaml
```

The iOS and macOS implementations are the same Swift class
(`KmdbIcloudPlugin: NSObject, FlutterPlugin`), differing only in how they
obtain the `binaryMessenger` (a `#if os(macOS)` guard inside
`register(with:)`). They are kept in sync as separate real files rather than a
symlink (the iOS podspec comment says "symlink" but this is stale — both are
real, git-tracked files).

### What SPM support requires (verified against real-world plugins)

Flutter detects SPM support in a plugin by looking for a `Package.swift` at
`<platform>/<plugin_name>/Package.swift` (e.g. `macos/kmdb_icloud/Package.swift`).
No `pubspec.yaml` changes are needed for the per-platform approach.

The Flutter framework is **not** declared as an SPM package dependency.
Flutter's build toolchain injects the Flutter/FlutterMacOS framework at Xcode
build time via build settings (`FRAMEWORK_SEARCH_PATHS`, etc.). The plugin's
`Package.swift` has an empty `dependencies:` array.

**The industry pattern** (verified against `url_launcher_macos`,
`cryptography_flutter`, `betto_onnxrt_ios`, and Flutter's own
`integration_test_macos`):
- `Package.swift` at `<platform>/<plugin_name>/Package.swift`
- Sources at `<platform>/<plugin_name>/Sources/<plugin_name>/`
- **Podspec updated** to point `s.source_files` at the same `Sources/` path
- `Classes/` directories are then obsolete and can be removed
- No `pubspec.yaml` changes required

### Source directory: per-platform vs. shared `darwin/`

Two patterns exist:
- **A. Per-platform** — `ios/kmdb_icloud/Package.swift` +
  `macos/kmdb_icloud/Package.swift`, each with their own `Sources/` directory.
- **B. Shared `darwin/`** — move to `darwin/Sources/kmdb_icloud/`, add
  `sharedDarwinSource: true` to `pubspec.yaml`, one `darwin/Package.swift`.

**Decision: Option A (per-platform).** Matches the established industry
pattern (`url_launcher_macos`, `cryptography_flutter`). Requires two copies of
`ICloudSyncPlugin.swift` (one per platform), but this duplication already
exists — Option A just moves where the copies live and unifies the CocoaPods
and SPM source paths. Option B is better long-term for publication but adds
pubspec churn and a `darwin/` restructure; defer until the package is prepared
for pub.dev.

### Dual CocoaPods + SPM mode

Both managers will use the SAME source files under `Sources/kmdb_icloud/`.
The podspec `s.source_files` path changes from `'Classes/**/*'` to
`'kmdb_icloud/Sources/kmdb_icloud/**/*'`. The `Classes/` directories are
deleted — there is only one copy of the Swift source.

### Key files

| File | Action |
| ---- | ------ |
| `macos/kmdb_icloud/Package.swift` | **Create** — SPM manifest for macOS |
| `macos/kmdb_icloud/Sources/kmdb_icloud/ICloudSyncPlugin.swift` | **Create** — move from `macos/Classes/` |
| `macos/kmdb_icloud/.gitignore` | **Create** — ignore `.build/` and `.swiftpm/` |
| `macos/kmdb_icloud.podspec` | **Update** — `source_files` path |
| `macos/Classes/ICloudSyncPlugin.swift` | **Delete** — replaced by `Sources/` |
| `ios/kmdb_icloud/Package.swift` | **Create** — SPM manifest for iOS |
| `ios/kmdb_icloud/Sources/kmdb_icloud/ICloudSyncPlugin.swift` | **Create** — move from `ios/Classes/` |
| `ios/kmdb_icloud/.gitignore` | **Create** — ignore `.build/` and `.swiftpm/` |
| `ios/kmdb_icloud.podspec` | **Update** — `source_files` path |
| `ios/Classes/ICloudSyncPlugin.swift` | **Delete** — replaced by `Sources/` |
| `pubspec.yaml` | **No change** — per-platform approach needs none |

### Edge cases and risks

- **Podspec `source_files` path.** The relative path in the podspec is
  relative to the podspec file's location (e.g. `macos/kmdb_icloud.podspec`).
  The new path `'kmdb_icloud/Sources/kmdb_icloud/**/*'` resolves to
  `macos/kmdb_icloud/Sources/kmdb_icloud/**/*`. Verify this resolves before
  deleting `Classes/`.
- **Swift tools version.** `swift-tools-version: 5.9` requires Xcode 15+.
  Flutter 3.29+ (our minimum) already requires Xcode 15, so this is not a new
  constraint.
- **`classPrefix` in `pubspec.yaml`.** Retained unchanged — harmless for Swift
  plugins, and removing it adds risk for no benefit.
- **No `Package.resolved`.** With `dependencies: []`, SPM generates no lockfile
  inside the plugin package directories. The consuming app's `Package.resolved`
  is updated by the consumer, not the plugin.
- **macOS example only.** The `example/` app has only `example/macos/` — no
  iOS target. The iOS `Package.swift` is not exercised by any automated check.
  See Phase 3 for how this is handled.
- **iOS simulator architecture.** The current iOS podspec excludes `i386`
  (`EXCLUDED_ARCHS[sdk=iphonesimulator*]`). SPM + Xcode handles architecture
  selection automatically; the exclusion is not needed in the iOS `Package.swift`
  and is omitted.
- **CI observable outcome.** `make cicd_icloud` runs `flutter pub get` in
  both `packages/kmdb_icloud/` and `packages/kmdb_icloud/example/` on
  `macos-latest`. The SPM warning is currently visible there and will disappear
  after this change — a concrete, CI-verifiable outcome (confirmed by reviewer).

## Implementation plan

### Phase 1 — macOS SPM package

- [ ] Create directory `packages/kmdb_icloud/macos/kmdb_icloud/Sources/kmdb_icloud/`.
- [ ] Move `macos/Classes/ICloudSyncPlugin.swift` to
  `macos/kmdb_icloud/Sources/kmdb_icloud/ICloudSyncPlugin.swift`.
- [ ] Create `packages/kmdb_icloud/macos/kmdb_icloud/Package.swift` with the
  following content (verified against `url_launcher_macos-3.2.5` and
  `cryptography_flutter-2.3.4`):
  ```swift
  // swift-tools-version: 5.9
  // The swift-tools-version declares the minimum version of Swift required to build this package.

  import PackageDescription

  let package = Package(
      name: "kmdb_icloud",
      platforms: [
          .macOS("10.15"),
      ],
      products: [
          .library(name: "kmdb-icloud", targets: ["kmdb_icloud"]),
      ],
      dependencies: [],
      targets: [
          .target(
              name: "kmdb_icloud",
              dependencies: []
          ),
      ]
  )
  ```
- [ ] Create `packages/kmdb_icloud/macos/kmdb_icloud/.gitignore`:
  ```
  .build/
  .swiftpm/
  ```
- [ ] Update `packages/kmdb_icloud/macos/kmdb_icloud.podspec`:
  change `s.source_files = 'Classes/**/*'`
  to `s.source_files = 'kmdb_icloud/Sources/kmdb_icloud/**/*'`.
- [ ] Delete `packages/kmdb_icloud/macos/Classes/` directory.
- [ ] Confirm `Package.swift` does not need a license header (it is a Swift
  Package manifest). If `license_check` flags it, add the Apache 2.0 header
  comment at the top (before `// swift-tools-version`).

### Phase 2 — iOS SPM package

- [ ] Create directory `packages/kmdb_icloud/ios/kmdb_icloud/Sources/kmdb_icloud/`.
- [ ] Move `ios/Classes/ICloudSyncPlugin.swift` to
  `ios/kmdb_icloud/Sources/kmdb_icloud/ICloudSyncPlugin.swift`.
- [ ] Create `packages/kmdb_icloud/ios/kmdb_icloud/Package.swift`:
  ```swift
  // swift-tools-version: 5.9
  // The swift-tools-version declares the minimum version of Swift required to build this package.

  import PackageDescription

  let package = Package(
      name: "kmdb_icloud",
      platforms: [
          .iOS("13.0"),
      ],
      products: [
          .library(name: "kmdb-icloud", targets: ["kmdb_icloud"]),
      ],
      dependencies: [],
      targets: [
          .target(
              name: "kmdb_icloud",
              dependencies: []
          ),
      ]
  )
  ```
- [ ] Create `packages/kmdb_icloud/ios/kmdb_icloud/.gitignore`:
  ```
  .build/
  .swiftpm/
  ```
- [ ] Update `packages/kmdb_icloud/ios/kmdb_icloud.podspec`:
  change `s.source_files = 'Classes/**/*'`
  to `s.source_files = 'kmdb_icloud/Sources/kmdb_icloud/**/*'`.
- [ ] Delete `packages/kmdb_icloud/ios/Classes/` directory.

### Phase 3 — Verification

- [ ] Run `flutter pub get` in `packages/kmdb_icloud/` — confirm no SPM warning
  for either platform.
- [ ] Run `flutter pub get` in `packages/kmdb_icloud/example/` — confirm no
  warning (exercises the **macOS** manifest only; no iOS example app exists).
- [ ] Run `cd packages/kmdb_icloud && dart test` — confirm Dart-side tests pass
  (these do not build native code; they validate the Dart channel logic).
- [ ] Add **RC-17** to `docs/spec/28_release_checklist.md` (RC-16 is the current
  last entry). Use the standard entry format:
  - **Area:** `kmdb_icloud` plugin / SPM
  - **Validates:** iOS SPM manifest (`ios/kmdb_icloud/Package.swift`) compiles
    and links the Flutter plugin correctly. macOS is covered by CI; iOS is
    human-only because the example has no iOS target.
  - **Why not automated:** No iOS Simulator CI lane; CloudKit requires a real
    entitlement.
  - **Applies when:** releasing any version of `kmdb_icloud` that includes this
    change or any subsequent Swift source modification.
  - **Steps:** Build and run the example (or any test host app) on an iOS
    Simulator with CocoaPods disabled (`--no-codesign` / SPM-only mode). Confirm
    the plugin registers without linker errors and that `import Flutter` resolves.
  - **Expected result:** App launches; plugin channel responds to a method call.

### Phase 4 — CI check

- [ ] Confirm CI output after the change: look for absence of the SPM warning in
  the `flutter pub get` step of `make cicd_icloud` on `macos-latest`. This step
  was confirmed to run during the review.

## Follow-up (out of scope for this plan)

- **`darwin/` restructuring (Option B):** consolidate the two
  `ICloudSyncPlugin.swift` copies into `darwin/Sources/kmdb_icloud/` with
  `sharedDarwinSource: true`. Appropriate if/when preparing this package for
  pub.dev publication.
- **Drop CocoaPods** once Flutter fully removes support or when all consumers
  have migrated.

## Review (2026-06-19, kmdb-plan-reviewer)

**Verdict: `Questions`, gated on Q1.** The plan was well-scoped and low-risk.
One load-bearing gap blocked `Investigated`: the `Package.swift` content was
asserted but not cited, and the proposed manifest shape (explicit Flutter
framework product dependency, `path: "Classes"`) did not match Flutter's actual
SPM plugin template. All three questions are now resolved by inspection of real-
world pub-cached plugins (see Open Questions above).

Key corrections made after review:
- Package.swift location changed from `macos/Package.swift` → `macos/kmdb_icloud/Package.swift`
- Flutter framework dependency removed from both manifests (`dependencies: []`)
- Source location changed from `Classes/` to `Sources/kmdb_icloud/` (SPM default)
- Podspec `source_files` updated to reference the new `Sources/` path
- `Classes/` directories deleted (CocoaPods and SPM share the same files)
- iOS verification scoped to release checklist only (RC-17); macOS exercised by CI

## Summary

{To be completed on implementation.}
