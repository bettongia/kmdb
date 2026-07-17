# Vault file export

**Status**: Complete

**PR link**: — (implemented directly on `main`, no worktree/branch/PR — small
plan, per explicit instruction)

## Problem statement

`kmdb_cli` has no way to export a single vault blob to a chosen destination
the way a user would expect from a "download this file" operation.
`vault get` (`packages/kmdb_cli/lib/src/commands/vault/vault_get_command.dart`)
comes close — it fetches by URI and writes to `--output <file>` or stdout —
but it only supports an exact file path; it has no notion of "put this file
into a directory, named after what it originally was."

Per `docs/roadmap/0_09.md` ("Vault file export"), a `vault export` subcommand
should:

- Write to an exact path when `--output` names a file path.
- Write into a directory (named from the manifest's `originalName`, or
  `blob` if absent) when `--output` names an existing directory.

The roadmap entry also flags a related bug in the same file:
`kmdb <db> vault help` fails with "Vault is not available for this database"
on a database with no vault initialised yet, instead of showing subcommand
help. This plan fixes that alongside the new command since both live in
`vault_command.dart`.

**Note (2026-07-16):** WI-12 (PR #60) has since made `ctx.vaultStore` non-null
for every database the production CLI opens (see Q5 below), so this specific
failure mode can no longer be triggered via the shipped binary — the guard-
ordering bug is still real (`'help'` isn't a registered subcommand, and the
null-check still runs before the args check) and still worth fixing for
correctness, but it is no longer a live production issue a user can hit
today.

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

- [x] **Q1 — Is `--output` required? DONE — accepted recommendation.** `vault get` treats `--output` as
      optional (defaults to writing raw bytes to stdout). For `vault export`,
      writing binary blob content to stdout when `--output` is omitted is a
      poor "export" default (no directory-vs-file behavior is meaningful
      without a target). Recommendation: require `--output` for `vault
      export` and error clearly if it's missing, deliberately deviating from
      `vault get`'s optional-output convention. Document the deviation in the
      command's doc comment so it doesn't read as an inconsistency bug later.
- [x] **Q2 — Overwrite behavior. DONE — accepted recommendation.** Neither `vault get --output` nor
      `export_command.dart` appears to guard against overwriting an existing
      file at the target path (needs a quick confirmation read of
      `export_command.dart` during implementation). Recommendation: match
      existing convention (silently overwrite) for consistency rather than
      introducing a new `--force`/confirmation flag that no sibling command
      has.
- [x] **Q3 — Missing parent directory. DONE — accepted recommendation.** If `--output` names a path whose
      parent directory doesn't exist (e.g. `--output
      /tmp/nonexistent/photo.jpg`), should the command create it, or fail
      with a clear error? Recommendation: fail with a clear error (matches
      `vault get`'s current behavior of letting `io.File.writeAsBytes` throw)
      rather than silently creating directory structure — a `vault export`
      into a typo'd path should not leave a surprising new directory behind.
- [x] **Q4 — Trailing-slash-but-nonexistent directory. DONE — accepted
      recommendation.** If `--output` ends
      in `/` but the directory doesn't exist yet, is that "obviously a
      directory, create it" or just another missing-parent error per Q3?
      Recommendation: treat it as covered by Q3 (fail) for a first pass —
      directory auto-creation is a small, separable enhancement if requested
      later, not required by the roadmap's stated behavior.
- [x] **Q5 (added by reviewer) — RESOLVED 2026-07-16 by WI-12 (PR #60,
      merged).** `DatabaseOpener.open()` (`packages/kmdb_cli/lib/src/database_opener.dart:170`)
      now constructs `VaultStore(dbDir: dbPath, adapter: adapter)`
      **unconditionally** — no branching, no conditional path that could skip
      it — exactly the wiring this question asked the plan to fold in or
      defer. `ctx.vaultStore` (`command.dart:115`) is therefore non-null for
      every database the production CLI opens, and `vault export`'s golden
      path can now run against a real store with no further wiring work
      needed from this plan. Confirmed WI-12 did not touch
      `vault_command.dart`, `completer.dart`, or `command.dart` — the rest of
      this plan's Investigation and citations are unaffected.
      **Consequence for the `vault help` bug below:** its production
      reachability has changed. Before WI-12, `ctx.vaultStore == null` was
      the normal state for any freshly-initialised database, so the guard-
      ordering bug fired constantly. After WI-12, `vaultStore` is never null
      via the shipped binary, so that specific guard can no longer trigger in
      production. The guard-ordering logic is still objectively wrong
      (`'help'` still isn't a registered subcommand, and the null-check still
      runs before the args check), so the fix in this plan remains worth
      doing for correctness/robustness and for direct `KmdbDatabase.open()`
      callers that bypass `DatabaseOpener` (e.g. tests, or any future
      embedder) — but it is no longer the production-blocking bug the
      roadmap originally described it as. Re-word the Problem Statement's
      framing of this bug accordingly rather than presenting it as a live
      production issue.
      *(Original question, preserved for context:)* The production CLI wires
      no `VaultStore`, so `vault export`'s export path can never run against
      a real database. Fold a wiring fix into this plan, or explicitly defer
      it with a tracked follow-up? `DatabaseOpener.open()`
      (`packages/kmdb_cli/lib/src/database_opener.dart`) never passes
      `vaultStore:` to `KmdbDatabase.open()`, and `KmdbDatabase` does not
      auto-create one, so `ctx.vaultStore` (`command.dart:115`,
      `db.vaultStore`) is **always `null`** in the shipped binary. Every vault
      subcommand — `get`, `search`, `reindex`, `status`, `insert --import`,
      `update --vault`, and the proposed `export` — hits the
      `vaultStore == null` guard and returns the "Vault is not available"
      error before its real logic runs. The plan's tests inject a
      `_TestVaultStore` (or open `KmdbDatabase` directly), so the automated
      suite is green while the shipped `vault export` is non-functional
      end-to-end. This is exactly the failure mode CLAUDE.md warns about
      ("in-memory test adapters hide an entire class of bugs"). Note the
      asymmetry: the **`vault help` fix is** prod-reachable (it deliberately
      runs before the null guard), but the **export feature is not** until the
      store is wired. Wiring is a ~1-line change
      (`VaultStore(dbDir: dbPath, adapter: adapter)` passed into
      `KmdbDatabase.open`), but it is outside the roadmap's stated scope
      (`vault_command.dart`, `vault_export_command.dart`, `completer.dart`,
      spec doc) and touches the write pipeline (vault ref-count interceptor,
      GC), so it deserves a conscious decision rather than being silently
      pulled in or silently ignored. **Recommendation: fold the minimal wiring
      into this plan** so the headline feature is actually usable and its
      golden path is exercised against a real store; if deferred, add a
      dedicated roadmap/ISSUES entry and state in this plan that `vault export`
      ships non-functional in production until that lands.
- [x] **Q6 (added by reviewer) — RESOLVED, baked into design 2026-07-16.**
      Resolved as recommended: the directory-mode filename is
      `p.basename(manifest.originalName)`, falling back to the literal
      `blob` when that's empty. Folded into the "Output-target resolution"
      Investigation section and the Implementation plan checklist below,
      including an explicit path-traversal/absolute-path test case.
      *(Original question, preserved for context:)* `originalName` is untrusted input; the
      directory-mode join must be sanitised. Confirm the basename + `blob`
      fallback rule.** In directory mode the plan writes
      `p.join(outputPath, manifest.originalName)`. `originalName` is
      user-supplied metadata captured at ingest and, per §31/Gap 4, can
      originate from another device. `package:path`'s `join` does **not** keep
      the result inside `outputPath`: an absolute `originalName` (`/etc/passwd`)
      replaces the directory entirely, and a relative one (`../../foo`) climbs
      out of it — a directory-escape / overwrite hazard driven by blob
      metadata. This is genuinely new behavior (neither `vault get` nor
      `export --vault` joins a manifest name onto a caller path), so there is
      no existing convention to inherit. **Recommendation (bake into the
      design, not left open): resolve the directory-mode filename as
      `p.basename(manifest.originalName)`, and if that is empty fall back to
      the literal `blob`.** `basename` collapses `/etc/passwd` → `passwd` and
      `../../foo` → `foo`, keeping the write inside the chosen directory, and
      the empty→`blob` fallback satisfies the roadmap's explicit "name it
      `blob`" requirement defensively rather than relying on the ingest-time
      default. This supersedes the Investigation's claim that no null/empty
      handling is needed.

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
auto-created directories).

**Directory-mode filename sanitisation (Q6, baked into design).**
`originalName` is untrusted, blob-carried metadata (§31 Gap 4 — it can
originate from another device) and must not be joined onto the caller's
directory path unsanitised: `p.join` does not keep the result inside
`outputPath` (an absolute `originalName` like `/etc/passwd` replaces the
directory outright; a relative one like `../../foo` climbs out of it).
Resolve the filename as `p.basename(manifest.originalName)` — which
collapses both of those hazards to `passwd`/`foo` respectively — and fall
back to the literal `blob` if that's empty, then join:
`p.join(outputPath, p.basename(manifest.originalName).isEmpty ? 'blob' : p.basename(manifest.originalName))`.
This also independently satisfies the roadmap's "if `originalName` does not
exist, name it `blob`" requirement, defensively rather than relying solely
on the ingest-time default.

`package:path` is currently a `dev_dependency` only
(`kmdb_cli/pubspec.yaml`) — a `lib/` command using it at runtime (both
`p.join` and `p.basename` above) needs it under `dependencies:`, or the
analyzer will flag `depend_on_referenced_packages`. Promote it as an
explicit implementation step (below), not just a design note.

**Encryption interaction (non-blocking design note, worth stating
explicitly).** The manifest must be fetched via `VaultStore.getManifest(sha256)`
— the sole decryption point per `vault_manifest.dart`'s doc comment and §24
— never `VaultManifest.fromJson` directly, which would yield the still-
encrypted base64 for `originalName` on an encrypted database.
`vault export`'s directory mode is the first CLI caller to surface a
decrypted `originalName` to the filesystem, so this is load-bearing (the
existing `export --vault` KVLT path already calls `getManifest`, so there's
in-repo precedent for the right call).

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

- [x] Resolve Q1–Q4 (or accept the stated recommendations) before writing
      code. **DONE** — all four accepted as recommended.
- [x] Fix the `vault help` / guard-ordering bug in `vault_command.dart`:
      move the help/no-args handling ahead of the `vaultStore == null` check;
      print each subcommand's `name`/`usage`/`description`. **DONE** —
      `args.isEmpty || args[0] == 'help'` now short-circuits before the
      vault-store guard and prints every sub-command's `usage` +
      `description` (not just names).
- [x] Promote `path` from `dev_dependencies` to `dependencies` in
      `packages/kmdb_cli/pubspec.yaml` (needed at runtime by
      `vault_export_command.dart`, not just in tests). **DONE**.
- [x] Add `packages/kmdb_cli/lib/src/commands/vault/vault_export_command.dart`
      (`VaultExportCommand`), modeled on `VaultGetCommand`. **DONE** — all
      sub-bullets implemented as specified, including `p.basename(...).trim()`
      sanitisation (the `.trim()` was an implementation-time addition beyond
      the plan's literal expression, needed so a whitespace-only
      `originalName` also falls back to `blob`, not just a literal empty
      string).
- [x] Register `VaultExportCommand` in `vault_command.dart`'s `_subCommands`
      map and update the class doc comment's subcommand list. **DONE**.
- [x] Fix `completer.dart`'s vault subcommand completion list and the
      matching README completion table row (see Investigation). **DONE** —
      also fixed the stale doc-comment completion table inside
      `completer.dart` itself (`| After \`vault\` | \`get\` |`), which the
      plan didn't explicitly call out but was the same drift.
- [x] Update `docs/spec/24_vault.md`: add a `### vault export` subsection
      mirroring the existing `### vault get` one, and correct the
      `` `vault export` `` → `` `export --vault` `` naming-collision
      reference. **DONE** — ran `make site/spec.html` (not `make site`,
      which silently no-ops, nor `make doc_site`, which re-runs full
      coverage) to rebuild the spec HTML.
- [x] Update `packages/kmdb_cli/README.md`'s vault section (if any beyond the
      completion table) to mention `export`. **DONE** — only the completion
      table existed; updated.
- [x] Tests. **DONE**, plus two adjacent fixes surfaced by the full-suite
      run:
  - `vault_export_command_test.dart` (18 tests) — all listed cases, plus
    manifest-read-failure and blob-read-failure catches (via a toggleable
    failure-injection `VaultStore` subclass reused from the same `setUp`,
    not a second `KmdbDatabase.open()` — see note below) and a
    write-time-`IOException` case (directory-name collision) distinct from
    the earlier parent-missing guard, plus a command-metadata test.
  - `vault_command_test.dart` (6 tests) — all listed cases plus a
    known-sub-command dispatch test.
  - **Pre-existing test updated**: `test/restore_verify_test.dart` had an
    older `VaultCommand` test asserting the *old* (buggy) no-args behavior
    (`returns false ... requires a sub-command`). Updated it to assert the
    new, correct behavior (`vault` with no args succeeds and prints the same
    summary as `vault help`) — this was a real pre-existing test my change
    would otherwise have broken, caught by the full-suite `make coverage`
    run, not by my own new test files.
  - **Pre-existing test updated**: `test/command_metadata_test.dart` — a
    metadata-contract test enumerating every `CliCommand` subclass was
    missing `VaultExportCommand`; added it.
  - **Design note on failure-injection tests**: initially tried opening a
    second, freshly-created `KmdbDatabase` wired to a throwing `VaultStore`
    subclass to test the manifest/blob-read catches. This broke: opening a
    brand-new empty KV store against a `VaultStore` holding an
    already-ingested-but-unreferenced blob triggers vault ref-count GC on
    `open()` (per §24's crash-recovery orphan sweep), reclaiming the blob
    before the test could exercise the throwing behavior — confirmed
    correct, documented, production-safe behavior by `kmdb-qa`, not a bug.
    Fixed by using one `_ToggleableVaultStore` (mutable
    `throwOnGetManifest`/`throwOnGetBytes` flags) reused for the whole test
    group via the normal `setUp`, flipping the flag immediately before the
    assertion, avoiding a second `open()` entirely.

**Final step — QA sign-off and pre-commit:**

- [x] Run `make coverage` — confirm >95% on all new files. **DONE** — both
      `vault_export_command.dart` and `vault_command.dart` at 100% line
      coverage; overall repo coverage held at 95.0%.
- [x] Hand off to the **`kmdb-qa` agent** for sign-off (spec alignment, doc
      comments, test coverage/adequacy, code health). Resolve every blocking
      item before proceeding. Do not open a PR until sign-off is received.
      **DONE** — zero blocking issues. One WARN flagged and resolved (see
      below).
- [x] Run `make pre_commit` — format, analyze, license_check, tests all green.
      **DONE**, via the `kmdb-pre-commit` agent. Note: `make pre_commit`'s
      `pre_commit_test` Melos script is scoped to the `kmdb` package only —
      it does not exercise `kmdb_cli`, where every file in this plan lives.
      The agent additionally ran `kmdb_cli`'s full test suite directly
      (1148 passed, 1 skipped e2e, 0 failed) to actually validate the
      change; `make pre_commit` passing alone would not have.
- [x] Verify licence headers on all new files (2026). **DONE**.

**QA-flagged plan-fidelity divergence (resolved before finalizing).** The
first QA pass caught that my initial implementation had bare `vault` (no
args) *error* ("requires a sub-command", returning `false`) rather than
behaving identically to `vault help` (print the summary, return `true`) as
this plan's Investigation (`vault help` bug section) and testing strategy
explicitly specify. Root cause: I initially treated `args.isEmpty` and
`args[0] == 'help'` as two separate branches with different outcomes: fixed
by unifying them into one `args.isEmpty || args[0] == 'help'` branch per the
plan's exact wording, and enriching the printed summary to each
sub-command's `usage` + `description` (the plan's stated requirement — my
first pass printed only sub-command names). This also required updating the
pre-existing `restore_verify_test.dart` test noted above, which had encoded
the old, incorrect behavior.

## Reviewer feedback (2026-07-16)

Overall this is a well-scoped, well-investigated plan for a genuinely small
feature. The `vault get` reference-implementation mapping is accurate, the
`vault help` root-cause analysis is correct and its fix is sound, and Q1–Q4's
recommendations all hold up against the current code (`export_command.dart` and
`vault_get_command.dart` both silently overwrite via `writeAsBytes`, confirming
Q2; neither creates parent dirs, confirming Q3/Q4). The adjacent
completer/README drift is real (`completer.dart:202-203` hardcodes `['get']`)
and worth fixing in the same pass. **Two blocking gaps kept it out of
`Investigated`, captured as Q5 and Q6 above — Q5 has since resolved itself.**

**Update (2026-07-16):** Q5 is resolved — WI-12 (PR #60) landed unconditional
`VaultStore` wiring in `DatabaseOpener.open()` for unrelated reasons (fixing
the same gap for `vault get`/`search`/`status`/`reindex`/etc.), which
incidentally clears this plan's headline blocker too. See Q5's entry above
for the verified detail. **Only Q6 remains blocking.**

**Blocking:**

1. ~~**Production wiring gap (Q5).**~~ **Resolved by WI-12, no longer
   blocking.** The headline feature cannot run against a
   real database because `DatabaseOpener` wires no `VaultStore`. This must be a
   conscious decision, not an accident — either fold in the minimal wiring or
   defer it with a tracked follow-up. Whichever is chosen, the plan's testing
   strategy should stop implying the golden path is exercised in production
   when it is not: if wiring is deferred, add an explicit end-to-end
   verification to `docs/spec/28_release_checklist.md` (it cannot pass in the
   automated suite until a real store is wired), consistent with README.md #4.
   *(Superseded — `VaultStore` is now wired unconditionally; no follow-up or
   release-checklist entry needed for this specific gap.)*

2. **Untrusted `originalName` in directory mode (Q6).** The plan joins a
   user-controlled manifest field onto the caller's directory path with no
   sanitisation, which allows a blob's metadata to steer the write outside the
   target directory. The basename + `blob`-fallback rule resolves it cleanly;
   fold it into the "Output-target resolution" design and add a test.

**Required non-blocking corrections to record before implementing:**

- **`package:path` must be promoted, not merely "confirmed".** It is currently a
  `dev_dependency` only (`kmdb_cli/pubspec.yaml:23`). A `lib/` command using it
  at runtime needs it under `dependencies:` (analyzer will also flag
  `depend_on_referenced_packages` otherwise). Make this a firm checklist item:
  move `path: ^1.9.0` from `dev_dependencies` to `dependencies`. (The join +
  basename logic is small enough that `p.basename`/`p.join` are the only APIs
  needed.)

- **Roadmap citation was wrong.** The item lives in `docs/roadmap/0_09.md`
  ("Vault file export"), not `0_08.md` — corrected inline. The plan *filename*
  (`plan_0_08_...`) is inconsistent with the 0_09 roadmap slot, but the 0_09
  roadmap entry links to this exact filename, so leave the filename as-is to
  avoid breaking that link (or rename both together — implementer's call, not a
  blocker).

**Design notes worth incorporating (non-blocking):**

- **Encryption interaction is handled correctly but state it explicitly.** The
  design must fetch the manifest via `VaultStore.getManifest(sha256)` (the sole
  decryption point per `vault_manifest.dart` doc and §24) — never
  `VaultManifest.fromJson`, which would yield still-encrypted base64 for
  `originalName` on an encrypted db. `vault export`'s directory mode is the
  first CLI caller to surface a decrypted `originalName` to the filesystem, so
  this is load-bearing. Note the `export_command.dart` KVLT path already calls
  `getManifest`, so the precedent is right there.

- **Directory-mode overwrite is a slightly higher surprise than file-mode**
  (the clobbered filename is derived, not user-typed). Matching the silent-
  overwrite convention for a first pass is defensible, but call it out in the
  command doc comment so it is a documented choice.

- **Trailing-slash-nonexistent (Q4) will produce a cryptic error.** Falling
  through to `writeAsBytes` on a path ending in `/` throws a low-level I/O
  error rather than a clear "directory does not exist" message. Acceptable for
  v1, but a one-line explicit check would read better; implementer's call.

**Status rationale:** `Investigated` (confirmation pass 2026-07-16). Both
blocking items are resolved and re-verified against the current code:

- **Q5** — `DatabaseOpener.open()` (`database_opener.dart:170`) now constructs
  `VaultStore(dbDir: dbPath, adapter: adapter)` unconditionally and passes it
  into `KmdbDatabase.open()` (line 180), with an inline comment citing this
  plan's Q5 decision. `ctx.vaultStore` is non-null for every CLI-opened
  database; the golden path runs against a real store with no further wiring
  from this plan. The Problem Statement's `vault help` framing was correctly
  reworded to reflect that the guard-ordering bug is no longer production-
  reachable but is still worth fixing for correctness and non-`DatabaseOpener`
  callers.
- **Q6** — the directory-mode filename is baked into the design as
  `p.basename(manifest.originalName)` with a `blob` fallback, wired through the
  Investigation, the checklist, and dedicated absolute-path / path-traversal /
  empty-name test cases. `package:path` is a firm promotion step (verified
  currently `dev_dependencies`-only), and the `getManifest`-as-decryption-point
  note is folded in (`VaultStore.getManifest` verified at `vault_store.dart:386`
  as the decryption boundary).

Q1–Q4 stand as accepted recommendations — each is a low-stakes CLI-ergonomics
choice with a firm default, none forcing an architecture decision at
implementation time. Nothing else blocks mechanical execution. Ready for
`kmdb-plan-implement`.

## Summary

- Added `vault export <uri> --output <path>` to `kmdb_cli`
  (`vault_export_command.dart`), modeled on `vault get` but with `--output`
  required (no stdout fallback) and a new directory-vs-file target
  resolution: an existing-directory target derives its filename from the
  vault manifest's `originalName`, sanitised via `p.basename(...).trim()`
  with a `blob` fallback (defends against absolute-path/traversal/blank
  metadata originating from another device); a non-directory target is
  written to exactly, requiring the parent directory to already exist
  (fails clearly, no auto-create) and silently overwriting any existing
  file.
- Fixed the `vault help` / guard-ordering bug in `vault_command.dart`: bare
  `vault` and `vault help` are now identical, unconditionally-answered
  branches (print every sub-command's `usage` + `description`, return
  `true`) that run before the `vaultStore == null` guard — previously the
  guard ran first, and `'help'` wasn't even a registered sub-command.
- Promoted `package:path` from `dev_dependencies` to `dependencies` in
  `kmdb_cli/pubspec.yaml` (now used at runtime).
- Fixed stale vault sub-command drift in `completer.dart` (tab-completion
  list and its own doc-comment table) and `README.md`'s completion table,
  both hardcoded to `['get']` only.
- Updated `docs/spec/24_vault.md`: added a `### vault export` subsection
  mirroring `### vault get`; corrected a pre-existing naming collision where
  a sentence about the unrelated top-level `export --vault` KVLT-archive
  flag said "`vault export`" instead.
- Added `vault_export_command_test.dart` (18 tests, 100% line coverage of
  the new file) and `vault_command_test.dart` (6 tests, 100% line coverage
  of the changed file), including absolute-path and path-traversal
  `originalName` containment tests that assert the filesystem outcome
  directly (e.g. confirming `/etc/passwd` itself is untouched), not just a
  return code.
- Caught and fixed two pre-existing tests that a narrower "just run my new
  test files" check would have missed: `restore_verify_test.dart` asserted
  the old, incorrect `vault` no-args behavior, and `command_metadata_test.dart`
  (a contract test enumerating every `CliCommand` subclass) was missing the
  new `VaultExportCommand`. Both surfaced only via the full `kmdb_cli` suite
  run, reinforcing why that full run — not just the new files — is part of
  this workflow.
- QA sign-off caught one real plan-fidelity divergence pre-finalization (see
  "QA-flagged plan-fidelity divergence" above) and confirmed the
  failure-injection test design's GC-on-open behavior is correct, documented
  §24 behavior, not a bug being papered over.
- Verification: `kmdb_cli` full suite 1148/1148 passing (0 regressions,
  1 e2e test skipped by default as expected); overall repo coverage held at
  95.0%; `vault_export_command.dart` and `vault_command.dart` both at 100%
  line coverage; `kmdb-qa` signed off with zero blocking issues;
  `make pre_commit` green (format/analyze/license clean across all
  packages; `kmdb_cli`'s own suite additionally run directly since
  `pre_commit_test` is scoped to the `kmdb` package only and wouldn't have
  exercised this change).
- Implemented directly on `main` per explicit instruction (small,
  well-scoped plan) — no worktree, branch, or PR.
