# A core `SecretStore` seam for host-provided secret storage

**Status**: Investigated

**PR link**: _(none yet)_

> **Provenance.** Split out of `plan_0_10_01_sync_authentication.md` on 2026-08-10
> (reviewer scope decision, round 2). It was that plan's former Phase 1. It is a
> self-contained, low-risk refactor with no dependency on the sync-auth crypto
> core, so it lands **first** and unblocks the `SyncAuthenticator`'s root-key
> storage. Part of the [0.10.01 hardening track](../roadmap/0_10_01.md).

## Problem statement

KMDB has exactly one secret-at-rest seam today — `kmdb_cli`'s
`CredentialStore` / `DirectoryCredentialStore`
(`packages/kmdb_cli/lib/src/config/credential_store.dart` and
`.../credential_store/directory_credential_store.dart`) — and it has three
limitations that block the sync-authentication work and leave a reviewed gap
open:

1. **It lives in `kmdb_cli`, not core.** The forthcoming `SyncAuthenticator`
   default implementation lives in `kmdb` core and must read a root key from a
   host-provided secret store. Core cannot depend on `kmdb_cli`, so the seam has
   to exist in core (interface) with the concrete directory-backed implementation
   supplied by the host — exactly the shape `DekCache`
   (`lib/src/encryption/dek_cache.dart`) already uses.
2. **It is string-oriented (`write(account, secretJson)`).** A sync-auth root key
   is 32 raw bytes; round-tripping it through a JSON string is wrong. The seam
   must be byte-oriented, and it must expose `list` so orphaned secrets can be
   enumerated and pruned.
3. **Its rooting (`{dbDir}/local/`) still leaves the Windows C-1 gap open in
   code.** The permission model relies on NTFS ACL inheritance from the
   containing directory; an arbitrary user-supplied `{dbDir}/local/` is not
   guaranteed to inherit the restrictive profile ACLs that `%APPDATA%\kmdb`
   does. **Discrepancy to note:** `docs/roadmap/0_10_01.md` marks C-1 "✅ Closed —
   superseded by WI-0," on the basis that WI-0 "moved the sync-auth secret to a
   controlled location (`%APPDATA%\kmdb` / `~/.config/kmdb`)." Verified against
   `main` (2026-08-10): **that move was never implemented** — there is no
   `SecretStore`, no profile-dir store, and `directory_credential_store.dart`
   still roots at `{dbDir}/local/`. WI-0 (PR #61) shipped S-1/S-3/S-4/S-6/S-7/D-1
   validation, not a secret store. This plan is what actually performs the
   controlled-location move the C-1 closure assumed. (Roadmap edit is out of scope
   for this plan; flagged for the architect.)

## Goals

- A byte-oriented `SecretStore` **interface in core**, with an in-memory default,
  mirroring `DekCache`.
- A `DirectorySecretStore` implementation (outside core, in `kmdb_cli`) with a
  **configurable root** defaulting to the per-user profile config directory
  (`%APPDATA%\kmdb` on Windows, `~/.config/kmdb` on POSIX), carrying over the
  existing POSIX permission model unchanged.
- `kmdb_cli` credential storage refactored onto the new seam.
- `kmdb credentials prune` to remove orphaned secrets.
- Actually perform the controlled-location move the roadmap's **C-1** closure
  assumed (the profile-directory default), which is not yet in the code.

## Non-goals

- **The `SyncAuthenticator`, envelope, enrollment, or any crypto.** All of that
  stays in `plan_0_10_01_sync_authentication.md`.
- **OS-native keychain integration** (macOS Keychain, Windows Credential Manager,
  Linux Secret Service) — still deferred (`docs/roadmap/9_99.md`). The interface
  is the seam a future native backend slots into.
- **Extracting `betto_secret_store`** — see
  [the proposal](../proposals/betto_secret_store.md). This ships a KMDB-local
  implementation behind the interface.

## Investigation

### Existing seams

- **`DekCache`** (`lib/src/encryption/dek_cache.dart`) — the exact architectural
  precedent: an `abstract interface class` in core, an `InMemoryDekCache` default
  in the same file, and platform-backed implementations (`FlutterSecureDekCache`)
  outside the package. `SecretStore` follows this shape one-for-one.
- **`DirectoryCredentialStore`** (`kmdb_cli`) — its permission model was reviewed
  and found sound (review C-3) and is **carried over unchanged**:
  - Platform gate `!Platform.isWindows` (not `isLinux || isMacOS`), so other
    Unix platforms are still enforced.
  - Directory-first `chmod 700` **before** the file write (closes the
    create-at-umask exposure window), then `chmod 600` on the file; delete the
    just-written file on file-chmod failure so a secret is never left at loose
    permissions.
  - Read-side hard refusal: `CredentialPermissionException` (renamed
    `SecretPermissionException`) when any group/world bit is set on the file or
    its parent directory.
  - `chmod` shells out via `Process.run` (no `dart:io` permission API); the two
    defensive `_chmod` failure branches remain `coverage:ignore` (not portably
    triggerable in CI — carry the existing justification comment across).
- **`RemoteConfig`** (`kmdb_cli/lib/src/config/remote_config.dart`) — the source
  of truth for which remotes exist; `credentials prune` cross-references it to
  identify orphaned secrets.

### Design

**Interface (core).** New file `lib/src/secret/secret_store.dart`, exported from
the public library:

```dart
abstract interface class SecretStore {
  Future<void> write(String key, Uint8List value);
  Future<Uint8List?> read(String key);        // may throw SecretPermissionException
  Future<void> delete(String key);            // no-op if absent
  Future<List<String>> list();                // keys currently held
}
```

Plus `InMemorySecretStore` (default, in the same file) mirroring
`InMemoryDekCache`: a `Map<String, Uint8List>` with defensive copies on
`write`/`read`. `SecretPermissionException` moves to core alongside the
interface (it is part of the read contract).

**Implementation (`kmdb_cli`).** `DirectorySecretStore implements SecretStore`,
constructed with a configurable root and a platform factory:

```dart
DirectorySecretStore({required String root});
factory DirectorySecretStore.forPlatform();  // %APPDATA%\kmdb | ~/.config/kmdb
```

Each key is a filename directly under `root` (the existing "account = filename"
model; a directory scoped to one root cannot collide). Bytes are written/read
verbatim — no UTF-8/JSON transform. The POSIX permission model above is applied
to `root` and each file.

**CLI refactor.** `CredentialStore` call sites (the Google Drive OAuth blob,
`remote add --type google-drive`, and the sync/push/pull command helpers) move
onto `SecretStore`, encoding/decoding their JSON payloads to/from `Uint8List` at
the call site. The default root moves from `{dbDir}/local/` to the profile
config dir; **no migration** — developers re-run `remote add` once (documented in
the command's error text when a credential is missing).

**`credentials prune`.** New `kmdb credentials prune`: `SecretStore.list()` →
for each key, if it does not correspond to a currently-configured remote
(per `RemoteConfig`), delete it. `--dry-run` prints what would be removed.

### Edge cases

- **Relocation of the credential root** (per-db → profile dir): a stale
  `{dbDir}/local/<account>` left behind is harmless (never read again). Note it in
  the migration text; do not attempt to move it automatically.
- **Windows**: no `chmod`/`stat`; enforcement is profile-dir ACL inheritance —
  which is exactly why the default root moves under `%APPDATA%` (C-1).
- **`list()` on a non-existent root** returns empty, not an error (a store that
  has never been written to is valid).
- **Prune with no `RemoteConfig`** (fresh database): every listed secret is
  orphaned by definition — guard so `prune` does not delete a secret for a remote
  that exists but is defined elsewhere; scope prune strictly to the current
  database's config.

## Implementation plan

### Phase 1 — Core interface

- [ ] `lib/src/secret/secret_store.dart`: `SecretStore` interface,
      `InMemorySecretStore` default, `SecretPermissionException`. Export from the
      public library. Full doc comments + 2026 licence header.

### Phase 2 — Directory implementation

- [ ] `DirectorySecretStore` in `kmdb_cli` with a configurable root and a
      `forPlatform()` factory (`%APPDATA%\kmdb` / `~/.config/kmdb`).
- [ ] Carry over the `DirectoryCredentialStore` permission model verbatim
      (directory-first chmod, delete-on-chmod-failure, read-side refusal,
      `!Platform.isWindows` gate, `coverage:ignore` on the two `_chmod` branches).
- [ ] Implement `list()` (enumerate files directly under `root`).

### Phase 3 — CLI refactor + prune

- [ ] Refactor all `CredentialStore` call sites onto `SecretStore` (byte
      payloads). Remove `CredentialStore`/`DirectoryCredentialStore` once no call
      site remains (no dead code left behind).
- [ ] Update the "credential missing" error text to say "re-run `remote add`".
- [ ] Add `kmdb credentials prune` (with `--dry-run`).

### Phase 4 — Tests

- [ ] `InMemorySecretStore` round-trip incl. defensive-copy isolation, `list`,
      `delete` no-op.
- [ ] `DirectorySecretStore`: write/read/list/delete; permission enforcement
      (directory-first chmod ordering; read-side refusal on a loosened file **and**
      on a loosened parent dir); byte fidelity for non-UTF-8 payloads.
- [ ] Windows-path guards: build every path with `package:path`; gate
      POSIX-permission assertions on `!Platform.isWindows` (the
      `vault_export_command_test.dart` 2026-07-19 reference case).
- [ ] `credentials prune`: orphan removed, live credential kept, `--dry-run`
      deletes nothing, empty store is a no-op.
- [ ] CLI regression: `remote add` / sync path still reads and writes its
      credential through the new seam.

### Phase 5 — Docs

- [ ] Update `docs/spec/33_cli_credential_store.md` for the new core seam, the
      profile-dir default, and `credentials prune`. Flag to the architect that
      the roadmap's C-1 "closed by WI-0" note should be corrected to point here
      (the move is implemented by this plan, not WI-0).
- [ ] Note the no-migration relocation in the CLI docs.

**Final step — QA sign-off and pre-commit:**

- [ ] `make coverage` — >95% on new files.
- [ ] `kmdb-qa` sign-off before any PR.
- [ ] `make pre_commit` (scoped to `packages/kmdb`) **and** `cd
      packages/kmdb_cli && dart test` — this plan is mostly `kmdb_cli`.
- [ ] 2026 licence headers on all new files.

## Summary

_To be completed when the work is done._
