# Release Checklist — {VERSION}

Copy this file to `{version}.md` (e.g. `0.1.0-dev.1.md`) in this directory,
replace `{VERSION}`/`{version}` throughout, and fill it in as you work through
the process described in [README.md](README.md). See
[`0.1.0-dev.1.md`](0.1.0-dev.1.md) for a worked example.

## Release metadata

- **Version:** {VERSION}
- **Date:**
- **Released by:**

## Stage 1 — Prep

For each Dart-publishable workspace member, confirm: `publish_to: none`
removed, `LICENSE` present, `repository:` set, `CHANGELOG.md` has an entry
for this version, every dependency has a real (non-blank) version
constraint, and the package version matches this release.

- [ ] `kmdb`
- [ ] `kmdb_cli`
- [ ] `kmdb_google_drive`
- [ ] `kmdb_extractor_pdf`
- [ ] `kmdb_extractor_html`
- [ ] `kmdb_extractor_markdown`

## Stage 2 — Publish

Publish in this order (each step's `dart pub publish` must succeed before
starting the next — see README.md's dry-run caveat):

- [ ] `kmdb`
- [ ] `kmdb_google_drive`
- [ ] `kmdb_extractor_pdf`
- [ ] `kmdb_extractor_html`
- [ ] `kmdb_extractor_markdown`
- [ ] `kmdb_cli`
- [ ] `kmdb_flutter` (hand-published — see README.md's _Hand-publishing the
      Flutter packages_ section; verify the three open unknowns listed there
      before publishing)
- [ ] `kmdb_icloud` (hand-published — same caveats as `kmdb_flutter`)

`kmdb_harness` is never published.

## §28 Release Checklist entries

Go through [§28](../spec/28_release_checklist.md) **as it currently stands**
(do not reuse a previous release's entry list — new entries accrue between
releases) and add one row per `RC-N` entry below, marking `[x]` (run and
passed) if its **Applies when** condition is true for this release's
changes, or `[-]` (not applicable). A release is not cut until every
applicable entry passes or has a documented, accepted waiver.

| Entry | Applies? | Result | Notes |
| :---- | :------- | :----- | :---- |
| RC-N — *(short title from §28)* | | | |

## Sign-off

- [ ] Every applicable §28 entry passes or has an accepted, documented waiver.
- [ ] This file committed alongside the version bump.
