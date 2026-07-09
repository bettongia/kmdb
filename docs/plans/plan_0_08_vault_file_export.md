# Vault file export

**Status**: Open

**PR link**: —

## Problem statement

`kmdb_cli` has no way to export a single vault blob to a chosen destination
the way a user would expect from a "download this file" operation.
`vault get` (`packages/kmdb_cli/lib/src/commands/vault/vault_get_command.dart`)
comes close — it fetches by URI and writes to `--output <file>` or stdout —
but it only supports an exact file path; it has no notion of "put this file
into a directory, named after what it originally was."

Per `docs/roadmap/0_08.md` ("Vault file export"), a `vault export` subcommand
should:

- Write to an exact path when `--output` names a file path.
- Write into a directory (named from the manifest's `originalName`, or
  `blob` if absent) when `--output` names an existing directory.

The roadmap entry also flags a related bug in the same file:
`kmdb <db> vault help` fails with "Vault is not available for this database"
on a database with no vault initialised yet, instead of showing subcommand
help. This plan fixes that alongside the new command since both live in
`vault_command.dart`.

**Naming check (resolved during grounding, confirmed with `kmdb-architect`):**
`docs/spec/24_vault.md` line 571 mentions "KVLT archive export (`vault
export`)" in the context of the *existing* top-level `export --vault` flag
(`export_command.dart` + `vault_package.dart`, producing a Zstandard KVLT
archive of a whole collection's documents + referenced vault blobs). No
`vault export` subcommand exists or is separately planned — that line is loose
phrasing for `export --vault`, not a name reservation. `vault export` is safe
to use for this single-blob command; the spec line should be corrected to say
`` `export --vault` `` as part of this plan's doc changes to remove the
ambiguity for future readers.

## Open questions

- [ ] **Q1 — Is `--output` required?** `vault get` treats `--output` as
      optional (defaults to writing raw bytes to stdout). For `vault export`,
      writing binary blob content to stdout when `--output` is omitted is a
      poor "export" default (no directory-vs-file behavior is meaningful
      without a target). Recommendation: require `--output` for `vault
      export` and error clearly if it's missing, deliberately deviating from
      `vault get`'s optional-output convention. Document the deviation in the
      command's doc comment so it doesn't read as an inconsistency bug later.
- [ ] **Q2 — Overwrite behavior.** Neither `vault get --output` nor
      `export_command.dart` appears to guard against overwriting an existing
      file at the target path (needs a quick confirmation read of
      `export_command.dart` during implementation). Recommendation: match
      existing convention (silently overwrite) for consistency rather than
      introducing a new `--force`/confirmation flag that no sibling command
      has.
- [ ] **Q3 — Missing parent directory.** If `--output` names a path whose
      parent directory doesn't exist (e.g. `--output
      /tmp/nonexistent/photo.jpg`), should the command create it, or fail
      with a clear error? Recommendation: fail with a clear error (matches
      `vault get`'s current behavior of letting `io.File.writeAsBytes` throw)
      rather than silently creating directory structure — a `vault export`
      into a typo'd path should not leave a surprising new directory behind.
- [ ] **Q4 — Trailing-slash-but-nonexistent directory.** If `--output` ends
      in `/` but the directory doesn't exist yet, is that "obviously a
      directory, create it" or just another missing-parent error per Q3?
      Recommendation: treat it as covered by Q3 (fail) for a first pass —
      directory auto-creation is a small, separable enhancement if requested
      later, not required by the roadmap's stated behavior.

## Investigation

### `vault get` as the reference implementation

`VaultGetCommand.execute()` already implements the parts this command
reuses: `VaultRef(uriStr).sha256` for URI parsing/validation,
`vaultStore.exists(sha256)` for the not-ingested-locally check,
`vaultStore.isHydrated(sha256)` for the stub check (with the existing "pull to
hydrate" error message), and `vaultStore.getBytes(sha256)` for the actual
content. `vault export` follows the identical validation sequence and only
diverges at the output-target resolution step.

### Manifest access for `originalName`

`VaultStore.getManifest(sha256)` → `VaultManifest`
(`packages/kmdb/lib/src/vault/vault_manifest.dart`) exposes `originalName`
(required field, defaults to `'blob'` at ingest time per
`VaultStore.ingest(..., originalName = 'blob')` — so an empty/missing
`originalName` in practice only happens for blobs ingested without a supplied
name, and the field is never literally absent, just possibly already
`'blob'`). This means the "if `originalName` does not exist, name it `blob`"
behavior from the roadmap is effectively already guaranteed by the ingest-time
default — `vault export` doesn't need its own null-handling for this beyond
reading the field.

### Output-target resolution (new logic)

No existing CLI command currently distinguishes "target is a file" from
"target is a directory" for a `--output` flag — this is new logic. Use
`io.Directory(outputPath).existsSync()` to detect an existing directory (per
Q3/Q4, non-existent paths are always treated as literal file targets, not
auto-created directories). When true, join with
`p.join(outputPath, manifest.originalName)` (use `package:path`, already a
dev dependency — confirm/promote to a regular dependency if not already
available at runtime in `kmdb_cli/pubspec.yaml`).

### `vault help` bug (root cause confirmed)

`VaultCommand.execute()` (`vault_command.dart:57-93`) checks
`ctx.vaultStore == null` **before** inspecting `args[0]`. Two compounding
issues:

1. Any subcommand — including a hypothetical `help` — hits the
   vault-not-configured error first if the vault hasn't been initialised,
   regardless of what the user actually asked for.
2. `'help'` isn't in `_subCommands` (`{get, search, reindex, status}`) at all,
   so even on a database *with* an initialised vault, `vault help` would fall
   through to "Unknown vault sub-command 'help'".

Fix: check for `args.isEmpty || args[0] == 'help'` first and print a
subcommand summary (name/usage/description for each entry in
`_subCommands`, including the new `export`), returning `true`, before the
`vaultStore == null` guard runs. The guard should only apply to subcommands
that actually touch the vault store.

### Adjacent drift found while reading this file family (in scope, small)

`packages/kmdb_cli/lib/src/repl/completer.dart:202-203` hardcodes vault
subcommand tab-completion to `['get']` only — already stale (missing
`search`, `reindex`, `status`) independent of this plan. Since this plan adds
a fifth subcommand and is already touching `vault_command.dart`'s subcommand
set, fix the completer list to the full current set (`get`, `search`,
`reindex`, `status`, `export`) in the same pass, and correct the stale
`README.md` completion table row (`| After \`vault\` | \`get\` |` →
full list). Small, adjacent, and would otherwise immediately re-drift the
moment `export` ships.

## Implementation plan

- [ ] Resolve Q1–Q4 (or accept the stated recommendations) before writing
      code.
- [ ] Fix the `vault help` / guard-ordering bug in `vault_command.dart`:
      move the help/no-args handling ahead of the `vaultStore == null` check;
      print each subcommand's `name`/`usage`/`description`.
- [ ] Add `packages/kmdb_cli/lib/src/commands/vault/vault_export_command.dart`
      (`VaultExportCommand`), modeled on `VaultGetCommand`:
  - Positional `<uri>` argument (same `VaultRef` validation).
  - Required `--output <path>` flag (error per Q1 if absent).
  - Existence/hydration checks reused verbatim from `vault get`'s pattern.
  - Fetch the manifest, resolve the final write path per the
    directory-vs-file logic above.
  - Write bytes; report success via `ctx.writeValue({...})` including the
    resolved output path (mirroring `vault get`'s success payload shape:
    `uri`, `sha256`, `size`, `output`).
- [ ] Register `VaultExportCommand` in `vault_command.dart`'s `_subCommands`
      map and update the class doc comment's subcommand list.
- [ ] Fix `completer.dart`'s vault subcommand completion list and the
      matching README completion table row (see Investigation).
- [ ] Update `docs/spec/24_vault.md`: add a `### vault export` subsection
      mirroring the existing `### vault get` one (~line 542), and correct
      line 571's `` `vault export` `` reference to `` `export --vault` ``.
      Run `make site` after editing spec files.
- [ ] Update `packages/kmdb_cli/README.md`'s vault section (if any beyond the
      completion table) to mention `export`.
- [ ] Tests:
  - New `vault_export_command_test.dart`: file-path target; directory target
    (filename derived from `originalName`); not-hydrated (stub) error;
    not-found error; missing `--output` error; vault-uninitialised error.
  - New `vault_command_test.dart` (none currently exists — subcommand tests
    are per-file today): `vault help` succeeds with no vault configured and
    lists all subcommands including `export`; `vault` with no args behaves
    the same as `vault help`; unknown subcommand still errors correctly.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm >95% on all new files.
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on all new files (2026).

## Summary

{Dot points highlighting the work undertaken}
