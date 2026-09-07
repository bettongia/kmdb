# kmdb_example_todo

Sample Flutter to-do app demonstrating `kmdb` library integration — companion
code for the [Integration Guide](../../docs/integration_guide/README.md).

A to-do app with multiple projects, each with tasks (title, description,
priority, status, file attachments, comments). It exercises schema admission,
the secondary index, both full-text search surfaces, the vault, authenticated
sync, and encryption — every subsystem the guide covers, in one working,
tested app.

Desktop-only (macOS, Linux, Windows) — see the guide's "Platform scope"
section for why.

## Running it

```bash
cd packages/kmdb_example_todo
flutter pub get
flutter run -d macos   # or -d linux / -d windows
```

## Testing it

```bash
flutter test --coverage
```

The measured coverage bar (≥90%, enforced by `make cicd_example_todo`) applies
to `lib/src/repositories/`, `lib/src/codecs/`, and `lib/src/db/schemas.dart`.
The UI layer (`lib/src/ui/**` and `lib/main.dart`) is marked
`// coverage:ignore-file` and is smoke-tested only (`test/widget_test.dart`).

## `dependency_overrides` — a maintenance liability

This package's `pubspec.yaml` path-overrides three **unpublished** local
packages it depends on: `kmdb`, `kmdb_extractor_html`, and
`kmdb_extractor_markdown` (all still `version: 0.1.0`, not yet on pub.dev).
Every other transitive dependency — the whole betto_\* closure included —
resolves normally from pub.dev via `kmdb`'s own `dependencies:` block, exactly
as a real pub.dev consumer of `kmdb` would experience it.

This means the package can currently only be built from a clone of the `kmdb`
repository, not as a standalone pub.dev consumer. Once `kmdb`,
`kmdb_extractor_html`, and `kmdb_extractor_markdown` are published, these path
overrides should be dropped and the version constraints in `pubspec.yaml`
tightened to the published versions.

**Do not** copy `packages/kmdb_icloud/example/pubspec.yaml`'s
`dependency_overrides` block as a template for a new Flutter package in this
repo — it still carries a stale betto_\* version-pin block that predates
WI-9's removal of the workspace root's equivalent override block, and
replicating it would reintroduce exactly the drift WI-9 removed.
