# `kmdb_cli` Credential Store

## Overview

`kmdb_cli` manages one class of secret today: the Google Drive OAuth
credentials (`AccessCredentials.toJson()` plus `client_id`/`client_secret`)
written by `kmdb <db> remote add --type google-drive` and consumed by the
`push`/`pull`/`sync` commands. This is a **per-machine, non-synced, CLI-only**
secret — it never touches the `kmdb` core database, `EncryptionProvider`, or
any synced surface (see §31 gap 9). `CredentialStore` is the storage
abstraction for it, and `DirectoryCredentialStore` is the one implementation
that ships.

The design deliberately follows the model OpenSSH (`~/.ssh`, refuses to use a
key file it finds group/world-readable) and `gcloud` (`~/.config/gcloud` on
POSIX, `%APPDATA%\gcloud` on Windows) both use in production for exactly this
class of secret: a permission-hardened, per-user directory, not integration
with an OS-native keychain (macOS Keychain, Windows Credential Manager, Linux
Secret Service). Directory-permission hardening is not a "degraded fallback"
here — it is the primary, intended design. Native keychain integration is
deferred; see [docs/roadmap/9_99.md](../roadmap/9_99.md).

## `CredentialStore` interface

```dart
abstract interface class CredentialStore {
  Future<void> write(String account, String secretJson);
  Future<String?> read(String account);
  Future<void> delete(String account);

  factory CredentialStore.forPlatform({required String dbDir}) =>
      DirectoryCredentialStore(dbDir: dbDir);
}
```

`account` is used directly as the storage key — for `DirectoryCredentialStore`
that means the filename within `{dbDir}/local/`. `forPlatform` is
**synchronous**: unlike an OS-native-keychain design, there is no native store
to probe asynchronously in v1, so it always resolves to a
`DirectoryCredentialStore` rooted at the given `dbDir`.

`read` returns `null` when no secret has been written for `account` (callers
convert this to the existing "run remote add" `StateError`), the secret JSON
string on success, or throws `CredentialPermissionException` when the
underlying storage is found readable by someone other than the owner.

The interface exists as an injection seam even though only one implementation
ships: it costs nothing extra now, gives tests a seam to avoid ever touching
real credential storage (`FakeCredentialStore`,
`packages/kmdb_cli/test/support/fake_credential_store.dart`), and gives a
future native-backend pickup somewhere to slot in without reshaping call
sites.

## `DirectoryCredentialStore` permission model

Stores each credential as a plain file at `{dbDir}/local/{account}` — the same
location the Google Drive OAuth blob has always lived at.

### Platform gate

Every POSIX-permission behaviour below is gated on `!Platform.isWindows`, not
`Platform.isLinux || Platform.isMacOS`. The narrower check would silently
disable enforcement on other Unix platforms (e.g. FreeBSD), storing a secret
world-readable with no warning. On Windows, `write` and `read` perform no
`chmod`/`stat` calls at all; permission enforcement instead relies on the
default NTFS ACL inheritance from the user's profile directory (owner +
Administrators/SYSTEM only) — the same free ride `gcloud` relies on for
`%APPDATA%\gcloud`.

### Primitives

`dart:io` has no `chmod`/`setPermissions` API on `File` or
`FileSystemEntity`. Permission *setting* therefore shells out via
`Process.run('chmod', ['700', dirPath])` / `Process.run('chmod', ['600',
filePath])`. Permission *inspection* uses `FileSystemEntity.stat()` →
`FileStat.mode`, whose low 9 bits are the POSIX permission bits; the refuse
predicate is `(fileMode & 0x1FF & 0o077 != 0) || (dirMode & 0x1FF & 0o077 !=
0)` — any group or world bit set on either the file or its parent directory.

If a `chmod` subprocess is missing (`ProcessException`) or exits non-zero on
write, the write fails with a `StateError` — a secret is never left written at
loose permissions. Specifically, if the directory chmod fails, the file is
never written; if the file chmod fails after the file was written, the
just-written file is deleted on a best-effort basis before the error
propagates.

### Write ordering

`File.writeAsString` always creates a file at the process umask (typically
`644`, group/world-readable) — `dart:io` has no create-at-mode primitive, so a
naive write-then-chmod sequence leaves a brief window where the secret's bytes
are world-readable. `DirectoryCredentialStore.write` closes that window by
chmodding the *directory* to `700` **before** writing the file: ensure
`local/` exists → `chmod 700` the directory → write the file → `chmod 600` the
file. Once the directory is owner-only, the file is never reachable by path by
another user, even during the interval before the file itself is chmod'd.

### Shared directory

`{dbDir}/local/` is not credential-owned — it also holds `config.json`
(written by `KmdbConfig.save()` at the process umask). Only the credential
write path ever tightens it to `700`. This is an intentional, benign side
effect: the owner retains full access to everything else in `local/`. Both the
directory and the file are checked on `read` (not file-only, as SSH does)
because the file check alone cannot detect a `local/` that regressed to a
looser mode after being widened by some other process — either failing
triggers the refusal.

### `CredentialPermissionException`

```dart
final class CredentialPermissionException implements Exception {
  CredentialPermissionException({
    required this.path,
    required this.actualMode,
    required this.expectedMode,
  });

  final String path;
  final int actualMode;
  final int expectedMode;
}
```

Modelled on OpenSSH's `Permissions 0644 for '...' are too open` refusal:
rather than silently reading a secret the store can no longer vouch for, the
read is **hard-refused** — not a warning — with a `toString()` naming the
exact fix, e.g.:

```
Credentials at /db/local/creds.json are readable by others (mode 644).
Fix with: chmod 600 /db/local/creds.json
```

`DirectoryCredentialStore.read` throws it; `adapterFor`
(`packages/kmdb_cli/lib/src/config/remote_config.dart`) lets it propagate.
Each of `sync`/`push`/`pull` (`sync_command.dart`, `push_command.dart`,
`pull_command.dart`) wraps its `adapterFor` call in a `try` that catches
`CredentialPermissionException` and renders it via `ctx.writeError(e
.toString())` — the same one-line `Error: ...` idiom those commands already
use for other handled errors — rather than letting it propagate to
`cli_runner.dart`'s generic top-level handler, which prints the exception
**and** a stack trace. The same `try` also catches the pre-existing
missing-credentials `StateError` for the same reason.

### Account key

`account` is used directly as the filename within `{dbDir}/local/` — no
encoding transform is needed. Unlike a single global OS keychain, a directory
scoped to one `dbDir` cannot collide across databases, so two `google-drive`
remotes on the same database with distinct `--credentials` values simply
address distinct files. This is what
`GoogleDriveRemoteConfig.credentialsPath` is for
(`packages/kmdb/lib/src/config/remote_config.dart`).

## Write/read/refresh/delete sites

- **Write:** `RemoteCommand._authoriseGoogleDrive`
  (`packages/kmdb_cli/lib/src/commands/remote_command.dart`) — runs the OAuth
  consent flow, then calls `store.write(credentialsPath, ...)`. Untestable in
  the automated suite (requires a real browser and live Google OAuth
  endpoint); marked `// coverage:ignore`.
- **Read + refresh-rewrite:** `_loadGoogleDriveAuthClient`
  (`packages/kmdb_cli/lib/src/config/remote_config.dart`) — calls
  `store.read(credentialsPath)`. On `hasExpired`, refreshes via
  `refreshCredentials` (a real network call to Google's token endpoint — also
  `// coverage:ignore`'d) and persists the refreshed token through
  `store.write(credentialsPath, ...)` rather than a bare
  `File(...).writeAsString`, so a refreshed token re-asserts the store's
  permission model (`chmod 600` on POSIX) instead of relying on
  `writeAsString` preserving the existing file mode. In practice
  `writeAsString` on an existing file does preserve its mode, so this is
  belt-and-braces — but it keeps `write` as the single source of truth for
  the permission invariant.
- **Delete:** `RemoteCommand._remove`
  (`packages/kmdb_cli/lib/src/commands/remote_command.dart`) — looks up the
  removed remote *before* clearing it from `KmdbConfig` so a
  `GoogleDriveRemoteConfig`'s `credentialsPath` is still available, then calls
  `store.delete(credentialsPath)`. Prior to this design, `remote remove`
  deleted only the `config.json` entry and left the credentials file behind —
  a stale, still-valid OAuth token orphaned in `{dbDir}/local/` with no config
  entry pointing at it.

## Injection seam

`RemoteCommand.execute`/`_add`/`_remove`, `adapterFor`, and
`_loadGoogleDriveAuthClient`/`_authoriseGoogleDrive` all take an extra
**optional** `CredentialStore? credentialStoreOverride` parameter, defaulting
to `null` and resolved to `CredentialStore.forPlatform(dbDir: dbDir)` when
absent. This is legal in Dart even though `CliCommand.execute`'s abstract
signature does not declare it — an override may add extra optional parameters
beyond its superclass signature, since omitting them still satisfies the
superclass contract. `cli_runner.dart` calls through the `CliCommand`
interface and is unaffected; tests that hold a concrete `RemoteCommand`
reference (or call `adapterFor` directly) can pass a `FakeCredentialStore` to
avoid exercising the real permission-hardened filesystem store.

## Not implemented: OS-native keychain integration

An earlier design for this same problem chose OS-native keychain integration
(`win32` `Cred*` FFI on Windows, `dbus` Secret Service on Linux, a `security`
CLI subprocess on macOS) as the primary mechanism, with a plaintext-file
fallback. Three native backends for one CLI-managed secret was judged
disproportionate machinery, and the directory-permission model is legitimate,
widely-precedented production practice rather than a degraded fallback — so
this design was not built. The package survey research remains valid and is
preserved as prior art in [docs/roadmap/9_99.md](../roadmap/9_99.md) for
whoever picks up native backend support later; the `CredentialStore`
interface already provides the seam it would slot into.

## Known limitation: write is not atomic

`DirectoryCredentialStore.write` uses a direct `File.writeAsString`, not a
temp-file-then-rename sequence. A process crash mid-write can leave a
truncated credential file. This is not a regression — the prior plaintext
write path had the same property — and is recoverable by re-running `kmdb
<db> remote add --type google-drive` to re-authorise.
