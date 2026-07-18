# Releasing KMDB

This document describes how KMDB packages are published to pub.dev, in what
order, and the per-release checklist convention that gates a release on
[§28 Release Checklist](../spec/28_release_checklist.md).

This document is not itself a checklist — it describes the *process*. The
per-release checklist (what actually gets checked off for a specific release)
is a copy of [`TEMPLATE.md`](TEMPLATE.md) named after the version being
released, e.g. [`0.1.0-dev.1.md`](0.1.0-dev.1.md).

## Which packages are publishable

| Package | Publishable? | Notes |
| :------ | :------------ | :---- |
| `kmdb` | Yes | Foundation package; everything else depends on it. |
| `kmdb_cli` | Yes | Depends on `kmdb`, `kmdb_google_drive`, and the three extractors. |
| `kmdb_google_drive` | Yes | Depends only on `kmdb`. |
| `kmdb_extractor_pdf` | Yes | Depends only on `kmdb`. |
| `kmdb_extractor_html` | Yes | Depends only on `kmdb`. |
| `kmdb_extractor_markdown` | Yes | Depends only on `kmdb`. |
| `kmdb_flutter` | Yes, but **hand-published** | Non-workspace Flutter package. See _Hand-publishing the Flutter packages_ below. |
| `kmdb_icloud` | Yes, but **hand-published** | Non-workspace Flutter package. See _Hand-publishing the Flutter packages_ below. |
| `kmdb_harness` | **Never** | Internal multi-device test harness, permanently `publish_to: none`. Not part of any release. |

The `betto_*` packages (`betto_common`, `betto_schema`, `betto_zstd`,
`betto_mediatype_detector`, `betto_lexical`, `betto_inferencing`,
`betto_charset_detector`, `betto_lang_detector`, and their own transitive
`betto_icu`/`betto_builder_tools`/`betto_onnxrt` dependencies) are published
independently, in their own repositories, ahead of any KMDB release — they are
not part of this process. Check that the versions pinned in the root
`pubspec.yaml`'s `dependency_overrides` are still the versions actually
published on pub.dev before starting a release; if a `betto_*` package needs a
fresh version, that happens in its own repo first.

## Publish process

Publishing is a two-stage process: **prep** (get the workspace into a
publish-ready state, no `dart pub publish` calls) and **publish** (the actual
`dart pub publish` calls, in a strict order the server enforces).

### Stage 1 — Prep

For each of the six Dart-publishable workspace members (`kmdb`, `kmdb_cli`,
`kmdb_google_drive`, `kmdb_extractor_pdf`, `kmdb_extractor_html`,
`kmdb_extractor_markdown`):

1. Confirm `publish_to: none` is **not** present in the package's
   `pubspec.yaml` (it must be actively removed before a package's first
   publish — this is easy to forget).
2. Confirm a `LICENSE` file exists in the package directory. `dart pub
   publish` hard-errors without one — the repo-root `LICENSE` does not
   satisfy this; each package needs its own copy.
3. Confirm `repository:` (or `homepage:`) is set.
4. Confirm a `CHANGELOG.md` exists and has an entry for the version being
   released.
5. Confirm every dependency in the package's `dependencies:` block has a
   real, pub.dev-resolvable version constraint — no blank entries **and no
   explicit `any`** (both trigger the same "should have a version
   constraint" warning). Workspace members resolve blank constraints locally
   via `resolution: workspace` during development, but pub.dev has no
   knowledge of the workspace: a blank or `any` constraint publishes as
   `any`, which `dart pub publish` only warns about (not a hard error), but
   it's bad practice and should be fixed before
   publishing. Member-to-member constraints should point at the version being
   released for that member (e.g. `kmdb: ^0.1.0-dev.1`); member-to-`betto_*`
   constraints should copy the exact range already pinned in the root
   `pubspec.yaml`'s `dependency_overrides`.
6. Confirm the package version matches the version being released (see
   _Version-bump rules_ below).

None of this involves running `dart pub publish` — it's entirely local
pubspec/file editing, verified with `dart pub publish --dry-run` per package.
Two categories of dry-run output are expected and not a blocker:

- **"1 checked-in file is modified in git"** for `pubspec.yaml` — expected
  while Stage 1's edits are uncommitted; resolves once the version bump is
  committed.
- **"Non-dev dependencies are overridden in ../../pubspec.yaml"** (one hint
  per overridden package) — expected for every package while working inside
  this Pub workspace, since the root `pubspec.yaml`'s `dependency_overrides`
  intentionally pin consistent versions across the monorepo during
  development. This is informational, not a publish blocker.

**Important caveat about dry-run:** `dart pub publish --dry-run` resolves
workspace-relative dependencies **locally**, even if the sibling package has
never been published. A dry-run for `kmdb_cli` will pass cleanly even before
`kmdb` has ever reached pub.dev, because the workspace resolves `kmdb`
locally. This gives false confidence about publish order — dry-run tells you
a package's own pubspec is well-formed, not that its dependencies are
actually resolvable from pub.dev yet. The bottom-up publish order below is
enforced by the pub.dev **server**, not by dry-run, and must be followed
regardless of what dry-run reports.

### Stage 2 — Publish

Publish in this order — each step depends on the previous one having
succeeded on pub.dev, not just locally:

1. **`kmdb`** — the foundation; every other package depends on it.
2. **`kmdb_google_drive`, `kmdb_extractor_pdf`, `kmdb_extractor_html`,
   `kmdb_extractor_markdown`** — each depends only on `kmdb`, so these four
   can be published in any order relative to each other, but only after step 1.
3. **`kmdb_cli`** — depends on `kmdb` *and* `kmdb_google_drive` *and* all
   three extractors, so it must come after all of them.
4. **`kmdb_flutter`, `kmdb_icloud`** — hand-published last; see below.

`kmdb_harness` is never published — it isn't in the above list because it's
permanently internal, not because it was overlooked.

## Hand-publishing the Flutter packages

`kmdb_flutter` and `kmdb_icloud` are **not** Dart workspace members — they
depend on `flutter: sdk: flutter`, which the workspace's Dart-only CI runners
(Linux, Windows) don't have. They resolve `kmdb` via a `path:` dependency
(`kmdb: {path: ../kmdb}`) rather than the `resolution: workspace` +
blank-constraint pattern the six Dart-only members use, and they publish by
hand from a macOS/Flutter-capable machine, after everything else in Stage 2
has landed on pub.dev.

Because a `path:` dependency is structurally different from a blank
workspace-resolved one, this process has **not** empirically verified the
exact pubspec end-state these two packages need for a real publish (the
Stage 1 prep steps above were verified against the six Dart-only workspace
members specifically). Before hand-publishing either package, the publisher
must verify — not assume — the following:

1. **The `path:` dependency in `dependencies:` must become a real version
   constraint** (e.g. `kmdb: ^0.1.0-dev.1`) before publishing — a `path:`
   dependency in a package's main `dependencies:` block is a hard
   `dart pub publish` error, not a warning. Confirm with
   `dart pub publish --dry-run` from the package directory after making this
   change.
2. **Whether the mirrored `path:` entry in `dependency_overrides` also needs
   removing is unverified.** Both packages carry a `dependency_overrides`
   block that mirrors the root workspace's overrides, including a `kmdb:
   {path: ../kmdb}` override used for local development before `kmdb` exists
   on pub.dev. Whether `dependency_overrides` are stripped from the published
   archive (in which case leaving the path override in place is actually
   *useful* for local dev) or whether a `path:` override also triggers a
   publish error is not confirmed — check pub.dev's publish validation output
   directly rather than assuming either answer.
3. **`kmdb_icloud`'s `dev_dependencies: kmdb_harness: {path: ../kmdb_harness}`
   targets a permanently-unpublished package.** Whether a `path:`
   *dev*-dependency blocks publish (dev dependencies are not part of what a
   consumer resolves, so this may be a non-issue) is also unverified. If it
   does block publishing, the dev-dependency (or whatever test relies on it)
   needs removing or relocating before `kmdb_icloud` can be published.

Add each package's own `LICENSE`, `repository:`, and `CHANGELOG.md` (same
requirements as Stage 1 above) before attempting to publish either package —
neither currently has a `LICENSE` file.

## Version-bump rules

The workspace's coordinator `pubspec.yaml` (`kmdb_workspace`, itself never
published — `publish_to: none`) is not required to move in lockstep with
every member on every release, but for this first release **all publishable
members and the root coordinator are versioned identically**:
`0.1.0-dev.1`, a prerelease matching the convention already used by the
`betto_*` ecosystem KMDB depends on. This sidesteps the awkwardness of a
"stable" package depending on prerelease `betto_*` constraints.

For future releases, packages may diverge on **minor/patch** versions
(e.g. a patch release of `kmdb_cli` alone doesn't require bumping `kmdb`),
but must **never diverge on major version** — the root coordinator's version
is the release-train label, and no published member may carry a different
major version than it. This is currently a **documented convention, checked
by hand during the release process** — there is no mechanical CI check for
major-version parity across `packages/*/pubspec.yaml`. Adding one is a
candidate future roadmap item; it was deliberately scoped out of this release
process work to keep this a docs-only change (see the `kmdb-plan-reviewer`
discussion on `plan_0_09_release_process_doc.md`'s Q2).

## Per-release checklist convention

Each release gets its own checklist file in this directory, named after the
version being released (e.g. `0.1.0-dev.1.md`), created by copying
[`TEMPLATE.md`](TEMPLATE.md). The template is **not** a copy of
[§28](../spec/28_release_checklist.md)'s content — it references §28's
current entries by ID (`RC-1`, `RC-2`, …) so that the per-release checklist
is always generated against whatever §28 looks like *at release time*,
rather than going stale as §28 grows. Do not hard-code an RC count anywhere
in this process — check `docs/spec/28_release_checklist.md` directly for the
current list before authoring a new release's checklist.

For each release:

1. Copy `TEMPLATE.md` to `{version}.md` in this directory.
2. Read through the current [§28](../spec/28_release_checklist.md) and, for
   every `RC-N` entry, mark it `[x]` (run and passed) if its **Applies when**
   condition is true for this release's changes, or `[-]` (not applicable) if
   it isn't. A release is not cut until every applicable entry passes or has
   a documented, accepted waiver (see §28's own "How to use it" section).
3. Work through the publish-order checklist in the template, checking off
   each Stage 1 prep item and each Stage 2 publish step as completed.
4. Commit the completed checklist file alongside the version bump.

See [`0.1.0-dev.1.md`](0.1.0-dev.1.md) for a worked example against the
current `§28` state.
