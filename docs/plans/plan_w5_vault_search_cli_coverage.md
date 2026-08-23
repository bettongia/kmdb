# Vault search CLI positive-path coverage

**Status**: Investigated

**PR link**: _(none yet)_

> **Provenance.** The single plan-sized gap from the WI-10 / W5 CLI
> test-adequacy audit (`kmdb-qa`, 2026-08-23). Split from the quick-wins
> (`plan_w5_cli_coverage_quick_wins.md`) because, unlike those, it needs a test
> seam / fixture design decision rather than just adding assertions.

## Problem statement

`test/commands/vault/vault_search_commands_test.dart` covers only the **negative**
paths of the `vault search` / `vault reindex` / `vault status` CLI commands:
not-configured, missing flags, and an **empty** collection. Nothing indexes a
real blob and then asserts:

- a **ranked search hit** (find a blob by its text content — the entire point of
  vault search),
- a **non-zero `reindex`** count,
- **non-zero `status`** counts,
- the human and `--json` **hit/output shapes** (ranking, fields).

So the actual *value* of vault search is unexercised at the CLI. This is the
highest-value W5 gap.

## Resolved questions

Both open questions from the audit are resolved. See the Investigation section
for evidence. Two important corrections to the original framing are recorded
there: (a) **no injection seam, dev-dependency, or fake extractor is needed** —
the default already indexes `text/plain`; and (b) **there is no `--json` flag**
on any of these three commands, so no JSON output can be asserted.

- [x] **Q1 — How is a plain-text blob indexed offline?** **None of the three
      candidate approaches is required.** `VaultSearchConfig()` — the exact
      config the existing tests already open with — *always* prepends the
      built-in core `PlainTextExtractor` for `text/plain` via
      `VaultSearchConfig.effectiveExtractors`
      (`packages/kmdb/lib/src/vault/search/vault_search_config.dart:134`). A blob
      ingested with `originalName: 'test.txt'` is detected as `text/plain` by the
      default `FreedesktopMediaTypeDetector` and indexed by the real async
      pipeline — pure Dart, no ONNX, no external package, no seam. **Decision:
      use the default `VaultSearchConfig()` and the real end-to-end pipeline.**
      Reject candidate 1 (fake extractor + new seam — unnecessary complexity;
      would add a production surface for no reason), candidate 2 (dev-dep on an
      extractor package — unnecessary; core already handles `text/plain`), and
      the framing of candidate 3 (there is nothing to "wire" — lexical is simply
      what happens when no embedding model is configured).
- [x] **Q2 — Which search mode(s) to assert?** The command default is `auto`.
      With no embedding model wired (the tests open with `VaultSearchConfig()`
      and no model), `auto` and `semantic` both degrade to **lexical** in
      `VaultSearcher.search` (`vault_searcher.dart:174-213`). **Decision: assert
      with `--mode lexical`** for an explicit, deterministic, offline path.
      Semantic (ONNX) is out of scope.

## Investigation

Verified against HEAD (`01d33da`, Dart 3.13.1). All line numbers below are at
that commit.

### The indexing path is fully offline by default (Q1)

- `VaultSearchConfig.effectiveExtractors`
  (`packages/kmdb/lib/src/vault/search/vault_search_config.dart:134-141`)
  unconditionally prepends a core `PlainTextExtractor` unless the caller already
  supplied one for `text/plain`. `VaultSearchManager` uses this list. So the
  default `VaultSearchConfig()` handles `text/plain` with **zero** external
  dependencies.
- Media type is detected in `VaultStore.ingest`
  (`packages/kmdb/lib/src/vault/vault_store.dart:268-286`) via the default
  `FreedesktopMediaTypeDetector` from `originalName` + bytes; `test.txt` → 
  `text/plain`.
- Ingest triggers async indexing through `VaultStore.onAfterIngest`
  (`vault_store.dart:329`), which `KmdbDatabase.open` wires to the manager
  (`kmdb_database.dart:551-563`, `vaultSearchManager.attach()`).
- The existing test's `_openVaultSearchDb()` already opens with
  `vaultSearch: VaultSearchConfig()` and no model, and `_ingest()` already
  ingests `test.txt`. The positive-path work reuses these helpers unchanged.

### A search hit requires a docref, not just an indexed blob (critical)

This is the subtle prerequisite the original checklist missed:
`VaultSearcher.search` scopes candidate blobs to those referenced by a document
**in the searched collection** via `$vault:docref:{sha256}` — see
`_candidatesForNamespace` (`vault_searcher.dart:245-269`). If no document in the
collection references the blob, `candidateSha256s` is empty and the search
returns **zero hits even though the blob is fully indexed**
(`vault_searcher.dart:161-171`). The core searcher tests demonstrate exactly
this: `test/vault/search/vault_searcher_test.dart:443` — *"blob in vault but no
docref returns no candidates"*.

Therefore the positive search test must, in addition to ingesting the blob,
**insert a document into the searched collection whose value contains the blob's
`kmdb-vault://sha256/{sha256}` URI**. `VaultRefInterceptor` walks the decoded
document for vault URI *strings* (`_scanForVaultUris`,
`vault_ref_interceptor.dart:243-256`) and writes the `$vault:docref:{sha256}` /
`{docId}` entry in the same write batch
(`vault_ref_interceptor.dart:156-172`). This fires for any collection write
(including `db.rawCollection(...).insert(...)`) when a vault store is
configured. The doc key segment is the document's own UUIDv7 id.

- `db.rawCollection(name)` is public
  (`kmdb_database.dart:1187`) and returns
  `KmdbCollection<Map<String, dynamic>>`; `insert` mints a UUIDv7 id for a
  keyless map and runs the full write pipeline including the interceptor
  (`kmdb_collection.dart:207-222`). Pass a map with **no `id` field** so `insert`
  is legal (it throws `ArgumentError` if the value already has a key).

### Indexing completion must be awaited deterministically

Indexing runs asynchronously in the isolate. The existing
`status with indexed blob` group uses `Future.delayed(200ms)` and only asserts
`total > 0` — a flaky pattern that CLAUDE.md's durability guidance discourages
and that does **not** prove the blob reached `indexed`. Replace it with a
polling helper mirroring the core `_awaitTerminal`
(`test/vault/search/vault_search_manager_test.dart:311-335`): poll
`db.vaultIndexingStatus()` on a deadline (~5 s, 20 ms interval) until
`status.indexed >= 1`. `vaultIndexingStatus()` is public and already used by the
commands (`kmdb_database.dart`, `vaultIndexingStatus`).

### Reindex counts only indexed/extracting blobs (ordering constraint)

`reindexVault()` (`vault_search_manager.dart:467-519`) resets and counts only
blobs currently `indexed` or `extracting` (or with missing state); a `pending`
blob is left as-is and **not** counted. So a non-zero reindex count requires the
blob to have reached `indexed` **first**. Ordering: ingest → poll until
`indexed` → `reindex` → assert count ≥ 1.

### No `--json` output exists (correction)

`vault search`, `vault reindex`, and `vault status` emit **human-only** output
via `ctx.out.writeln`; none of their `configureArgParser` methods defines a
`--json` flag (`vault_search_command.dart:47-71`,
`vault_reindex_command.dart`, `vault_status_command.dart`). The original
checklist item to assert a "`--json` hit shape" is not implementable and is
dropped. Adding a `--json` mode would be a separate feature plan, out of scope
here. Assertions target the human output only.

### How the commands are invoked in tests

Commands are called directly: `const VaultSearchCommand().execute(ctx, args,
flags)` where `args` is the positional query (`['term']`) and `flags` is a map
(`{'collection': 'docs', 'mode': 'lexical'}`). `CommandContext` is built via the
existing `_ctx(db, out:, err:)` helper. All plumbing already exists in the test
file.

### Output shapes to assert (from source)

- **search hit** (`vault_search_command.dart:175-193`): a header line
  `Vault search results for "<query>" in <collection> (<total> total, showing
  <n>):`, then per hit `[<rank>] score=<0.0000> id=<docId>` and a
  `field: <path>  chunk: i/n` line and the snippet. Assert the header contains
  the collection and the query, and that the output contains the inserted
  document's id and `score=`.
- **search miss** (`:166-172`): `No vault search results for "<query>" in
  <collection>.` — assert this for a non-matching term.
- **reindex** (`vault_reindex_command.dart:79-88`): `Queued <n> vault blob…` —
  assert it reports a non-zero queued count.
- **status** (`vault_status_command.dart:70-107`): `Indexed:` line reflects the
  count; assert `Indexed:           1` (or ≥ 1 via regex like the existing
  `Total blobs:` assertion) and a `Status:` summary line.

## Implementation plan

- [ ] **Add a deterministic index-completion helper** to
      `test/commands/vault/vault_search_commands_test.dart`, e.g.
      `Future<void> _awaitIndexed(KmdbDatabase db, {int atLeast = 1, Duration
      timeout = const Duration(seconds: 5)})` that polls
      `db.vaultIndexingStatus()` every 20 ms until `status.indexed >= atLeast`,
      throwing `TimeoutException` on the deadline. Mirror
      `vault_search_manager_test.dart:_awaitTerminal`.
- [ ] **Add a "searchable document" helper** that (a) ingests a text blob via
      `db.vaultStore!.ingest(bytes: utf8.encode('<distinctive searchable
      text>'), hlcTimestamp: …, originalName: 'test.txt')` returning the
      `sha256`, and (b) inserts a raw document referencing it:
      `await db.rawCollection('docs').insert({'attachment':
      'kmdb-vault://sha256/$sha256'})`. Use text containing a term that stems
      distinctly (e.g. `'quantum'`) so a matching/non-matching query pair is
      unambiguous.
- [ ] **`vault search` positive path** (new group, `_openVaultSearchDb()`):
      ingest + reference + `_awaitIndexed`, then
      `VaultSearchCommand().execute(ctx, ['<matching term>'], {'collection':
      'docs', 'mode': 'lexical'})`. Assert `ok == true`, the output contains the
      results header (collection + query), the inserted doc's id, and `score=`.
- [ ] **`vault search` miss path**: same setup, query a term **not** present;
      assert `ok == true` and output contains `No vault search results`.
- [ ] **`vault reindex` positive path**: ingest + reference + `_awaitIndexed`,
      then `VaultReindexCommand().execute(ctx, [], {})`. Assert `ok == true` and
      the output reports a non-zero queued count (`contains('Queued 1 vault
      blob')` or a `RegExp(r'Queued (\d+)')` group > 0).
- [ ] **`vault status` positive path**: **replace** the existing flaky
      `status with indexed blob` group (which uses `Future.delayed(200ms)` and
      only asserts `total > 0`) with a group that uses `_awaitIndexed` and
      asserts the `Indexed:` line is ≥ 1 (regex `RegExp(r'Indexed:\s+(\d+)')`),
      in addition to `Total blobs:` ≥ 1. Keep asserting `ok == true`.
- [ ] Do **not** add or assert any `--json` output — no such flag exists (see
      Investigation).
- [ ] Keep all existing negative-path tests unchanged; this plan only adds the
      positive paths (and hardens the one flaky status test).

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm ≥ baseline. (This is `kmdb_cli` — run
      `cd packages/kmdb_cli && dart test` explicitly; `make pre_commit`'s scoped
      step is `kmdb`-only.)
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on any new files (2026).

## Reviewer notes (2026-08-23, kmdb-plan-reviewer)

Verdict: **Investigated.** An implementer can execute this with no design
decisions left. Key points that shaped the plan:

- **No production seam is needed.** The audit's Q1 framed this as possibly
  requiring a `VaultSearchConfig(extractors:)` injection surface. It does not —
  core already indexes `text/plain` by default. This stays firmly in test-only
  territory; nothing in `lib/` changes.
- **The docref prerequisite is the one real trap.** Indexing a blob is necessary
  but not sufficient for a search hit; the collection must contain a document
  referencing the blob. A well-meaning implementer who only ingested a blob
  would write a test that passes for status/reindex but returns zero search hits
  and might then "fix" it by weakening the assertion. The plan makes the docref
  insert an explicit step and cites the core test that proves the constraint.
- **Determinism over sleeps.** The existing status test's `Future.delayed(200ms)`
  is exactly the kind of timing-dependent test CLAUDE.md warns against. The plan
  replaces it with a bounded poll on `vaultIndexingStatus()`, matching the
  established core pattern.
- **`--json` was a phantom.** The audit checklist referenced a `--json` hit
  shape that no command implements. Dropped, with a note that it would be a
  separate feature.

No open questions remain. This is a small, self-contained `kmdb_cli` test
addition; the coverage impact is on `kmdb_cli` (run its suite explicitly — the
`make pre_commit` scoped step is `kmdb`-only, as the checklist already notes).

## Summary

_To be completed when the work is done._
