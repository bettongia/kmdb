# Vault search CLI positive-path coverage

**Status**: Open

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

## Open questions

- [ ] **How is a plain-text blob indexed in the CLI test environment without
      pulling an extractor package or ONNX?** The vault search index is populated
      by a `VaultTextExtractor`. The production extractors live in separate
      packages (`kmdb_extractor_pdf` → betto_pdfium/native, the html/markdown
      ones pure-Dart) and semantic indexing needs ONNX. The test must index a
      `text/plain` (or similar) blob deterministically and offline. **Decision
      needed:** the injection mechanism. Candidate approaches — the reviewer/
      investigation should pick one:
      1. A **fake `VaultTextExtractor`** (returns fixed text for a known media
         type) injected into the CLI's database-open path. **Requires a seam** —
         does the CLI's `KmdbConfig`/database-open already accept a
         `VaultSearchConfig(extractors: …)`, or is one needed? (Investigate
         `packages/kmdb_cli/lib/src/config/` and the vault-search open path.)
      2. Reuse the **pure-Dart `kmdb_extractor_markdown`/`_html`** as a
         `dev_dependency` of `kmdb_cli` tests to index a real `text/markdown` /
         `text/html` blob (no native/ONNX) — simpler if a dev-dep is acceptable
         and lexical-only indexing suffices for a ranked hit.
      3. Index via the **lexical** path only (BM25) to avoid ONNX entirely —
         confirm `vault search` without semantic still produces a ranked hit.
- [ ] **Which search mode(s) to assert?** Lexical is offline and deterministic;
      semantic needs ONNX (likely out of scope for a CLI test). Confirm the
      command's default mode and scope the assertions to what runs offline.

## Investigation

_To be completed by the reviewer/investigation. Anchor points:_

- CLI vault-search commands: `packages/kmdb_cli/lib/src/commands/vault/` (the
  `search`/`reindex`/`status` subcommands) and the existing negative-path tests
  in `test/commands/vault/vault_search_commands_test.dart`.
- Core vault-search wiring: `VaultSearchConfig` / `VaultTextExtractor` and how
  `KmdbDatabase.open` accepts extractors (see the `kmdb_extractor_*` packages'
  examples and `docs/spec/24_vault.md` / the vault-search proposal).
- How the CLI opens the database and whether extractors can be supplied in a
  test (`packages/kmdb_cli/lib/src/config/`).

## Implementation plan

_Finalised once the open questions are resolved._ Expected shape:

- [ ] Establish the chosen blob-indexing seam/fixture (per Q1).
- [ ] `vault reindex` — index ≥1 text blob; assert a **non-zero** indexed count.
- [ ] `vault status` — assert **non-zero** indexed/pending counts reflect the
      blob(s).
- [ ] `vault search <term>` — assert a **ranked hit** on the indexed blob for a
      matching term, and **no hit** for a non-matching term; assert the human
      output and the `--json` hit shape (fields, ranking).
- [ ] Keep the existing negative-path tests; this plan only adds the positive
      paths.

**Final step — QA sign-off and pre-commit:**

- [ ] Run `make coverage` — confirm ≥ baseline. (This is `kmdb_cli` — run
      `cd packages/kmdb_cli && dart test` explicitly; `make pre_commit`'s scoped
      step is `kmdb`-only.)
- [ ] Hand off to the **`kmdb-qa` agent** for sign-off.
- [ ] Run `make pre_commit` — format, analyze, license_check, tests all green.
- [ ] Verify licence headers on any new files (2026).

## Summary

_To be completed when the work is done._
