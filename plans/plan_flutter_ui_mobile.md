# Flutter UI — Mobile (iOS and Android)

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

**Prerequisite**: [plan_flutter_ui.md](plan_flutter_ui.md) must be complete
before this plan begins. The responsive layout scaffold from Phase 0 of that
plan is required here.

See also:

- [plan_flutter_ui.md](plan_flutter_ui.md)
- [docs/roadmap/0_02.md](../docs/roadmap/0_02.md)

## Problem statement

The `kmdb_ui` Flutter package targets macOS desktop. This plan extends it to
iOS and Android, validating the KMDB engine on mobile platforms. It is
intentionally separate from [plan_flutter_ui.md](plan_flutter_ui.md) because
mobile feasibility depends on unresolved questions about native FFI compilation
that must be answered before any implementation effort is committed.

Scope constraints carried over from the desktop plan:

- **Sync is desktop-only**: mobile OS restricts arbitrary filesystem directory
  access; push/pull/sync will be hidden on mobile.
- **Semantic search is iOS-only blocker**: `kmdb_inferencing` (ONNX Runtime)
  throws `UnsupportedError` on iOS; semantic search will be suppressed there.
- **Vault**: shown as strings in the document detail view; no blob rendering.

---

## Open questions

- [ ] **`kmdb_zstd` on iOS arm64**: The Zstd FFI package uses
      `native_toolchain_c` (`CBuilder.library`,
      `LinkModePreference.dynamic`). Can it produce a valid `.dylib`/`.a`
      for iOS arm64 via Dart Native Assets? Run
      `flutter build ios --no-codesign` and check for link errors.
      **This is the gating question — do not proceed with iOS work until
      answered.**

- [ ] **`kmdb_zstd` on Android arm64**: Same question for Android. Run
      `flutter build apk` and check the Gradle/NDK build output.

- [ ] **`kmdb_tokenizer_icu` on iOS**: The package loads `libicucore.dylib`
      on iOS (the system-bundled ICU). Does the dynamic load succeed at
      runtime on a real device? Simulator may differ.

- [ ] **`kmdb_tokenizer_icu` on Android**: Loads `libicuuc.so` from the NDK.
      Does the dynamic load succeed on Android arm64?

- [ ] **Lexical-only search on iOS**: With semantic search unavailable, is
      lexical-only search acceptable for v0.02 iOS scope? Proposed answer:
      yes — hide the mode selector on iOS and default to lexical.

- [ ] **Sync on mobile**: The desktop plan hides sync on non-macOS platforms.
      Filesystem-directory sync is not practical on mobile. Cloud-based sync
      drivers (e.g. Google Drive) would make mobile sync viable, but those do not
      exist yet. Sync on mobile is deferred until a cloud adapter is available;
      the "Sync is not available on this platform" placeholder from the desktop
      plan remains in place.

- [ ] **Database path model on mobile**: Mobile apps cannot use a directory
      file picker for arbitrary filesystem paths. Should databases always
      live in `getApplicationDocumentsDirectory()` (named sub-directories),
      or should the app use the iOS Files app / Android Storage Access
      Framework for user-chosen locations? Proposed answer:
      `getApplicationDocumentsDirectory()` for v0.02; revisit if users need
      to share databases between apps.

---

## Investigation

### Mobile feasibility assessment

| Component | iOS | Android | Notes |
|:---|:---|:---|:---|
| `kmdb` core (pure Dart) | Yes | Yes | No platform code in core |
| `kmdb_zstd` (FFI, native_toolchain_c) | Unknown | Unknown | **Gating question** — needs build validation |
| `kmdb_tokenizer_icu` | Likely | Likely | Branches on `Platform.isIOS`/`isAndroid`; needs runtime test |
| `kmdb_inferencing` (ONNX Runtime) | No | Yes | iOS path throws `UnsupportedError` |
| `file_picker` (directory picking) | Limited | Limited | Mobile pickers are file-not-directory oriented; UX redesign needed |
| `PlatformMenuBar` (macOS native menu) | No | No | Conditional on macOS — already planned in desktop Phase 0 |
| `shared_preferences` | Yes | Yes | |
| macOS security-scoped bookmarks | macOS only | N/A | Already guarded in desktop plan |
| Sync (filesystem sync directory) | Not practical | Not practical | Mobile OS sandbox |

### What the desktop plan provides

By the time this plan starts, [plan_flutter_ui.md](plan_flutter_ui.md) will
have delivered:

- An adaptive layout that switches automatically to a navigator-push stack on
  narrow (< 900 px) screens — the mobile navigation model is already wired.
- `PlatformMenuBar` guarded behind `TargetPlatform.macOS`.
- Full document CRUD, search, schema, index, import/export, and sync panels
  (sync guarded by a platform check that shows a placeholder on mobile).

This plan therefore focuses entirely on: build validation, platform scaffolding,
the mobile database path UX, and suppressing unsupported features per platform.

---

## Implementation plan

### Phase 1 — Build validation (must complete before any further work)

- [ ] Add iOS and Android platform folders to `kmdb_ui` via
      `flutter create --platform ios,android .` (run from
      `packages/kmdb_ui/`). Check in the generated shell.

- [ ] Attempt `flutter build ios --no-codesign` and record whether
      `kmdb_zstd` and `kmdb_tokenizer_icu` link successfully.

- [ ] Attempt `flutter build apk` and record whether `kmdb_zstd` and
      `kmdb_tokenizer_icu` link and load successfully.

- [ ] Run a minimal smoke test on a real iOS device (simulator may suppress
      FFI issues): open the app, open a database, list collections. Record
      pass/fail.

- [ ] Run the same smoke test on an Android device.

- [ ] **Decision gate**: If `kmdb_zstd` fails to link on iOS, either (a)
      disable compression on iOS (Zstd is optional — the engine can store
      uncompressed values) or (b) defer iOS support. Document the decision
      before continuing.

### Phase 2 — Mobile database path UX

- [ ] Add `path_provider` to `kmdb_ui` pubspec (it is already a transitive
      dep via `kmdb`; make it explicit).

- [ ] Create `lib/storage/mobile_database_store.dart`: a helper that
      resolves `getApplicationDocumentsDirectory()` and lists
      sub-directories as available databases.

- [ ] On iOS/Android, replace the desktop file-picker database open flow
      with a list of databases from the app documents directory.

- [ ] "New Database" dialog on mobile: asks only for a name; path is
      `getApplicationDocumentsDirectory()/<name>`.

- [ ] Guard the existing `FilePicker.getDirectoryPath()` flow behind
      `defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows`.

### Phase 3 — Suppress unsupported features per platform

- [ ] **Sync**: The desktop plan gates sync buttons behind a macOS platform
      check. Verify the "Sync is not available on this platform" placeholder
      displays correctly on iOS and Android.

- [ ] **Semantic search**: On iOS, hide the search mode selector and default
      to lexical. Use a compile-time or runtime check:
      `defaultTargetPlatform == TargetPlatform.iOS`.

- [ ] **`PlatformMenuBar`**: Verified conditional from the desktop plan.
      Confirm no crash on iOS/Android.

### Phase 4 — Integration smoke tests on device

- [ ] iOS: open a database, create a collection, insert a document, view
      detail, run a lexical search query. Record pass/fail.

- [ ] Android: same sequence. Also verify semantic search works (ONNX
      Runtime is supported on Android).

- [ ] Confirm the adaptive layout navigator-push stack works on a 390 px
      wide iPhone screen (collection list → document list → detail → back).

- [ ] Confirm the adaptive layout navigator-push stack works on a 360 px
      wide Android screen.

---

## Summary

{Dot points highlighting the work undertaken — to be filled in after implementation}
