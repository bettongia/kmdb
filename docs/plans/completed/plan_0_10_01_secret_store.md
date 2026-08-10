# A core `SecretStore` seam for host-provided secret storage

**Status**: Implementing

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

### Implementation-time finding: key scoping (filled in, not a redesign)

`DirectorySecretStore.forPlatform()`'s root is **global** (one fixed profile
directory, not parameterised by `dbDir`) — unlike the `DirectoryCredentialStore`
it replaces, which was rooted at `{dbDir}/local/` and therefore could never
collide across databases. The plan's design section restates the old
"a directory scoped to one root cannot collide" reasoning without flagging that
it no longer holds once the root is global: two databases on the same machine
both configuring a `--type google-drive` remote with the *default*
`credentialsPath` (`google_credentials.json`, `GoogleDriveRemoteConfig`'s
literal default) would silently overwrite each other's stored OAuth token under
one shared global key.

This is not a hypothetical gap — the plan's own **prune edge case** already
requires distinguishing "this key belongs to my database but is orphaned" from
"this key belongs to a different database" (`scope prune strictly to the
current database's config`), which is only possible if keys are scoped by
database identity in the first place. So the edge case implicitly mandates a
mechanism the design section never states.

**Resolution (implemented, not escalated — bounded and mechanical, no change to
`SecretStore`'s or `DirectorySecretStore`'s specified shape):** CLI call sites
key the store with `dbScopedSecretKey(dbDir, credentialsPath)`
(`lib/src/config/secret_store/secret_key.dart`) — a fixed-length hex **SHA-256
digest** of the canonicalised absolute `dbDir` path, joined by a single `-`
with `credentialsPath`. `credentials prune` uses the companion
`isSecretKeyForDb` to recognise which of the (possibly multi-database) keys
returned by the global `SecretStore.list()` belong to the current database at
all, before applying the orphan check against `RemoteConfig`; keys with a
different database's scope are never touched. `DirectorySecretStore`'s own
shape (bare `root` + bare `key`) is unchanged — only the *value* passed as
`key` at the CLI layer changes.

> **QA finding (2026-08-10) — resolved.** The first cut used the
> *readable, filesystem-sanitised path* as the scope prefix with a `--`
> delimiter, on the reasoning that a legible `credentials prune` listing was
> worth keeping. QA rejected this: the encoding was **not boundary-safe** (a
> directory name may contain `--`, so a sibling database `~/work--archive`'s
> key had `~/work`'s prefix and would be deleted as orphaned by `~/work`'s
> prune) and **not injective** (`a/b` and `a:b` both sanitised to `a_b`).
> Since the whole point of the helper is to *never* touch another database's
> secret, correctness beat legibility: the scope is now a fixed-length,
> `-`-free SHA-256 prefix, which is both boundary-unambiguous and injective.
> Regression tests: `test/config/secret_store/secret_key_test.dart` (the
> sibling-`--` and separator-vs-colon cases) and the sibling-path prune test
> in `test/commands/credentials_command_test.dart`. Adds a `crypto`
> dependency to `kmdb_cli`.

This whole scoping mechanism was flagged for retroactive `kmdb-architect`/
`kmdb-plan-reviewer` review since no `Agent`/`Task` tool was available in the
implementation session; the QA pass above is that review for the scoping
correctness question (see the PR description for the same note).

**Follow-on consequence for `push`/`pull`/`sync`:** those three commands never
had a `credentialStoreOverride` injection seam — they always called
`adapterFor(remote, dbDir: dbDir)` with no override, relying on `adapterFor`'s
*own* default resolving to a store rooted at that same test's temp `dbDir`.
That was safe under the old per-`dbDir` root; under the new global profile
root it would mean these commands' existing permission/missing-credential
tests either silently stop exercising the scenario they claim to (fixture
written to a location the store never reads) or, worse, touch the real
machine's profile secret directory during `dart test`. Added the identical
optional `secretStoreOverride` parameter (already used by `RemoteCommand`) to
`PushCommand`/`PullCommand`/`SyncCommand.execute`, threaded through to
`adapterFor`, so their tests can inject a temp-rooted store. Same rationale as
above: mechanical application of an existing, already-reviewed pattern to
close a hole the root-directory change opened, not a new seam design.

## Implementation plan

### Phase 1 — Core interface

- [x] `lib/src/secret/secret_store.dart`: `SecretStore` interface,
      `InMemorySecretStore` default, `SecretPermissionException`. Export from the
      public library. Full doc comments + 2026 licence header.

### Phase 2 — Directory implementation

- [x] `DirectorySecretStore` in `kmdb_cli` with a configurable root and a
      `forPlatform()` factory (`%APPDATA%\kmdb` / `~/.config/kmdb`).
- [x] Carry over the `DirectoryCredentialStore` permission model verbatim
      (directory-first chmod, delete-on-chmod-failure, read-side refusal,
      `!Platform.isWindows` gate, `coverage:ignore` on the two `_chmod` branches).
- [x] Implement `list()` (enumerate files directly under `root`).

### Phase 3 — CLI refactor + prune

- [x] Refactor all `CredentialStore` call sites onto `SecretStore` (byte
      payloads). Remove `CredentialStore`/`DirectoryCredentialStore` once no call
      site remains (no dead code left behind).
- [x] Update the "credential missing" error text to say "re-run `remote add`".
- [x] Add `kmdb credentials prune` (with `--dry-run`).

### Phase 4 — Tests

- [x] `InMemorySecretStore` round-trip incl. defensive-copy isolation, `list`,
      `delete` no-op.
- [x] `DirectorySecretStore`: write/read/list/delete; permission enforcement
      (directory-first chmod ordering; read-side refusal on a loosened file **and**
      on a loosened parent dir); byte fidelity for non-UTF-8 payloads.
- [x] Windows-path guards: build every path with `package:path`; gate
      POSIX-permission assertions on `!Platform.isWindows` (the
      `vault_export_command_test.dart` 2026-07-19 reference case).
- [x] `credentials prune`: orphan removed, live credential kept, `--dry-run`
      deletes nothing, empty store is a no-op. Also covers multi-database
      isolation (a key scoped to a different database is never touched — see
      the key-scoping deviation note above).
- [x] CLI regression: `remote add` / sync path still reads and writes its
      credential through the new seam.

### Phase 5 — Docs

- [x] Update `docs/spec/33_cli_credential_store.md` for the new core seam, the
      profile-dir default, and `credentials prune`. Flag to the architect that
      the roadmap's C-1 "closed by WI-0" note should be corrected to point here
      (the move is implemented by this plan, not WI-0). (Also updated
      `docs/spec/99_glossary.md`, `docs/spec/31_encryption.md`,
      `docs/spec/28_release_checklist.md` RC-24, and `docs/roadmap/9_99.md`'s
      prior-art note.)
- [x] Note the no-migration relocation in the CLI docs (spec 33 "No migration
      on upgrade" section).

**Final step — QA sign-off and pre-commit:**

- [x] `make coverage` — >95% on new files. Ran per-package
      (`dart run coverage:test_with_coverage` in `packages/kmdb` and
      `packages/kmdb_cli`; full workspace `make coverage` is redundant with
      this and much slower). Results: `secret_store.dart` 100%,
      `directory_secret_store.dart` 100%, `secret_key.dart` 100%,
      `remote_config.dart` 100%, `remote_command.dart` 100%,
      `credentials_command.dart` 100%; `push_command.dart`/`pull_command.dart`/
      `sync_command.dart` 96.3–96.4% (one pre-existing uncovered generic
      failure-catch line each, unrelated to this plan).
- [ ] `kmdb-qa` sign-off before any PR. **Outstanding** — no `Agent`/`Task`
      tool available in this implementation session; per
      `.claude/agent-memory/kmdb-plan-implement/feedback_no_agent_tool.md`,
      implementation/tests/docs/mechanical-gate work is completed and the
      coordinator runs `kmdb-qa` independently.
- [x] `make pre_commit` (format_check, analyze, license_check, `pre_commit_test`
      scoped to `packages/kmdb`) — green. **And** `cd packages/kmdb_cli && dart
      test` run separately (1195 tests, all passing) since this plan is mostly
      `kmdb_cli` and `pre_commit_test` does not cover it.
- [x] 2026 licence headers on all new files.

## Summary

**Implementation complete; awaiting `kmdb-qa` sign-off (no `Agent`/`Task` tool
available in this session — see the checklist note above).** Nothing has been
committed; the worktree at `.worktrees/20260810_plan_0_10_01_secret_store`
holds all changes uncommitted for the coordinator/user to review, get QA
sign-off, and commit.

- **Phase 1 (core).** `SecretStore` interface + `InMemorySecretStore` default
  + `SecretPermissionException` in `packages/kmdb/lib/src/secret/
  secret_store.dart`, exported from `kmdb.dart`. Mirrors `DekCache`'s shape.
- **Phase 2 (`kmdb_cli` directory implementation).** `DirectorySecretStore`
  (`packages/kmdb_cli/lib/src/config/secret_store/directory_secret_store.dart`)
  with a configurable `root` and a `forPlatform()` factory resolving to the
  per-user profile config directory (`%APPDATA%\kmdb` / `~/.config/kmdb`).
  Carries the `DirectoryCredentialStore` permission model over unchanged
  (directory-first chmod, delete-on-chmod-failure, read-side refusal,
  `!Platform.isWindows` gate).
- **Key-scoping deviation (filled in during implementation, documented above
  under "Implementation-time finding").** `DirectorySecretStore.forPlatform()`'s
  root is global across every database on the machine, unlike the old
  per-`dbDir` root — a bare key is no longer collision-free. Added
  `dbScopedSecretKey`/`isSecretKeyForDb`
  (`lib/src/config/secret_store/secret_key.dart`) at the CLI call-site layer to
  close this, which the plan's own prune edge case implicitly required but
  never named a mechanism for. Also extended the existing
  `secretStoreOverride` injection seam (previously `RemoteCommand`-only) to
  `PushCommand`/`PullCommand`/`SyncCommand`, since their tests could no longer
  safely rely on the default store being test-isolated once it stopped being
  scoped to a temp `dbDir`.
- **Phase 3 (CLI refactor + prune).** All former `CredentialStore` call sites
  (`remote_config.dart`'s `adapterFor`/`_loadGoogleDriveAuthClient`,
  `remote_command.dart`'s add/remove/authorise, and the sync/push/pull error
  wrapping) moved onto `SecretStore` with byte payloads.
  `CredentialStore`/`DirectoryCredentialStore` deleted — no remaining call
  sites. New `kmdb credentials prune [--dry-run]`
  (`lib/src/commands/credentials_command.dart`), scoped strictly to the
  current database's keys before computing orphans against `RemoteConfig`.
- **Phase 4 (tests).** New/updated test files: `packages/kmdb/test/secret/
  secret_store_test.dart`; `packages/kmdb_cli/test/config/secret_store/
  directory_secret_store_test.dart`; `packages/kmdb_cli/test/support/
  fake_secret_store.dart` (replacing `fake_credential_store.dart`);
  `packages/kmdb_cli/test/commands/credentials_command_test.dart` (new,
  including a multi-database isolation regression test for the key-scoping
  fix); `adapter_for_test.dart`, `remote_config_test.dart`,
  `remote_command_test.dart`, `push_command_test.dart`, `pull_command_test.dart`,
  `sync_command_test.dart` all updated onto the new seam. All CLI-command
  tests now inject a `FakeSecretStore` or a temp-rooted `DirectorySecretStore`
  rather than relying on the (now real-machine-touching) default, except three
  deliberately-safe read/delete-of-absent-key tests added specifically to
  exercise the `?? DirectorySecretStore.forPlatform()` fallback expression for
  real without ever writing to the actual machine profile directory.
- **Phase 5 (docs).** Rewrote `docs/spec/33_cli_credential_store.md` for the
  core seam, profile-dir default, key-scoping, and `credentials prune`.
  Updated `docs/spec/99_glossary.md` (renamed glossary entry
  `CredentialStore` → `SecretStore`), `docs/spec/31_encryption.md`,
  `docs/spec/28_release_checklist.md` (RC-24, incl. a new multi-database
  `credentials prune` isolation step), and `docs/roadmap/9_99.md` (native
  keychain prior-art note — also records that the key-scoping concern it
  had already anticipated is now solved).
- **Roadmap.** `docs/roadmap/0_10_01.md`: C-1 flipped from "reopened" to
  ✅ **Done**, WI-6 flipped to ✅ **Complete**, WI-4's row/checklist updated to
  note the `SecretStore` precursor has landed (crypto core still open).
- **Coverage.** All new/changed files under this plan are at 100% except
  `push_command.dart`/`pull_command.dart`/`sync_command.dart` (96.3–96.4%,
  one pre-existing uncovered generic failure-catch line each, unrelated to
  this plan).
- **Tests.** `packages/kmdb`: full suite green (`dart run
  coverage:test_with_coverage`). `packages/kmdb_cli`: 1195 tests, all
  passing (`dart test` run directly, plus via coverage). `make pre_commit`
  (format_check, analyze, license_check, `pre_commit_test`) green.
- **Deviations from the plan, both documented above and flagged for
  retroactive architect/reviewer confirmation:** (1) `dbScopedSecretKey`
  key-scoping at the CLI layer (multi-database collision the plan's design
  section didn't name a mechanism for, though its prune edge case implied
  one was needed); (2) extending `secretStoreOverride` injection to
  push/pull/sync commands (a mechanical, same-pattern consequence of (1)'s
  root-directory change, not a new seam design).
