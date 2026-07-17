# `kmdb_cli` cloud sync credentials: permission-hardened directory storage

**Status**: Complete

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
account. Confirmed via direct code inspection: neither write site
(`remote_command.dart:314`, `remote_config.dart:109`) sets file permissions —
the file lands at the process's default umask (typically `644`,
world-readable), not owner-only.

This is a deliberately deferred gap: `docs/spec/31_encryption.md` gap 9
records it as "accepted, out of scope" for the Encryption confidentiality
reconciliation plan (`plan_0_08_encryption_confidentiality_reconciliation.md`,
Q7), explicitly naming a future CLI-hardening item — this one — as the right
place to close it.

**Fix (revised — see Architecture pivot below):** store CLI-managed cloud
credentials in a **permission-hardened, per-user directory**
(`{dbDir}/local/`), matching the model both OpenSSH (`~/.ssh`, refuses to use
a key file it finds group/world-readable) and `gcloud`
(`~/.config/gcloud` on POSIX, `%APPDATA%\gcloud` on Windows) already use in
production for exactly this class of secret — rather than OS-native keychain
integration (macOS Keychain / Windows Credential Manager / Linux Secret
Service). CLI-only; no `kmdb` core, `EncryptionProvider`, or synced surface is
touched.

**Scope confirmed with `kmdb-architect`:** the Google Drive OAuth blob is the
only CLI-managed secret in the codebase today. `local/config.json` (remote
names/paths), `repl_config.dart`, and `history.dart` write only non-secret
state, so no other credential type needs migrating.

## Architecture pivot (2026-07-17)

The original design (below, preserved for its package-survey research) chose
OS-native keychain integration as the primary mechanism, with a plaintext-file
fallback. Discussion with the user reframed this: **directory-permission
hardening is not a "degraded fallback" — it's a legitimate, widely-precedented
primary design**, and pulling in three native backends (`win32` FFI, `dbus`
Secret Service, a `security` CLI subprocess) is disproportionate machinery for
a single credential type on a CLI tool, when OpenSSH and `gcloud` both solve
this exact problem with directory/file permissions alone.

Concretely:

- **POSIX (macOS, Linux):** `local/` is `chmod 700`, each credential file is
  `chmod 600`, both set at write time. The read path stats the file and its
  parent directory; if either is found looser than expected, it **hard
  refuses** (SSH's `Permissions 0644 for '...' are too open` precedent) with
  an error naming the exact `chmod` command to fix it, rather than silently
  reading a file it can no longer vouch for.
- **Windows:** no permission-setting code at all. `%APPDATA%\gcloud`
  is not itself ACL-hardened by `gcloud` — it relies on the default NTFS ACL
  inheritance from the user's profile directory (owner + Administrators/
  SYSTEM only). `{dbDir}/local/` gets the same free ride from whatever
  directory the user chose for their database, so v1 does the same: rely on
  default per-user-profile ACLs, no `icacls` shelling.
- **OS-native keychain integration is deferred to
  `docs/roadmap/9_99.md`** as a future "nice to have." The package survey
  below (win32 `Cred*` FFI, `dbus` Secret Service, `security` CLI subprocess)
  is preserved there as prior art for whoever picks it up — none of that
  research is wasted, it's just not being built now.

**Two follow-up decisions the user made explicitly:**

- **Keep the `CredentialStore` interface** even though only one
  implementation ships. It costs nothing extra now, gives tests an injection
  seam, and gives a future roadmap pickup of native backends a seam to slot
  into without reshaping call sites.
- **Hard refuse, not warn-and-proceed,** when POSIX permissions are found
  looser than expected — matching the SSH precedent exactly, on the reasoning
  that a security warning easy to ignore is worse than an error that stops
  you.

### What this resolves from the original Q1–Q6 / D1–D7 lists

Effectively all of it. See the per-item resolutions in **Open questions**
below (the numbering is kept for continuity with the reviewer feedback
history at the bottom of this file, but most are now resolved rather than
open). The blocking design gaps the reviewer raised (D1–D4, D6, D7) were all
specific to reconciling three heterogeneous native backends — with only one,
file-based implementation, they don't arise:

- **D1** (async factory can't be a default param) — `CredentialStore
  .forPlatform` no longer needs to be async at all: there's no native store to
  probe, so it's a plain synchronous factory returning
  `DirectoryCredentialStore(dbDir: dbDir)`. The seam (resolve inside
  `execute()`/`_add`/`_remove`/`adapterFor` via an optional nullable
  `CredentialStore?` override) is unchanged from the reviewer's
  recommendation, just simpler.
- **D2** (tests must never touch a real OS backend) — moot. There is no real
  OS backend to accidentally touch; `DirectoryCredentialStore` pointed at a
  temp `dbDir` is exactly as safe as any other filesystem test.
- **D3** (account-key derivation across 3 backends' service/account models) —
  moot. A directory-scoped file doesn't need the `base64Url(dbDir)` collision
  scheme that a single-namespace OS keychain required — `credentialsPath` is
  already just a filename inside `{dbDir}/local/`, exactly as today.
- **D4** (per-backend overwrite semantics) — moot; `File.writeAsString`
  already overwrites.
- **D6** (byte encoding / `CredentialBlob` 2560-byte cap) — moot; no such cap
  exists for a file on disk.
- **D7** (forced-backend failure behaviour) — moot; there's no second backend
  to force away from.

**This plan needs a fresh pass from `kmdb-plan-reviewer`** before it can move
to `Investigated` — the pivot invalidates most of the original review's
blocking-gap analysis (which was correct for the design it reviewed), but the
new design hasn't been reviewed itself yet.

## Open questions

- [x] **Q1 — Architecture: directory-permission hardening vs. OS-native
      keychain.** **Resolved 2026-07-17:** directory-permission hardening
      (SSH/`gcloud` model), not OS-native keychain integration. See
      Architecture pivot above. Native keychain work deferred to
      `docs/roadmap/9_99.md`.
- [x] **Q2 — Auto-migrate legacy plaintext credentials on first read.**
      **Resolved:** not applicable. This is a greenfields project — there are
      no existing installations with a plaintext `local/google_credentials.json`
      to migrate. The read path is simply: read from `{dbDir}/local/
      {credentialsPath}`, hard-refuse if permissions are wrong, done.
- [x] **Q3 — Fallback-warning frequency.** **Resolved:** not applicable.
      Directory-permission storage is the primary, intended design here, not a
      degraded fallback from something better — there's no "you're in the
      worse mode" state to warn about.
- [x] **Q4 — How the 3 real native backends get verified.** **Resolved:** not
      applicable, no native backends ship in v1. The permission-hardening
      logic (chmod on write, stat-and-refuse on read) is pure filesystem I/O —
      it runs identically and deterministically in the standard `dart test`
      matrix on macOS and Linux CI. On Windows the permission code path is a
      documented no-op, so the only thing to test there is that it *is* a
      no-op (no chmod attempted, no refusal triggered).
- [x] **Q5 — Fate of `GoogleDriveRemoteConfig.credentialsPath`.** **Resolved
      2026-07-17 (user accepted recommendation):** keep the field
      (`packages/kmdb/lib/src/config/remote_config.dart`, `kmdb` core) and its
      JSON shape unchanged (no config-format break); reframe its doc comment
      from "cached OAuth credentials file" to "credential filename within the
      permission-hardened `local/` directory." It's simpler under the new
      design than the original keychain framing suggested: it's just the
      filename within the permission-hardened `local/` directory, and it's
      the piece that makes two `google-drive` remotes on the same database
      (each with an explicit `--credentials`) address distinct files.
- [x] **Q6 — Explicit backend override.** **Resolved:** not applicable, no
      backend choice exists to override.
- [x] **Q7 — Keep the `CredentialStore` interface abstraction?** **Resolved
      2026-07-17 (user decision):** yes, keep it, even with only one
      implementation — cheap now, gives tests a seam, and gives a future
      roadmap pickup of native backends somewhere to slot in.
- [x] **Q8 — Hard refuse vs. warn-and-proceed on loose permissions?**
      **Resolved 2026-07-17 (user decision):** hard refuse, SSH-style, on
      POSIX. The error names the exact `chmod` fix. No-op on Windows (see
      Architecture pivot).

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

### Package survey (superseded — preserved for `docs/roadmap/9_99.md`)

This survey drove the original OS-native-keychain design. It's no longer
being implemented now (see Architecture pivot), but is accurate research and
is copied into the roadmap entry for whoever picks up native backend support
later.

| Platform | Chosen approach | Why |
| :------- | :--------------- | :-- |
| Windows | `package:win32` (`CredWrite`/`CredRead`/`CredDelete`/`CredFree`, `advapi32` topic) | Mature (halildurmus.dev, 6.4M downloads, 948 likes), pure Dart FFI to an **already-present system DLL** — no compilation step, no native-asset build hook. Confirmed via doc fetch that all four `Cred*` functions are exposed. |
| Linux | `package:dbus` (canonical.com, 5.3M downloads) implementing the freedesktop Secret Service D-Bus API (`org.freedesktop.secrets`) directly | Mature, pure-Dart, protocol-level — talks to whichever Secret Service provider is registered (GNOME Keyring, KDE's `ksecretd`, KeePassXC's integration, etc.) without depending on a specific desktop's CLI binary being installed. No native-asset build hook. |
| macOS | Subprocess to the bundled `/usr/bin/security` CLI | No mature pure-Dart FFI wrapper for `Security.framework` exists on pub.dev today (searched directly; nothing found). |
| Fallback | `PlaintextFileCredentialStore` — today's exact file/location, refactored into the new interface | Zero behaviour change for the fallback path. |

**Rejected (unchanged reasoning, still valid if this work is picked up
later):**
- `keyring`/`keyring_native` (kingwill101) — native layer is Rust, built via
  `native_toolchain_rust` — a second native toolchain requirement alongside
  `betto_zstd`'s existing FFI/C toolchain, and immature (0 stars, 5 commits).
- `flutter_secure_storage`, `crossvault`, `simple_secure_storage`,
  `biometric_storage` — all Flutter plugins; `kmdb_cli` is pure Dart.
- `dbus_secrets` — single-maintainer, v0.0.2, 153-download wrapper; better to
  implement the small Secret Service subset directly on `package:dbus`.

### Design

`CredentialStore` interface,
`packages/kmdb_cli/lib/src/config/credential_store.dart`:

```dart
abstract interface class CredentialStore {
  Future<void> write(String account, String secretJson);
  Future<String?> read(String account);
  Future<void> delete(String account);

  /// Synchronous — no native store to probe in v1.
  factory CredentialStore.forPlatform({required String dbDir}) =>
      DirectoryCredentialStore(dbDir: dbDir);
}
```

One implementation ships:
`packages/kmdb_cli/lib/src/config/credential_store/directory_credential_store.dart`
(`DirectoryCredentialStore` — replaces the originally-planned
`PlaintextFileCredentialStore`; "plaintext" framed it as a degraded fallback,
which it no longer is).

**Permission model (pinned per reviewer N1/N3/N4/N5):**

- **Platform gate:** `!Platform.isWindows` (not `isLinux || isMacOS` — the
  narrower check silently takes the no-enforcement branch on any other Unix,
  e.g. FreeBSD). Any non-Windows platform gets full POSIX permission
  enforcement; Windows gets none (relies on profile-ACL inheritance, see
  Architecture pivot).
- **Primitives (N1):** `dart:io` has **no** `chmod`/`setPermissions` API on
  `File`/`FileSystemEntity` (confirmed absent from the SDK — `File
  .setPermissions` does not exist). Permission *setting* goes through
  `Process.run('chmod', ['700', dirPath])` / `Process.run('chmod', ['600',
  filePath])`. Permission *inspection* uses `await entity.stat()` →
  `FileStat.mode`; refuse when `mode & 0x1FF & 0o077 != 0` (any group/world
  bit set). If the `chmod` subprocess is missing or exits non-zero on write,
  the write fails with a clear error — never leave a secret written at loose
  permissions.
- **Write ordering (N5 — closes the exposure window):** ensure
  `{dbDir}/local/` exists → `chmod 700` the directory → write the file →
  `chmod 600` the file. Chmodding the directory *before* writing (not after)
  means the file is never reachable by path by another user, even during the
  brief window before the file itself is chmod'd — `dart:io` has no
  create-at-mode primitive, so the directory-first ordering is the
  mitigation.
- **Shared directory (N4):** `local/` also holds non-secret `config.json`
  (written by `KmdbConfig.save()`, at umask default). The credential write
  path is the only thing that ever tightens it to `700`; this is a benign
  side effect (owner keeps full access to everything else in `local/`) but is
  intentional, not incidental — call it out in the spec doc. Both the
  **directory** and the **file** are stat'd and checked on read (not
  file-only, as SSH does) because the file check alone can't detect a
  `local/` that regressed to `755` after being widened by some other
  process; either failing triggers the refusal.
- **Exact refuse predicate (read):** `(fileMode & 0o077 != 0) ||
  (dirMode & 0o077 != 0)` → throw.
- **Exception shape (N6):** `CredentialPermissionException` (extends
  `Exception`), defined in `credential_store.dart`, with fields `path`
  (String — the offending file or directory), `actualMode` (int),
  `expectedMode` (int), and a `toString()` naming the exact fix, e.g.
  `Credentials at {path} are readable by others (mode {actualMode}). Fix
  with: chmod {expectedMode} {path}`. `DirectoryCredentialStore.read` throws
  it; `adapterFor` lets it propagate.
- **Surfacing (N8 — corrects an earlier, factually wrong claim in this plan
  that a clean one-line handler "already" exists).** It does not. Verified: the
  `adapterFor(remote, dbDir: dbDir)` call is *unwrapped* in all three commands
  (`sync_command.dart:93`, `push_command.dart:101`, `pull_command.dart:96` —
  none inside a `try`), so today a throw from it (including the existing
  missing-credentials `StateError`) propagates to the generic top-level handler
  at `cli_runner.dart:595-600`, which prints `Error executing "<cmd>": $e\n$st`
  — i.e. **with** a stack trace. The fix: wrap the `adapterFor(...)` call in
  each of `sync`/`push`/`pull` in a `try` that catches
  `CredentialPermissionException` and renders it via
  `ctx.writeError(e.toString())` (emits `Error: <message>` to stderr — the same
  one-line idiom those commands already use for their
  `ArgumentError`/`FormatException`/`'sync failed'` branches) and returns
  `false`. Do **not** route it through the shared `cli_runner.dart:597` catch —
  that handler is deliberately verbose (stack trace); per-command
  `ctx.writeError` matches the existing style. The pre-existing
  missing-credentials `StateError` is likewise unwrapped and currently
  stack-traced; the same `try` **may** additionally catch `StateError` to clean
  that up, but that is pre-existing behaviour outside this plan's core scope —
  treat it as an explicit, optional choice, not an accidental side effect.

**Account-key = filename.** `account` is used directly as the filename within
`{dbDir}/local/` — no encoding transform needed (contrast with the original
design's `base64Url(dbDir)` scheme, which existed only because a single OS
keychain is a global namespace across all databases on the machine; a
directory scoped to one `dbDir` doesn't have that problem). Two
`google-drive` remotes on the same database with distinct `--credentials`
values continue to address distinct files exactly as today.

**`read` contract (N7):** returns `null` when the file is absent (caller
converts this to the existing "run remote add" `StateError`, message
unchanged); returns the secret JSON string on success; throws
`CredentialPermissionException` on loose permissions. The refresh-rewrite
branch in `_loadGoogleDriveAuthClient` (`remote_config.dart:109`, currently a
bare `File(fullPath).writeAsString`) must be changed to call
`store.write(account, ...)` instead, so a refreshed token re-asserts `600`
through the single write path rather than relying on `writeAsString`
preserving the existing mode (it does, in practice, so this is belt-and-
braces — but it keeps one source of truth for the permission invariant).

**Wiring:** `adapterFor` and `RemoteCommand` resolve the store *inside*
`execute()`/`_add`/`_remove` (and inside `adapterFor`, which already has
`dbDir`), taking an optional nullable `CredentialStore?` override that
defaults to `null` and is replaced by `CredentialStore.forPlatform(dbDir:
dbDir)` when absent. `RemoteCommand` stays `const` in the command list
(`cli_runner.dart:87`) — the override is threaded as a method parameter, not
a constructor field.

### Testing implications

No real OS backend exists to accidentally touch, so tests are straightforward
filesystem tests: point `DirectoryCredentialStore` at a temp `dbDir`, assert
the file/directory modes after `write`, assert `read` throws when a fixture
file is chmod'd loose (POSIX only — skip/assert-no-op on Windows), assert
`delete` removes the file. `FakeCredentialStore` (in-memory `Map`, under
`packages/kmdb_cli/test/support/`) is still useful for pure unit tests of the
call sites (`adapterFor`, `RemoteCommand`) that don't want to exercise real
filesystem permission logic.

**Existing fixtures need updating, not just confirming (N2 — corrects an
earlier, incorrect claim in this plan that they'd keep working unchanged).**
`test/config/adapter_for_test.dart` writes its fixture via
`credFile.writeAsStringSync(...)` (lines 102–103, 116–117, 128–129) at the
process umask — typically `644`, group/world-readable. Under the new
hard-refuse read path this makes `adapterFor` throw
`CredentialPermissionException` instead of returning a `GoogleDriveAdapter`,
so "returns GoogleDriveAdapter when non-expired credentials are present" and
"uses custom credentialsPath" would fail as written. Every such fixture must
`chmod 600` the file and `chmod 700` its parent `local/` dir immediately
after writing (or route the fixture write through
`DirectoryCredentialStore.write` directly) before calling `adapterFor` — an
explicit implementation step, not an assumption.

### Spec and doc updates

- New `docs/spec/NN_cli_credential_store.md` (assign the actual next free
  number at implementation time per `docs/plans/README.md`'s numbering rule)
  documenting the `CredentialStore` interface, `DirectoryCredentialStore`'s
  permission model (POSIX chmod + hard-refuse, Windows ACL-inheritance
  reliance), the account-key-is-filename scheme, and a pointer to
  `docs/roadmap/9_99.md` for the deferred native-keychain item.
- Update `docs/spec/31_encryption.md` gap 9 to point at the new section and
  mark the gap resolved.
- Add a `docs/spec/99_glossary.md` entry for "credential store" /
  `CredentialStore`.
- Update `packages/kmdb_cli/README.md`'s `remote add`/`remote remove`
  sections to mention where credentials are actually stored (permission
  model included) and that `remote remove` now deletes them.
- Add a new entry to `docs/roadmap/9_99.md`: "OS-native keychain integration
  for `kmdb_cli` credentials (deferred)" — carries the package survey above as
  prior art, notes the directory-permission design shipped instead, and notes
  what would need to change (the `CredentialStore` interface already has the
  seam) to add native backends later.

## Implementation plan

- [x] Resolve Q5 — accepted the stated recommendation (2026-07-17).
- [x] Define the `CredentialStore` interface with full doc comments
      (`packages/kmdb_cli/lib/src/config/credential_store.dart`).
- [x] Implement `DirectoryCredentialStore`
      (`packages/kmdb_cli/lib/src/config/credential_store/directory_credential_store.dart`):
      write/read/delete against `{dbDir}/local/{account}`, gated on
      `!Platform.isWindows` (N3). Write path: ensure `local/` exists →
      `Process.run('chmod', ['700', dir])` → write file →
      `Process.run('chmod', ['600', file])` (N1, N5 ordering); fail the write
      with a clear error if either `chmod` call is missing or exits non-zero.
      Read path: `stat()` the file and directory, refuse via
      `CredentialPermissionException` if `(fileMode & 0o077 != 0) ||
      (dirMode & 0o077 != 0)` (N4); return `null` if the file is absent,
      otherwise the secret JSON (N7). Windows: no chmod/stat checks at all.
- [x] Define `CredentialPermissionException` (N6) in `credential_store.dart`:
      `implements Exception` (extending `Exception` doesn't compile — `Exception`
      only has factory constructors), fields `path`/`actualMode`/`expectedMode`,
      `toString()` naming the exact `chmod` fix. Surface it (N8) by wrapping the
      *currently unwrapped* `adapterFor(remote, dbDir: dbDir)` call in each of
      `sync`/`push`/`pull` (`sync_command.dart:93`, `push_command.dart:101`,
      `pull_command.dart:96`) in a `try` that catches
      `CredentialPermissionException`, renders it via `ctx.writeError(e
      .toString())`, and returns `false` — not routed through the shared
      stack-trace-printing `cli_runner.dart:597` catch. Optionally have the same
      `try` also catch the pre-existing (equally unwrapped, currently
      stack-traced) missing-credentials `StateError`.
- [x] Wire into `RemoteCommand._authoriseGoogleDrive` (write) and
      `_loadGoogleDriveAuthClient` (read). Change the refresh-rewrite branch
      (`remote_config.dart:109`, currently a bare `File(fullPath)
      .writeAsString`) to call `store.write(account, ...)` instead (N7) — no
      migration logic needed (greenfields).
- [x] Fix `RemoteCommand._remove` to delete the stored credentials file —
      closes the leak found during grounding.
- [x] Add `FakeCredentialStore` test double
      (`packages/kmdb_cli/test/support/fake_credential_store.dart`) and the
      injection seam on `adapterFor`/`RemoteCommand`. Seam implemented as an
      extra *optional* named parameter on the override methods
      (`RemoteCommand.execute`/`_add`/`_remove`, `adapterFor`,
      `_loadGoogleDriveAuthClient`, `_authoriseGoogleDrive`) — Dart allows an
      override to add optional parameters beyond its superclass signature, so
      `cli_runner.dart` (which calls through the `CliCommand` interface) is
      unaffected and simply omits it.
- [x] Update existing fixtures in `test/config/adapter_for_test.dart`
      (lines 102–103, 116–117, 128–129) to `chmod 600` the credentials file
      and `chmod 700` its parent `local/` dir immediately after writing —
      they will fail against the new hard-refuse read path otherwise (N2).
      Confirmed `remote_config_test.dart`, `remote_command_test.dart`,
      `kmdb_config_test.dart`, `cli_runner_inprocess_test.dart`: none of them
      write a credential fixture directly (only `adapter_for_test.dart` does),
      so no other fixture needed updating; all four still pass unchanged.
- [x] New tests: chmod-on-write produces `700`/`600` (POSIX); hard-refuse-on-
      read with a deliberately loose-permission fixture file (POSIX), with
      the error message naming the correct fix; Windows no-op behaviour
      (no chmod attempted, loose-permission fixture still reads
      successfully — via `skip:`-guarded tests that run for real on a
      Windows CI runner/dev machine, since this dev environment and CI are
      both macOS); account-key (filename) collision-freedom for two
      remotes with distinct `--credentials`; `remote remove` deletes the
      credentials file (both via `FakeCredentialStore` call-site assertions
      and a real-filesystem end-to-end check); **surfacing (N8):** a
      `sync`/`push`/`pull` run against a loose-permission credential renders a
      clean one-line `Error: ...` on stderr (naming the `chmod` fix) with no
      stack trace, and returns `false` (POSIX; tested in each of
      `sync_command_test.dart`/`push_command_test.dart`/
      `pull_command_test.dart`). New test files: `test/config/
      credential_store_test.dart`, `test/config/credential_store/
      directory_credential_store_test.dart`, `test/support/
      fake_credential_store.dart`. Not separately tested: the
      refresh-rewrite branch's `store.write` call
      (`remote_config.dart`'s `hasExpired` branch) — this whole branch was
      already `// coverage:ignore`'d before this plan (it requires a real
      network call to Google's token-refresh endpoint via
      `refreshCredentials`), and remains so; the `store.write` substitution
      for the prior bare `File(...).writeAsString` is a mechanical,
      behaviour-preserving change verified by code inspection (N7), not by a
      new automated test.
- [x] Write `docs/spec/33_cli_credential_store.md` (§33 was the next free
      number — confirmed against the file listing at write time, not the
      §32/RC-23 snapshot recorded by the prior reviewer passes, which had
      already been superseded by other merged work by the time
      implementation started); updated §31 gap 9 and §99 glossary. Ran
      `pandoc`/`make doc_site_html` to confirm the new file builds cleanly
      into `site/spec.html`.
- [x] Updated `packages/kmdb_cli/README.md` — added a new "Sync and remote
      management commands" section documenting `remote add`/`remote remove`/
      `remote list` (this section did not exist before; `push`/`pull`/`sync`
      themselves are still undocumented in README, which is a pre-existing
      gap outside this plan's scope).
- [x] Added a `docs/roadmap/9_99.md` entry for the deferred OS-native
      keychain item, carrying the package survey forward.
- [x] Added a release-checklist entry. The reviewer passes' "next free RC-N"
      placeholder assumed RC-23, but RC-23 was taken by an unrelated plan
      merged between review and implementation (`dart build cli` native-asset
      bundling) — used **RC-24** instead, confirmed against the live file at
      write time. Covers manual macOS/Linux `ls -la` permission confirmation,
      Windows `icacls` profile-inheritance confirmation, and a live
      hard-refusal check against a deliberately loosened fixture.

**Final step — QA sign-off and pre-commit:**

- [x] Ran scoped coverage for `kmdb_cli` (`dart run coverage:test_with_coverage`
      from inside `packages/kmdb_cli`, per the native-asset-hook rule) —
      package-wide 95.2% (2901/3048 lines). All new files: `credential_store
      .dart` 100%, `directory_credential_store.dart` 100% (two genuinely
      untestable-in-CI `chmod`-subprocess-failure branches marked
      `// coverage:ignore` — see RC-24 for the manual verification), `remote_config
      .dart` 100%. Touched command files: `remote_command.dart` 100%,
      `push_command.dart`/`sync_command.dart`/`pull_command.dart` 96.3–96.4%
      (the one remaining uncovered line per file in each is the pre-existing
      generic `'push failed: $e'`/`'sync failed: $e'`/`'pull failed: $e'`
      catch, unrelated to this plan). Full `make coverage` (all packages) was
      not run — too slow for this iteration loop; the scoped run covers every
      file this plan touched. `kmdb` core (`packages/kmdb/lib/src/config/
      remote_config.dart`) received a doc-comment-only change, no coverage
      impact; confirmed via the package's full `dart test` run (2373/2373
      passed).
- [x] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). **Completed 2026-07-17**
      in the main session (the implementing session's tool set lacked the
      Agent/Task tool — see the historical note in the Summary below). Verdict:
      ✅ ready to commit, all quality gates pass, no blocking issues — full
      report on file in the conversation record. Two trivial non-blocking
      observations noted (unguarded `store.delete()` call in `_remove`;
      `_chmod`-failure cleanup ordering), neither warranting a change.
- [x] Ran `make pre_commit` directly (in lieu of the `kmdb-pre-commit` agent,
      which also requires the Agent/Task tool) — `format --set-exit-if-changed`
      (0 changed), `melos run analyze` (all 7 packages, no issues),
      `melos licenses` (addlicense --check, passed), `melos pre_commit_test`
      (scoped to `kmdb` per its actual `pubspec.yaml` melos-script definition —
      note the Makefile's own comment claims this also covers `kmdb_cli`, which
      is not what the recipe does; pre-existing discrepancy, not introduced by
      this plan). `kmdb_cli`'s own full suite (1176 tests) and analyzer were
      run and confirmed green separately above, covering what the comment
      describes.
- [x] Verified licence headers (2026) on all new files: `credential_store.dart`,
      `credential_store/directory_credential_store.dart`,
      `test/support/fake_credential_store.dart`, `test/config/
      credential_store_test.dart`, `test/config/credential_store/
      directory_credential_store_test.dart`. `docs/spec/33_cli_credential_store.md`
      is a spec doc — confirmed other `docs/spec/*.md` files carry no license
      header (not code), so none was added.

## Reviewer sign-off (2026-07-17, kmdb-plan-reviewer) — second follow-up pass → `Investigated`

**Verdict: `Investigated`.** Promoted after verifying the N1–N7 fixes against
the live code (not just the checkmarks) and driving out one residual gap (N8)
found in that verification.

**N1–N7 land correctly and are factually sound.** Spot-checked the load-bearing
claims against the codebase:

- **N1** — `Process.run('chmod', ...)` for setting + `stat()`/`FileStat.mode`
  with an `& 0o077` refuse predicate is the right (and only) primitive set;
  the write-fails-on-chmod-failure rule is stated. Sound.
- **N2** — verified `test/config/adapter_for_test.dart` writes its three
  fixtures via `writeAsStringSync` at umask (lines 102–103, 116–117, 128–129);
  all three are correctly enumerated for the `chmod 600`/`700` fix. The
  line-128 invalid-JSON fixture is included, which is right — chmod'ing it keeps
  it reaching the `FormatException`→`StateError` path instead of tripping the
  permission refusal first.
- **N3** (`!Platform.isWindows`), **N4** (dir+file both checked, modes 700/600,
  documented shared-dir side effect), **N5** (dir-first chmod ordering), **N7**
  (`read` null/value/throw contract; refresh-rewrite routed through
  `store.write` — verified `remote_config.dart:109` is the bare
  `File(fullPath).writeAsString` the plan targets) — all present and correct.
- **N6** — the exception *shape* (`CredentialPermissionException extends
  Exception`, `path`/`actualMode`/`expectedMode`, `toString()` naming the fix)
  landed correctly.

**N8 (found and pinned this pass) — N6's surfacing claim was factually wrong.**
The plan asserted the throw would be caught "at the same top level that already
renders the missing-credentials `StateError` as a clean one-line CLI error."
Verification shows otherwise: `adapterFor(remote, dbDir: dbDir)` is *unwrapped*
in all three commands (`sync_command.dart:93`, `push_command.dart:101`,
`pull_command.dart:96`), so both the new `CredentialPermissionException` and the
existing missing-credentials `StateError` propagate to the generic
`cli_runner.dart:595-600` handler, which prints `$e\n$st` **with a stack
trace** — there is no pre-existing clean handler. This is the same class of
defect as N2 (a false premise about existing behaviour), so I held the same
bar. Because it is a design detail rather than a user-policy call, I pinned the
resolution directly rather than bouncing the plan: wrap the `adapterFor` call in
each of the three commands in a `try` that renders
`CredentialPermissionException` via `ctx.writeError(e.toString())` (verified:
emits `Error: <message>`, the idiom those commands already use) and returns
`false`; do not route through the verbose shared `cli_runner:597` catch;
optionally clean up the equally-unwrapped `StateError` in the same `try`. Design
section, checklist, and test list all updated.

**Nothing else blocks.** Open questions Q1–Q8 are all resolved (Q5 accepted as
recommended). The non-blocking notes from the prior pass stand: `write` is not
atomic (a mid-write crash can truncate the credential; recovered by re-running
`remote add`) — worth a one-line acknowledgement in the spec doc but not a
regression and not a blocker; RC-23 is the next free release-checklist entry;
the `§NN`/next-free spec-number placeholder is correct. An implementer can now
execute this without significant design decisions.

## Reviewer feedback (2026-07-17, kmdb-plan-reviewer) — fresh pass on the pivoted design

> **Note (2026-07-17): N1–N7 below have been folded into the Design, Testing
> implications, and Implementation plan sections above.** Kept verbatim here
> for history, same treatment as the D1–D7 record above it.

**Verdict: the pivot is the right call, but the plan is not yet `Investigated`.**

The architecture pivot is sound and I endorse it. Three native backends for one
CLI-managed secret was disproportionate, and the SSH/`gcloud` directory-permission
model is legitimate production precedent, not a degraded fallback — the framing in
the pivot section is correct. Dropping `win32`/`dbus`/`security` also deletes the
entire class of blocking gaps (D1–D4, D6, D7) the last review raised, and the
per-item "moot" reasoning checks out. The decisions to keep the `CredentialStore`
seam and to hard-refuse SSH-style are both defensible and well-recorded. The
`_remove` leak is real and correctly in scope.

But the simplified design introduces its own set of concrete, load-bearing details
that are currently left as "confirm at implementation time" — and one of them the
plan gets factually wrong. An implementer would hit real decisions immediately.
These are design gaps (mine to drive out), captured as a blocking checklist below.

### Blocking design gaps — resolve before `Investigated`

- [ ] **N1 — `File.setPermissions` does not exist; pin the real chmod/stat
      primitives.** I checked the SDK
      (`dart-sdk/lib/io/file.dart`, `file_system_entity.dart`): `dart:io` has **no**
      `setPermissions` / `chmod` API on `File` or `FileSystemEntity`. The plan's
      "e.g. via `File.setPermissions`/`Process.run('chmod', ...)` — confirm the
      simplest correct primitive at implementation time" names a method that does
      not exist and defers the one real choice. Pin it now: **write-side** perms are
      set via `Process.run('chmod', ['700', dir])` and `Process.run('chmod',
      ['600', file])` (there is no in-process alternative). **Read-side** perm
      inspection uses `await entity.stat()` → `FileStat.mode` (confirmed present;
      low 9 bits are POSIX perms), refusing when `mode & 0x1FF & 0o077 != 0`
      (any group/world bit). Specify: what happens if the `chmod` subprocess is
      missing or exits non-zero (fail the write with a clear error — do **not**
      leave a secret written at loose perms), and note this adds a `Process.run`
      dependency to a path that currently has none.

- [ ] **N2 — The claim that the existing fixture tests "keep working unchanged"
      is false; they will break.** `test/config/adapter_for_test.dart` writes its
      fixture with `credFile.writeAsStringSync(...)` (lines 102–103, 116–117,
      128–129), i.e. at the process umask — typically `644`, group/world-readable.
      Under the new hard-refuse read path, `adapterFor` will throw
      `CredentialPermissionException` instead of returning a `GoogleDriveAdapter`,
      so the "returns GoogleDriveAdapter when non-expired credentials are present"
      and "uses custom credentialsPath" tests **fail**. The Testing section's
      assertion that the fixture pattern "keeps working with the new class, since
      it's the same file location and shape" is wrong — same *shape*, but not same
      *permissions*. Every such fixture must `chmod 600` the file and `chmod 700`
      the `local/` dir (or route the write through `DirectoryCredentialStore.write`)
      before calling `adapterFor`. Make this an explicit checklist item and correct
      the Testing-implications paragraph.

- [ ] **N3 — `Platform.isLinux || Platform.isMacOS` is narrower than POSIX and
      silently unsafe on other Unix.** On FreeBSD or any other non-Linux/non-macOS
      Unix, that predicate is false, so the code takes the *Windows* branch: no
      chmod on write, no refuse on read — a secret stored world-readable on a real
      POSIX system with no warning. The correct gate for "this OS has POSIX
      permission semantics" is `!Platform.isWindows`. Decide and pin one predicate;
      if the intent really is to hard-restrict to the two tested platforms, say so
      and state that every other OS is treated as no-permission-enforcement (and
      why that's acceptable), rather than leaving it implied.

- [ ] **N4 — The shared `local/` directory makes the directory-mode check
      fragile; specify the invariant precisely.** `local/` is not credential-owned:
      `KmdbConfig.save()` writes `config.json` into it, and the write path's
      `file.parent.create(recursive: true)` creates it at umask default (`755`).
      The `700` mode is established **only** by the credential write path. So (a)
      credential write chmods a *shared* directory that also holds non-secret
      `config.json` down to `700` — benign (owner keeps full access) but a side
      effect that must be intentional and documented, not a surprise; and (b) the
      read-path *directory* check only stays consistent because write always
      precedes read. Spell out the exact expected modes (dir `700`, file `600`),
      the exact refuse predicate, and whether the directory check is even worth its
      fragility versus checking the key file alone (SSH's primary check is the key
      file). Pick one and justify it.

- [ ] **N5 — Specify create/chmod ordering to close the secret-exposure window.**
      `File.writeAsString` creates the file at umask default (`644`) and *then* you
      chmod `600` — a window where secret token bytes exist world-readable. SSH
      avoids this by creating with mode `600` up front; Dart can't, so the
      mitigation is to chmod the **parent dir to `700` before** writing the file
      (directory-traversal block covers the file-mode window). Pin the order:
      ensure `local/` exists → `chmod 700` dir → write file → `chmod 600` file. As
      written, the plan lists "write the file, then ... chmod," which is the unsafe
      order.

- [ ] **N6 — Nail down the `CredentialPermissionException` shape and how it
      surfaces.** The Design section says "`CredentialPermissionException` (or
      similar)" — under-specified for a mechanical implement. Name the exact type,
      the file it lives in (alongside `credential_store.dart`), its superclass
      (`Exception` / `IOException`), its fields (path, actual mode, expected mode,
      the exact `chmod` fix string), and its `toString()`. Then specify propagation:
      `DirectoryCredentialStore.read` throws it, `adapterFor` lets it propagate, and
      the `sync`/`push`/`pull` command wrapper must render it as a clean one-line
      CLI error (the way missing-creds `StateError` is today), not a stack trace —
      confirm the top-level handler does this.

- [ ] **N7 — Pin the `read` null-vs-throw contract and route the refresh-rewrite
      through `write`.** State it explicitly: `read` returns `null` when the file is
      absent (caller converts to the existing "run remote add" `StateError`, message
      unchanged), returns the secret on success, and throws
      `CredentialPermissionException` on loose perms. Critically, the refresh-rewrite
      branch in `_loadGoogleDriveAuthClient` (`remote_config.dart:109`, currently a
      bare `File(fullPath).writeAsString`) must call `store.write(account, ...)` so
      the rewritten file re-asserts `600` — otherwise a refresh silently reintroduces
      whatever perms the truncating write leaves. (Note for the implementer:
      `writeAsString` on an existing file preserves its mode, so this is belt-and-
      braces, but going through `write` keeps the single source of truth.)

### Non-blocking notes

- Q5 (`credentialsPath` fate) is the only remaining checkbox-open question, and
  the recommendation (keep field + JSON shape, reframe the doc comment) is clearly
  correct and format-preserving — I'd just accept it. It is not what's holding the
  plan back; the N-gaps are.
- Latest release-checklist entry is **RC-22**; next free is **RC-23** (the plan's
  placeholder is right — fill it at write time).
- `write` is not atomic (no temp-file + rename). Current code isn't either, so this
  is not a regression, but for a file whose whole purpose is holding a live OAuth
  token it's worth a one-line acknowledgement that a mid-write crash can leave a
  truncated credential (recovered by re-running `remote add`).
- The spec-number `§NN`/next-free approach is correct per `docs/plans/README.md` —
  keep it as a take-at-write-time placeholder.

**Status stays `Questions`.** Fold N1–N7 into the Design/Testing/Implementation
sections (they're design details, not user policy), accept or resolve Q5, and this
clears the bar for `Investigated`. The pivot itself needs no further blessing.

## Reviewer feedback (2026-07-16, kmdb-plan-reviewer) — superseded by the
2026-07-17 architecture pivot above

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

> **Note (2026-07-17): the design these gaps refer to (three native
> credential-store backends) is no longer being built.** See "Architecture
> pivot" above for how each of D1–D7 is resolved or made moot by the pivot to
> directory-permission hardening. Kept verbatim below for history.

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

**Q1–Q6 stand as the user's to bless.** ~~Once D1–D7 are folded into the Design
and Implementation sections and Q1–Q6 are accepted (or overridden), this is
ready to promote to `Investigated`.~~ Superseded — see Architecture pivot.

## Summary

**Complete (2026-07-17).** Implemented directly on `main` at the user's
request (small, self-contained body of work) rather than via a branch/worktree
+ PR — verified via `kmdb-qa` sign-off and `make pre_commit`, then committed
locally to `main`.

- Added `CredentialStore` (interface + `CredentialPermissionException`,
  `packages/kmdb_cli/lib/src/config/credential_store.dart`) and
  `DirectoryCredentialStore` (`packages/kmdb_cli/lib/src/config/
  credential_store/directory_credential_store.dart`): POSIX `chmod 700`
  directory / `chmod 600` file on write (directory-first ordering to close
  the exposure window), hard-refuse on read via `stat()` when either has
  drifted looser than expected, no-op on Windows (`!Platform.isWindows` gate).
- Wired the store into `RemoteCommand._authoriseGoogleDrive` (write),
  `_loadGoogleDriveAuthClient` (read + refresh-rewrite, now routed through
  `store.write` instead of a bare `File.writeAsString`), and `adapterFor`
  (`packages/kmdb_cli/lib/src/config/remote_config.dart`), each taking an
  optional `CredentialStore?` override — a legal Dart override pattern (extra
  optional params beyond the superclass signature) that keeps
  `cli_runner.dart` and the `const RemoteCommand()` registration unaffected.
- Fixed `RemoteCommand._remove` to delete the stored credential for a
  `google-drive` remote — closes the leak where `remote remove` previously
  deleted only the `config.json` entry and left a live OAuth token behind.
- Wrapped the previously-unwrapped `adapterFor(...)` call in each of
  `sync_command.dart`/`push_command.dart`/`pull_command.dart` (N8) so both
  `CredentialPermissionException` and the pre-existing missing-credentials
  `StateError` render as a clean one-line `Error: ...` via `ctx.writeError`
  instead of propagating to `cli_runner.dart`'s stack-trace-printing handler.
- Updated `GoogleDriveRemoteConfig.credentialsPath`'s doc comment
  (`packages/kmdb/lib/src/config/remote_config.dart`, `kmdb` core) per the
  accepted Q5 recommendation — field and JSON shape unchanged.
- Tests: `test/config/credential_store_test.dart`, `test/config/
  credential_store/directory_credential_store_test.dart` (new), `test/support/
  fake_credential_store.dart` (new test double), plus additions to
  `remote_command_test.dart`, `remote_config_test.dart`, and the three
  sync-command test files for the N8 surfacing behaviour. Updated the three
  loose-permission fixtures in `adapter_for_test.dart` (N2) to chmod after
  writing. Scoped `kmdb_cli` coverage: 95.2% package-wide; all new files
  100%; touched command files 96.3–96.4% (see the Final-step checklist entry
  above for the exact breakdown and the two intentionally
  `// coverage:ignore`'d `chmod`-subprocess-failure branches).
- Docs: new `docs/spec/33_cli_credential_store.md`; updated §31 gap 9
  (resolved) and §99 glossary; new `packages/kmdb_cli/README.md` "Sync and
  remote management commands" section (`remote add`/`remote remove`/
  `remote list` — this section did not exist before); new
  `docs/roadmap/9_99.md` entry carrying the superseded native-keychain
  package survey forward; new `docs/spec/28_release_checklist.md` **RC-24**
  (the reviewer-pass placeholder assumed RC-23, which was taken by an
  unrelated plan merged in the interim).
- All engineering-work checklist items above are checked off. Full test
  suites for both `kmdb` (2373 tests) and `kmdb_cli` (1176 tests) pass;
  `dart analyze` is clean across all 7 workspace packages; `make pre_commit`
  (format/analyze/license_check/`pre_commit_test`) is green.

**Historical note — kmdb-qa sign-off deferred, then completed.** The
implementing session's tool set did not include the Agent/Task tool, so the
mandatory `kmdb-qa` hand-off (and the `kmdb-pre-commit` agent, substituted
there by running `make pre_commit` directly via Bash) could not be invoked
from that session. The main session subsequently ran `kmdb-qa` against the
staged changes: ✅ sign-off, no blocking issues. `kmdb-pre-commit` was then run
for a final independent mechanical-gate confirmation, and the change was
committed locally to `main` (no branch/worktree/PR, per explicit user
instruction — this was judged a small, self-contained body of work). Note the
unrelated concurrent working-tree changes present at commit time
(`CLAUDE.md`, `docs/roadmap/0_09.md`, three other `plan_0_09_*.md` files from
a separate in-progress session) were deliberately excluded from both the QA
review and the commit via explicit-path `git add`.
