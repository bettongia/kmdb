# `kmdb_cli` Credential Store

## Overview

`kmdb_cli` manages one class of secret today: the Google Drive OAuth
credentials (`AccessCredentials.toJson()` plus `client_id`/`client_secret`)
written by `kmdb <db> remote add --type google-drive` and consumed by the
`push`/`pull`/`sync` commands. This is a **per-machine, non-synced, CLI-only**
secret — it never touches the `kmdb` core database, `EncryptionProvider`, or
any synced surface (see §31 gap 9).

The storage seam is `SecretStore`, a byte-oriented interface defined in `kmdb`
core (`lib/src/secret/secret_store.dart`) — not `kmdb_cli` — alongside its
in-memory default, `InMemorySecretStore`. It mirrors `DekCache`'s
architecture: an `abstract interface class` in core, an in-memory default in
the same file, and platform/host-backed implementations supplied from outside
the package. `kmdb_cli`'s `DirectorySecretStore` is the one filesystem
implementation shipped today.

> **History.** Prior to the 0.10.01 `SecretStore` precursor plan, this seam
> was `kmdb_cli`-only (`CredentialStore`/`DirectoryCredentialStore`),
> string-oriented (`write(account, secretJson)`), and rooted at
> `{dbDir}/local/`. It was promoted to a byte-oriented core interface so the
> `SyncAuthenticator`'s root-key storage (a separate, later plan) can build on
> the same seam, and re-rooted at the per-user profile config directory to
> close review finding **C-1** — see "Profile-directory rooting" below.

The design deliberately follows the model OpenSSH (`~/.ssh`, refuses to use a
key file it finds group/world-readable) and `gcloud` (`~/.config/gcloud` on
POSIX, `%APPDATA%\gcloud` on Windows) both use in production for exactly this
class of secret: a permission-hardened, per-user directory, not integration
with an OS-native keychain (macOS Keychain, Windows Credential Manager, Linux
Secret Service). Directory-permission hardening is not a "degraded fallback"
here — it is the primary, intended design. Native keychain integration is
deferred; see [docs/roadmap/9_99.md](../roadmap/9_99.md).

## `SecretStore` interface (core)

```dart
abstract interface class SecretStore {
  Future<void> write(String key, Uint8List value);
  Future<Uint8List?> read(String key);
  Future<void> delete(String key);
  Future<List<String>> list();
}
```

`key` is an opaque storage key scoped to whatever the concrete implementation
is itself scoped to. Bytes are written/read verbatim — no UTF-8/JSON
transform; callers that need structured data (e.g. the Google Drive
credential's JSON payload) encode/decode at the call site.

`read` returns `null` when no secret has been written for `key`, the secret
bytes on success, or throws `SecretPermissionException` when the underlying
storage is found readable by someone other than the owner. `list` returns
every key currently held (empty if the store has never been written to) — used
by `kmdb credentials prune` (below) to enumerate and remove orphans.

`InMemorySecretStore` (same file) is the default: a `Map<String, Uint8List>`
with defensive copies on `write`/`read`, holding secrets in memory for the
current process only.

## `DirectorySecretStore` (`kmdb_cli`)

```dart
final class DirectorySecretStore implements SecretStore {
  DirectorySecretStore({required String root});
  factory DirectorySecretStore.forPlatform();
}
```

Stores each secret as a plain file directly under `root`. `forPlatform()`
resolves `root` to the per-user profile config directory:

- **Windows:** `%APPDATA%\kmdb` (falling back to
  `%USERPROFILE%\AppData\Roaming\kmdb` if `APPDATA` is unset).
- **POSIX:** `~/.config/kmdb` (using `HOME`; falls back to `.` if unset).

### Profile-directory rooting (closes C-1)

Unlike the former `{dbDir}/local/`-rooted `DirectoryCredentialStore`, the
permission model's Windows half relies entirely on NTFS ACL inheritance from
the parent directory — `DirectorySecretStore` performs no `chmod`/`stat` calls
on Windows at all. An arbitrary user-supplied `dbDir` (e.g. an external drive,
a network share, or an unusual home-directory layout) was never guaranteed to
inherit the same restrictive ACLs the OS-managed profile directory does.
Rooting at `%APPDATA%\kmdb` / `~/.config/kmdb` closes that gap: every
CLI-managed secret now lives under a location the OS itself is responsible for
protecting, regardless of where any particular database happens to live.

### Key scoping (per-database keys under a global root)

`DirectorySecretStore.forPlatform()`'s root is a single directory **shared by
every KMDB database on the machine** — unlike the old per-`dbDir` root, a bare
key (e.g. the default `credentialsPath`, `google_credentials.json`) is not
collision-free on its own. `kmdb_cli` closes this at the call-site layer with
`dbScopedSecretKey(dbDir, name)`
(`lib/src/config/secret_store/secret_key.dart`): the canonicalised absolute
`dbDir` path, filesystem-sanitised (path separators and Windows drive-letter
colons replaced with `_`), joined with `name`. This is deliberately **not**
hashed, so `credentials prune`'s listing/diagnostic output stays legible.
`isSecretKeyForDb(key, dbDir)` is the inverse predicate, used by `prune` (see
below) to recognise which of the store's (possibly multi-database) keys belong
to the current database at all, before applying any orphan check.

### Permission model

Carried over unchanged from `DirectoryCredentialStore`:

**Platform gate:** every POSIX-permission behaviour below is gated on
`!Platform.isWindows`, not `Platform.isLinux || Platform.isMacOS`. The
narrower check would silently disable enforcement on other Unix platforms
(e.g. FreeBSD), storing a secret world-readable with no warning. On Windows,
`write` and `read` perform no `chmod`/`stat` calls at all; permission
enforcement instead relies on the default NTFS ACL inheritance from the user's
profile directory (owner + Administrators/SYSTEM only) — the same free ride
`gcloud` relies on for `%APPDATA%\gcloud`.

**Primitives:** `dart:io` has no `chmod`/`setPermissions` API on `File` or
`FileSystemEntity`. Permission *setting* therefore shells out via
`Process.run('chmod', ['700', rootPath])` / `Process.run('chmod', ['600',
filePath])`. Permission *inspection* uses `FileSystemEntity.stat()` →
`FileStat.mode`, whose low 9 bits are the POSIX permission bits; the refuse
predicate is `(fileMode & 0x1FF & 0o077 != 0) || (dirMode & 0x1FF & 0o077 !=
0)` — any group or world bit set on either the file or `root`.

If a `chmod` subprocess is missing (`ProcessException`) or exits non-zero on
write, the write fails with a `StateError` — a secret is never left written at
loose permissions. Specifically, if the directory chmod fails, the file is
never written; if the file chmod fails after the file was written, the
just-written file is deleted on a best-effort basis before the error
propagates.

**Write ordering:** `File.writeAsBytes` always creates a file at the process
umask (typically `644`, group/world-readable) — `dart:io` has no
create-at-mode primitive, so a naive write-then-chmod sequence leaves a brief
window where the secret's bytes are world-readable. `DirectorySecretStore
.write` closes that window by chmodding `root` to `700` **before** writing the
file: ensure `root` exists → `chmod 700` `root` → write the file → `chmod 600`
the file. Once `root` is owner-only, the file is never reachable by path by
another user, even during the interval before the file itself is chmod'd.

### `SecretPermissionException`

```dart
final class SecretPermissionException implements Exception {
  SecretPermissionException({
    required this.path,
    required this.actualMode,
    required this.expectedMode,
  });

  final String path;
  final int actualMode;
  final int expectedMode;
}
```

Defined in core alongside `SecretStore` (it is part of the read contract).
Modelled on OpenSSH's `Permissions 0644 for '...' are too open` refusal:
rather than silently reading a secret the store can no longer vouch for, the
read is **hard-refused** — not a warning — with a `toString()` naming the
exact fix, e.g.:

```
Secret at /home/user/.config/kmdb/... is readable by others (mode 644).
Fix with: chmod 600 /home/user/.config/kmdb/...
```

`DirectorySecretStore.read` throws it; `adapterFor`
(`packages/kmdb_cli/lib/src/config/remote_config.dart`) lets it propagate.
Each of `sync`/`push`/`pull` (`sync_command.dart`, `push_command.dart`,
`pull_command.dart`) wraps its `adapterFor` call in a `try` that catches
`SecretPermissionException` and renders it via `ctx.writeError(e.toString())`
— the same one-line `Error: ...` idiom those commands already use for other
handled errors — rather than letting it propagate to `cli_runner.dart`'s
generic top-level handler, which prints the exception **and** a stack trace.
The same `try` also catches the pre-existing missing-credentials `StateError`
for the same reason.

## Write/read/refresh/delete sites

- **Write:** `RemoteCommand._authoriseGoogleDrive`
  (`packages/kmdb_cli/lib/src/commands/remote_command.dart`) — runs the OAuth
  consent flow, then calls `store.write(dbScopedSecretKey(dbDir,
  credentialsPath), ...)`. Untestable in the automated suite (requires a real
  browser and live Google OAuth endpoint); marked `// coverage:ignore`.
- **Read + refresh-rewrite:** `_loadGoogleDriveAuthClient`
  (`packages/kmdb_cli/lib/src/config/remote_config.dart`) — calls
  `store.read(dbScopedSecretKey(dbDir, credentialsPath))`. On `hasExpired`,
  refreshes via `refreshCredentials` (a real network call to Google's token
  endpoint — also `// coverage:ignore`'d) and persists the refreshed token
  through `store.write(...)` rather than a bare `File(...).writeAsBytes`, so a
  refreshed token re-asserts the store's permission model (`chmod 600` on
  POSIX) instead of relying on the filesystem preserving the existing mode.
- **Delete:** `RemoteCommand._remove`
  (`packages/kmdb_cli/lib/src/commands/remote_command.dart`) — looks up the
  removed remote *before* clearing it from `KmdbConfig` so a
  `GoogleDriveRemoteConfig`'s `credentialsPath` is still available, then calls
  `store.delete(dbScopedSecretKey(dbDir, credentialsPath))`. Prior to the
  original `CredentialStore` design, `remote remove` deleted only the
  `config.json` entry and left the credentials file behind — a stale,
  still-valid OAuth token orphaned with no config entry pointing at it.

## `kmdb credentials prune`

```
kmdb <db> credentials prune [--dry-run]
```

Because `DirectorySecretStore.forPlatform()`'s root is shared globally across
every database on the machine, `prune` must never touch a key that isn't
scoped to the *current* database — even one that looks orphaned against the
current database's `RemoteConfig`, since it may simply belong to a different
database entirely. The algorithm:

1. Build the *live* key set: `dbScopedSecretKey(dbDir, credentialsPath)` for
   every `GoogleDriveRemoteConfig` currently in `KmdbConfig.forDatabase(dbDir)`.
2. Call `SecretStore.list()` (every key in the shared global store, across
   every database on the machine) and filter to just the keys for which
   `isSecretKeyForDb(key, dbDir)` is true.
3. Delete (or, under `--dry-run`, print) every key from step 2 that is not in
   the live set from step 1.

An empty orphan set — including the case where no `RemoteConfig` remotes exist
at all — prints `credentials prune: no orphaned secrets found.` and is a
no-op; it never falls through to deleting every listed key, since step 2
already excludes every other database's keys before the orphan check runs.

## Injection seam

`RemoteCommand.execute`/`_add`/`_remove`, `adapterFor`,
`_loadGoogleDriveAuthClient`/`_authoriseGoogleDrive`,
`PushCommand`/`PullCommand`/`SyncCommand.execute`, and
`CredentialsCommand.execute` all take an extra **optional**
`SecretStore? secretStoreOverride` parameter, defaulting to `null` and
resolved to `DirectorySecretStore.forPlatform()` when absent. This is legal in
Dart even though `CliCommand.execute`'s abstract signature does not declare
it — an override may add extra optional parameters beyond its superclass
signature, since omitting them still satisfies the superclass contract.
`cli_runner.dart` calls through the `CliCommand` interface and is unaffected;
tests that hold a concrete command reference (or call `adapterFor` directly)
pass a `FakeSecretStore`
(`packages/kmdb_cli/test/support/fake_secret_store.dart`) or a real
`DirectorySecretStore` rooted at a temp directory, so no automated test ever
touches the real machine's profile secret directory.

## Not implemented: OS-native keychain integration

An earlier design for this same problem chose OS-native keychain integration
(`win32` `Cred*` FFI on Windows, `dbus` Secret Service on Linux, a `security`
CLI subprocess on macOS) as the primary mechanism, with a plaintext-file
fallback. Three native backends for one CLI-managed secret was judged
disproportionate machinery, and the directory-permission model is legitimate,
widely-precedented production practice rather than a degraded fallback — so
this design was not built. The package survey research remains valid and is
preserved as prior art in [docs/roadmap/9_99.md](../roadmap/9_99.md) for
whoever picks up native backend support later; the `SecretStore` interface
already provides the seam it would slot into.

## Known limitation: write is not atomic

`DirectorySecretStore.write` uses a direct `File.writeAsBytes`, not a
temp-file-then-rename sequence. A process crash mid-write can leave a
truncated secret file. This is not a regression — the prior plaintext write
path had the same property — and is recoverable by re-running `kmdb <db>
remote add --type google-drive` to re-authorise.

## No migration on upgrade

The 0.10.01 `SecretStore` precursor moved the default root from
`{dbDir}/local/` to the per-user profile config directory. There is **no
automatic migration**: a database upgraded from an older `kmdb_cli` will have
a stale, never-read credential file left behind at
`{dbDir}/local/{credentialsPath}` (harmless — it is simply ignored) and must
re-run `kmdb <db> remote add --type google-drive ...` once to re-authorise
under the new store. Every "credentials missing" error message says as much.
