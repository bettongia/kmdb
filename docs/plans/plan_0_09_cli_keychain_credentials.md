# `kmdb_cli` cloud sync credentials: OS keychain storage

**Status**: Questions

**PR link**: —

## Problem statement

`packages/kmdb_cli/lib/src/commands/remote_command.dart` (`_authoriseGoogleDrive`)
and `packages/kmdb_cli/lib/src/config/remote_config.dart`
(`_loadGoogleDriveAuthClient`) store Google Drive OAuth credentials
(`AccessCredentials.toJson()` plus `client_id`/`client_secret`) as plaintext
JSON at `{dbDir}/local/{credentialsPath}` (default `google_credentials.json`).
This is a per-machine, non-synced, CLI-only file — it never touches the
database encryption boundary — but anyone with filesystem access to that
directory can read a live OAuth token and act as the user against their Drive
account.

This is a deliberately deferred gap: `docs/spec/31_encryption.md` gap 9
records it as "accepted, out of scope" for the Encryption confidentiality
reconciliation plan (`plan_0_08_encryption_confidentiality_reconciliation.md`,
Q7), explicitly naming a future CLI-hardening item — this one — as the right
place to close it.

**Fix (per `docs/roadmap/0_09.md`):** store CLI-managed cloud credentials in
the OS-native credential store — macOS Keychain, Windows Credential Manager,
Linux Secret Service — with a plaintext-file fallback (todays's behaviour)
only when no OS store is reachable, and an explicit warning whenever that
fallback is used. CLI-only; no `kmdb` core, `EncryptionProvider`, or synced
surface is touched.

**Scope confirmed with `kmdb-architect`:** the Google Drive OAuth blob is the
only CLI-managed secret in the codebase today. `local/config.json` (remote
names/paths), `repl_config.dart`, and `history.dart` write only non-secret
state, so no other credential type needs migrating.

## Open questions

- [ ] **Q1 — macOS backend: `security` CLI subprocess vs. Security.framework
      FFI.** Shelling out to the bundled `/usr/bin/security` CLI
      (`add-generic-password` / `find-generic-password` /
      `delete-generic-password`) is simple, needs no new dependency, and is
      the pattern used by `git-credential-osxkeychain`, GitHub CLI, and
      others. Its one real drawback: the secret is passed via `-w <value>`,
      which is briefly visible in that process's argv (e.g. via `ps` or
      `/proc`) to other processes running as the same local user during
      execution. The alternative — hand-written `dart:ffi` bindings to
      `Security.framework` (`SecItemAdd`/`SecItemCopyMatching`/
      `SecItemDelete`) — avoids that window entirely but adds a
      CoreFoundation/FFI binding surface we'd own and maintain, for a single
      call site. **Recommendation:** subprocess for v1 (lower implementation
      risk, strong precedent, and the exposure window is a local-user-only,
      execution-duration-only risk — a real but bounded downgrade from the
      current *permanent* plaintext file). Revisit as a follow-up if this is
      judged unacceptable.
- [ ] **Q2 — Auto-migrate legacy plaintext credentials on first read.** Once
      this ships, existing databases still have a plaintext
      `local/google_credentials.json`. Recommendation: on read
      (`_loadGoogleDriveAuthClient`), if the native store has no entry, fall
      back to reading the legacy plaintext file (if present); on success,
      opportunistically write it into the native store, delete the plaintext
      file, and print a one-time confirmation ("Migrated Google Drive
      credentials to the OS keychain."). This closes the exposure on next use
      without forcing a re-auth. Alternative: require the user to re-run
      `remote add` to opt in (simpler, but leaves old databases exposed
      indefinitely unless the user knows to act).
- [ ] **Q3 — Fallback-warning frequency.** Print the plaintext-fallback
      warning on every CLI invocation that reads or writes via that path
      (stateless, simple), or only once (needs a persisted "seen" flag).
      Recommendation: every invocation — a security warning that's easy to
      dismiss once is worse than a recurring one, and statelessness avoids
      another small piece of persisted CLI state to get wrong.
- [ ] **Q4 — How the 3 real native backends get verified.** macOS/Windows CI
      keychains may require interactive unlock; Linux CI images typically
      have no D-Bus session bus / Secret Service daemon running at all —
      which is also precisely the "headless" case the fallback exists for.
      None of the three real backends can be reliably exercised in the
      standard `dart test` matrix. Recommendation: unit-test the
      store-selection/fallback/env-override/account-key logic via an
      injectable `CredentialStore` and a `FakeCredentialStore` test double
      (full coverage, no real OS dependency), and verify the three real
      backends via a new release-checklist entry (§28, next free `RC-N`) —
      the same treatment RC-4 (Linux power-loss) and RC-6 (multi-device
      tombstone) already get for real-OS checks. The concrete backend classes
      (`MacosKeychainCredentialStore`, `WindowsCredentialManagerStore`,
      `LinuxSecretServiceCredentialStore`) get `// coverage:ignore` markers on
      their OS-calling bodies, mirroring `_authoriseGoogleDrive`'s existing
      treatment — confirm this is acceptable against the 90%/95% coverage bar
      before implementation starts.
- [ ] **Q5 — Fate of `GoogleDriveRemoteConfig.credentialsPath`.** This field
      (in `packages/kmdb/lib/src/config/remote_config.dart`, `kmdb` core) is
      "vestigial" in the sense that keychain storage doesn't need a file
      path — but it still does useful work: it's the plaintext-fallback
      filename, and it's the piece that makes two `google-drive` remotes on
      the same database (each with an explicit `--credentials`) address
      distinct credential entries. Recommendation: keep the field and its
      JSON shape unchanged (no config-format break), but reframe its doc
      comment from "cached OAuth credentials file" to "credential identifier
      — used as the plaintext-fallback filename and as a component of the
      OS-keychain account key."
- [ ] **Q6 — Explicit backend override.** Add a `KMDB_CLI_CREDENTIAL_STORE`
      env var (`keychain` / `plaintext`) so CI and locked-down hosts can force
      a deterministic choice instead of relying on native-store-failure
      detection alone? Recommendation: yes — it also gives the release
      checklist (Q4) a documented way to exercise the fallback path on
      demand, and gives users on a genuinely headless/no-DE Linux box a way
      to silence the auto-probe and go straight to plaintext (with the
      warning still printed).

## Investigation

### Current write/read/refresh sites

- **Write:** `RemoteCommand._authoriseGoogleDrive`
  (`packages/kmdb_cli/lib/src/commands/remote_command.dart:277-333`, already
  `// coverage:ignore`'d as it needs a real browser) — writes
  `{...credentials.toJson(), 'client_id': ..., 'client_secret': ...}` as JSON
  to `{dbDir}/local/{credentialsPath}`.
- **Read + refresh-rewrite:** `_loadGoogleDriveAuthClient`
  (`packages/kmdb_cli/lib/src/config/remote_config.dart:75-124`) — reads the
  file, and on `hasExpired`, refreshes and rewrites it in place (the
  `refreshCredentials` branch, also `coverage:ignore`'d).
- **Leak found during grounding:** `RemoteCommand._remove`
  (`remote_command.dart:197-231`) deletes the `config.json` entry but never
  deletes the credentials file itself — fixing this is now in scope (see
  Implementation plan).

### Package survey

Searched pub.dev and confirmed via direct doc fetch before committing to any
dependency:

| Platform | Chosen approach | Why |
| :------- | :--------------- | :-- |
| Windows | `package:win32` (`CredWrite`/`CredRead`/`CredDelete`/`CredFree`, `advapi32` topic) | Mature (halildurmus.dev, 6.4M downloads, 948 likes), pure Dart FFI to an **already-present system DLL** — no compilation step, no native-asset build hook. Confirmed via doc fetch that all four `Cred*` functions are exposed. |
| Linux | `package:dbus` (canonical.com, 5.3M downloads) implementing the freedesktop Secret Service D-Bus API (`org.freedesktop.secrets`) directly | Mature, pure-Dart, protocol-level — talks to whichever Secret Service provider is registered (GNOME Keyring, KDE's `ksecretd`, KeePassXC's integration, etc.) without depending on a specific desktop's CLI binary being installed. No native-asset build hook. |
| macOS | Subprocess to the bundled `/usr/bin/security` CLI | No mature pure-Dart FFI wrapper for `Security.framework` exists on pub.dev today (searched directly; nothing found). See Q1 for the accepted trade-off. |
| Fallback | `PlaintextFileCredentialStore` — today's exact file/location, refactored into the new interface | Zero behaviour change for the fallback path; keeps existing plaintext-fixture tests passing unchanged (see Testing below). |

**Rejected:**
- `keyring`/`keyring_native` (kingwill101) — the closest-looking off-the-shelf
  fit (cross-platform umbrella API, `KeyringEntry`/`setPassword`/
  `getPassword`). Rejected because its native layer is Rust, built via
  `native_toolchain_rust` — this is exactly the "native-asset build hook
  mismatch with the rest of the workspace" risk the roadmap item's own open
  questions warn about, it would add a **second** native toolchain
  requirement (Rust, alongside the existing FFI/C toolchain for
  `betto_zstd`) to every contributor's and CI's build environment, and the
  package itself is early-stage (0 stars, 5 commits, no docs on precompiled
  binaries) — too immature for a security-critical dependency.
- `flutter_secure_storage`, `crossvault`, `simple_secure_storage`,
  `biometric_storage` — all Flutter plugins; `kmdb_cli` is pure Dart
  (`dart:io`, no Flutter engine), so none of these are usable here at all.
  (`FlutterSecureDekCache` in `kmdb_flutter` is the in-repo precedent for
  *how* to shape this kind of cache, but it is Flutter-only and caches a
  different secret — the DEK, not OAuth tokens — so it's a pattern
  reference, not a reusable dependency.)
- `dbus_secrets` — does implement Secret Service on top of `dbus`, but is a
  single-maintainer, v0.0.2, 153-download wrapper. Given this is a
  security-critical local secret store, implementing the small Secret
  Service subset we need (open session, create/replace item, get secret,
  delete item — roughly 4 D-Bus calls) directly on the well-audited `dbus`
  package keeps the trust boundary on Canonical's package and the stable,
  documented freedesktop protocol, not on an obscure thin wrapper.

### Design

New interface, `packages/kmdb_cli/lib/src/config/credential_store.dart`:

```dart
abstract interface class CredentialStore {
  Future<void> write(String account, String secretJson);
  Future<String?> read(String account);
  Future<void> delete(String account);

  static Future<CredentialStore> forPlatform({required String dbDir}) async {
    // 1. KMDB_CLI_CREDENTIAL_STORE env var override (Q6), if set.
    // 2. Otherwise dispatch on Platform.operatingSystem to the native
    //    backend, wrapped so any failure (locked keychain, no D-Bus
    //    session, etc.) falls back to PlaintextFileCredentialStore with a
    //    warning (Q3) rather than propagating.
  }
}
```

Implementations, one file each under
`packages/kmdb_cli/lib/src/config/credential_store/`:
`macos_keychain_credential_store.dart`,
`windows_credential_manager_store.dart`,
`linux_secret_service_credential_store.dart`,
`plaintext_file_credential_store.dart` (extracted from today's inline
file-read/write logic — same path, same JSON shape, so its round-trip
behaviour is unchanged from today).

**Account-key derivation:** reuse the reversible, collision-free scheme
`FlutterSecureDekCache` already established for deriving a storage-safe key
from a filesystem path (`kmdb_flutter/lib/src/flutter_secure_dek_cache.dart`)
— `base64Url(utf8(dbDir))` — combined with `credentialsPath`, so two
`google-drive` remotes on the same database with distinct `--credentials`
values (today's existing mechanism for avoiding collisions) continue to
address distinct entries under keychain storage too.

**Wiring:** `adapterFor` and `RemoteCommand` gain an injectable
`CredentialStore` parameter (defaulting to `CredentialStore.forPlatform`),
giving tests a seam without changing any call site outside test code.

### Testing implications (ties to Q4)

The existing fixture pattern — tests write a plaintext JSON file directly to
`{dbDir}/local/google_credentials.json` and call `adapterFor`
(`adapter_for_test.dart:102-103`, `:117`, `:129`) — keeps working unchanged:
under the new design, the (non-overridden, real) native store will have no
entry for these synthetic test `dbDir` values, so `_loadGoogleDriveAuthClient`
falls through to the legacy-plaintext read exactly as today. New tests inject
a `FakeCredentialStore` (in-memory `Map`, test-only, under
`packages/kmdb_cli/test/support/`) to cover the store-selection, fallback,
override, migration-on-read, and account-key logic without touching a real
OS credential store.

### Spec and doc updates

- New `docs/spec/NN_cli_credential_store.md` (assign the actual next free
  number — `33` as of this writing — at implementation time per
  `docs/plans/README.md`'s numbering rule) documenting the `CredentialStore`
  interface, the three native backends plus fallback, the account-key
  derivation, the env-var override, and the migration-on-read behaviour.
- Update `docs/spec/31_encryption.md` gap 9 to point at the new section and
  mark the gap resolved (it currently ends with "a future CLI-hardening item
  ... is the appropriate place to close this" — this plan is that item).
- Add a `docs/spec/99_glossary.md` entry for "credential store" /
  `CredentialStore`.
- Update `packages/kmdb_cli/README.md`'s `remote add`/`remote remove`
  sections to mention where credentials are actually stored and that
  `remote remove` now deletes them.

## Implementation plan

- [ ] Resolve Q1–Q6 (or accept the stated recommendations) before writing
      code.
- [ ] Add `win32` and `dbus` as regular dependencies to
      `packages/kmdb_cli/pubspec.yaml`. Confirm neither triggers a
      native-asset build hook (per the Native-asset hooks note in
      `CLAUDE.md`) — both are expected to import cleanly on all three
      desktop platforms, gating actual OS calls behind `Platform.isX`
      checks at runtime.
- [ ] Define the `CredentialStore` interface with full doc comments
      (`packages/kmdb_cli/lib/src/config/credential_store.dart`).
- [ ] Implement `PlaintextFileCredentialStore`, extracted from today's inline
      logic in `remote_config.dart`/`remote_command.dart` — same file
      location and JSON shape, zero behaviour change.
- [ ] Implement `MacosKeychainCredentialStore` (subprocess to `security`;
      `// coverage:ignore` the OS-calling bodies per Q4).
- [ ] Implement `WindowsCredentialManagerStore` (`win32` `Cred*` FFI calls;
      `// coverage:ignore` the OS-calling bodies per Q4).
- [ ] Implement `LinuxSecretServiceCredentialStore` (`dbus` package,
      freedesktop Secret Service calls; `// coverage:ignore` the OS-calling
      bodies per Q4).
- [ ] Implement `CredentialStore.forPlatform`: env-var override (Q6) →
      platform dispatch → try native, catch → fall back to
      `PlaintextFileCredentialStore` + stderr warning (Q3).
- [ ] Wire into `RemoteCommand._authoriseGoogleDrive` (write) and
      `_loadGoogleDriveAuthClient` (read + refresh-rewrite), including
      migration-on-read from a legacy plaintext file (Q2).
- [ ] Fix `RemoteCommand._remove` to delete the stored credentials
      (`CredentialStore.delete` plus legacy plaintext file cleanup if
      present) — closes the leak found during grounding.
- [ ] Add `FakeCredentialStore` test double
      (`packages/kmdb_cli/test/support/fake_credential_store.dart`) and the
      injection seam on `adapterFor`/`RemoteCommand`.
- [ ] Confirm existing plaintext-fixture tests
      (`adapter_for_test.dart`, `remote_config_test.dart`,
      `remote_command_test.dart`, `kmdb_config_test.dart`,
      `cli_runner_inprocess_test.dart`) still pass unchanged via the
      legacy-fallback-read path; adjust only if a test's setup conflicts with
      the new default `forPlatform` seam (e.g. needs explicit
      `FakeCredentialStore` injection instead of relying on real-store-miss
      fallthrough).
- [ ] New tests: store-selection/env-override/fallback logic; account-key
      derivation (collision-free, reversible); `PlaintextFileCredentialStore`
      round-trip; `remote remove` deletes credentials (both backends);
      migration-on-read (plaintext → native store, file deleted, message
      printed once).
- [ ] Write `docs/spec/NN_cli_credential_store.md` (assign number at write
      time); update §31 gap 9 and §99 glossary. Run `make site` after
      editing spec files.
- [ ] Update `packages/kmdb_cli/README.md` (`remote add`/`remote remove`
      sections).
- [ ] Add release-checklist entry (§28, next free `RC-N`) covering manual
      round-trip verification on macOS (Keychain Access.app inspection),
      Windows (Credential Manager UI), and Linux (`secret-tool search` /
      `seahorse`), plus confirming `remote remove` deletes the entry on each
      platform.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files (mind the
      `coverage:ignore` markers agreed in Q4).
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

## Reviewer feedback (2026-07-16, kmdb-plan-reviewer)

**Verdict: strong problem statement and investigation, not yet `Investigated`.**
The framing is correct, the scope is genuinely confined (verified: the Google
Drive OAuth blob is the only CLI-managed secret; `local/config.json`,
`repl_config.dart`, `history.dart` hold no secrets), the leak in `_remove` is
real (verified — it deletes the `config.json` entry but never the credentials
file), and the package survey is excellent: the `keyring`/Rust-toolchain and
Flutter-plugin rejections are well-reasoned and the `win32`/`dbus`/`security`
choices are the right shape. The `FlutterSecureDekCache`
`base64Url(utf8(dbId))` precedent and the §31 gap-9 lineage both check out. The
Q1–Q6 recommendations are all defensible and I endorse them as written.

What holds it back from `Investigated` is the **Design** section: an implementer
would hit several unspecified decisions immediately. These are design details
(mine to drive out), not user policy calls (Q1–Q6), so I've captured them as a
blocking checklist below rather than as new user questions. Close them and the
plan clears the bar.

### Blocking design gaps — resolve before `Investigated`

- [ ] **D1 — The injection seam as described cannot compile / is
      architecturally misplaced.** The plan says "`adapterFor` and
      `RemoteCommand` gain an injectable `CredentialStore` parameter (defaulting
      to `CredentialStore.forPlatform`)." Three problems: (a)
      `CredentialStore.forPlatform` is an `async` factory returning
      `Future<CredentialStore>`, so it cannot be a default parameter value
      (defaults must be compile-time constants). (b) `RemoteCommand` is
      registered as `const RemoteCommand()` in the command list
      (`cli_runner.dart:87`); adding an injected field breaks the const
      construction. (c) `forPlatform` needs `dbDir`, which is only known at
      `execute()` time (from `ctx.store.storeInfo()`), *after* the command is
      constructed — so construction-time injection is impossible regardless.
      Specify the real seam: resolve the store *inside* `execute()`/`_add`/
      `_remove` (and inside `adapterFor`, which already has `dbDir`), taking an
      **optional nullable `CredentialStore?` override** that defaults to `null`
      and is replaced by `await CredentialStore.forPlatform(dbDir: dbDir)` when
      absent. Name exactly where the override is threaded for `RemoteCommand`
      (it isn't a constructor param — likely an extra optional method arg or a
      field on `CommandContext`) and how `adapterFor`'s new optional param is
      passed from `sync`/`push`/`pull` (which call `adapterFor(remote,
      dbDir: dbDir)` today).

- [ ] **D2 — Tests must never touch the real OS backend; make injection the
      default, not the fallback.** The Testing section leans on "the real native
      store will have no entry for synthetic test `dbDir` values, so it falls
      through to legacy-plaintext read." That means the *default* test path
      invokes the real macOS `security` subprocess / real D-Bus / real
      `CredRead` during `dart test`. That is slow, side-effecting, can prompt a
      developer's Keychain to unlock, risks writing into a developer's real
      Keychain during the migration-on-read test, and on a CI Linux box with no
      D-Bus session prints the fallback warning on every credential test. Invert
      it: credential-touching tests must **always** inject a `FakeCredentialStore`
      (or set `KMDB_CLI_CREDENTIAL_STORE=plaintext` per Q6) so no test ever
      reaches a real backend. Rewrite the "adjust only if a test's setup
      conflicts" checklist item to make explicit injection the rule for these
      tests, not an afterthought.

- [ ] **D3 — Pin the exact account-key derivation.** "`base64Url(utf8(dbDir))`
      combined with `credentialsPath`" is under-specified: *combined how?* Bare
      concatenation reintroduces exactly the separator-ambiguity the roadmap
      already flags for `indexToken` (0_09 housekeeping). Specify the exact
      construction (separator/encoding) so it is collision-free and two
      implementers produce identical keys. Also specify the **service/account
      split per backend**, since the interface's single `account` string must
      map onto each native API's identifiers: macOS `security -s <service>
      -a <account>`; win32 `CredWrite` `TargetName`; Secret Service attribute
      map. Pin a constant service name (e.g. `"kmdb-cli"`) so entries are
      discoverable via Keychain Access / `secret-tool` for the RC verification.

- [ ] **D4 — Specify overwrite/update semantics.** The refresh-rewrite path
      (`_loadGoogleDriveAuthClient`, `hasExpired` branch) rewrites credentials
      in place, so `CredentialStore.write` **must overwrite** an existing entry.
      This is a real correctness detail per backend: macOS
      `add-generic-password` errors on a duplicate unless `-U` is passed (or the
      entry is deleted first); win32 `CredWrite` overwrites by default; Secret
      Service `CreateItem` with `replace: true`. State that `write` is
      upsert semantics and how each backend achieves it.

- [ ] **D5 — Specify migration-on-read crash ordering (Q2).** Define the order:
      write-to-native → confirm success → delete plaintext → print once. Say
      what happens if the process dies between native-write and plaintext-delete
      (next run: native entry is authoritative, plaintext is an orphaned
      leftover that should be re-deleted on the next successful read, not
      re-migrated). Note that migration is a **write-on-read side effect** that
      will fire during a plain `kmdb sync`/`push`/`pull` (mutating the keychain
      and deleting a file mid-sync); that's acceptable but should be stated as
      intended so it isn't a surprise.

- [ ] **D6 — Byte encoding and size limits.** The interface passes `String
      secretJson`; the byte-based backends (Secret Service, win32
      `CredentialBlob`) need a defined encoding — specify UTF-8. Note the win32
      `CredentialBlob` size cap (2560 bytes) and confirm the stored blob
      (access + refresh token + `client_id`/`client_secret`) fits comfortably.

- [ ] **D7 — Define forced-backend failure behaviour (Q6).** If
      `KMDB_CLI_CREDENTIAL_STORE=keychain` is set but the native store is
      unreachable, does `forPlatform` hard-fail (the user explicitly demanded
      keychain) or silently fall back to plaintext? Pick one and document it; a
      forced choice silently degrading is a security-relevant surprise.

### Non-blocking notes

- Test-path references should use the real locations under
  `packages/kmdb_cli/test/config/` (e.g. `test/config/adapter_for_test.dart`);
  confirm `remote_command_test.dart` / `cli_runner_inprocess_test.dart` actually
  exercise the credential path before listing them as "keep passing unchanged."
- The next free release-checklist entry is **RC-23** (latest is RC-22); the
  plan's "next free `RC-N`" placeholder is correct — just fill 23 at write time.
- The next free spec number is **§33** as the plan states; keep it as a
  take-at-write-time placeholder per `docs/plans/README.md`.
- `win32`'s `CredWrite`/`CredRead`/`CredDelete`/`CredFree` exposure and the
  `dbus`/Secret Service call sequence are worth a quick import-and-link spike at
  the start of implementation, before committing the whole design to them (both
  are claimed pure-Dart, no native-asset hook — verify with
  `.dart_tool/native_assets.yaml` absence after `dart pub get`).

**Q1–Q6 stand as the user's to bless.** Once D1–D7 are folded into the Design
and Implementation sections and Q1–Q6 are accepted (or overridden), this is
ready to promote to `Investigated`.

## Summary

{Dot points highlighting the work undertaken}
