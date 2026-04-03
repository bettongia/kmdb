---
name: kmdb project overview for plan reviews
description: Key architectural facts and conventions that recur when reviewing plans — package layout, public API boundary, engine internals visibility
type: project
---

The `kmdb` package public surface is `lib/kmdb.dart`. Storage-engine internals
(`SstableReader`, `WalReader`, `ManifestReader`, `BloomFilter`, `WalRecord`,
`VersionEdit`, `SstableFooter`, `_BlockRef`) are NOT exported from this barrel.
Any plan that needs the CLI or another package to consume these types must
explicitly decide how to expose them — either via a separate engine barrel
(e.g. `kmdb_engine.dart`) or targeted additions to `kmdb.dart`.

**Why:** The CLI package depends on `package:kmdb`, not on internal Dart library
files directly. Accessing unexported types from outside the library is a
compilation error.

**How to apply:** When reviewing plans that involve the CLI reading raw engine
files (SSTable, WAL, Manifest), flag the package boundary question as a required
design decision before implementation begins.

Other facts worth keeping in mind:
- `SstableMeta.toMap()` and `SstableRef.toMap()` already exist (as of 2026-04-03).
- `_BlockRef` is a library-private type; any plan exposing it must rename/publicize it.
- `ManifestReader.replay()` returns only `ManifestState` (the final state), not the edit history.
- The CLI uses `DatabaseOpener.open()` which acquires an exclusive LOCK — incompatible with inspecting a live database.
- All 600 kmdb + 112 kmdb_cli tests passing as of 2026-03-30; 90% coverage required.
