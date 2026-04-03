# Database analysis utility in the CLI

**Status**: Investigated

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

Debugging an LSM database without tooling to inspect its raw storage files is
genuinely painful. WAL records, SSTable internals, and Manifest VersionEdits are
all opaque binary formats. The existing `verify` command checks document-level
integrity; this fills the complementary gap at the storage-engine level.

The primary audience is **developers debugging storage-engine issues and
preparing bug reports**. Typical scenarios include diagnosing an unexpected
compaction outcome, capturing Manifest state at the point a crash occurred, or
confirming that a WAL replay is producing the expected record sequence before
filing a defect. Because the output is frequently copy-pasted directly into bug
tickets, **JSON mode (`--mode json`) is the primary output path**;
human-readable table output is secondary.

A new `util` command in the CLI lets the developer point at one of those files
and get structured, readable output. Because outputs can be large (L2 SSTables
or long-running WAL files can contain thousands of entries), **summary output is
the default** — key metadata and record counts only. The developer passes
`--full` to request complete record-level output. This keeps the default output
concise enough to paste directly into a bug ticket without truncation.

Example CLI calls:

```bash
# Summary output (default): footer metadata and record counts
kmdb mydb util sstable <filename>

# Full record-level output
kmdb mydb util sstable <filename> --full

# WAL summary
kmdb mydb util wal <filename>

# WAL with every record
kmdb mydb util wal <filename> --full

# Manifest: current state (level → SSTable list)
kmdb mydb util manifest

# Manifest: complete VersionEdit history
kmdb mydb util manifest --full
```

This is a **read-only** facility. No writes to the database are permitted.

## Open questions

- None at this stage.

## Investigation

### SSTables

- `SstableReader` already handles footer parsing, index loading, and Bloom
  filter loading. Summary output reuses this without additional block scanning.
- `_BlockRef` is a `final class` with a leading underscore defined inside
  `sstable_reader.dart`. Returning `List<_BlockRef>` from any public getter is a
  Dart compilation error outside that library file. The solution is to rename it
  to `BlockRef` (public), keeping it in the same file. This is resolved in the
  engine changes below.
- `SstableMeta.toMap()` and `SstableRef.toMap()` **already exist** and do not
  need to be added.
- `SstableFooter` needs a `toMap()` for JSON output.

### WAL

- `WalReader` and `WalRecord` provide the necessary decoding logic.
- `WalRecord.key` is raw 16-byte binary (a UUIDv7). `toMap()` must hex-encode it
  — a raw integer array is not readable in JSON output and does not survive
  copy-paste. `WalRecord.value` should be represented as
  `{"compressionFlag": N, "byteLength": N}`; full CBOR decode of the value is
  out of scope for `util wal`.
- `replayStrict` must be used so corruption is surfaced immediately rather than
  silently skipped. When `CorruptedWalException` is thrown, the command outputs
  all records decoded before the failure point, then emits a structured
  corruption marker — in JSON mode:
  `"corruptedAt": {"recordIndex": N, "reason": "..."}`. This ensures the partial
  output is not lost when pasted into a bug ticket.

### Manifest

- `ManifestReader.replay()` replays VersionEdits into `ManifestState` and
  returns only the final computed state. It does not retain the edit sequence.
- For summary output, `replay()` is sufficient — no change to `ManifestReader`
  or `ManifestState` is needed for the default path.
- For full output (`--full`), a new `ManifestReader.replayEdits()` method
  returns `List<VersionEdit>` without modifying any `ManifestState`. This keeps
  the operational and diagnostic paths cleanly separated. The existing
  `replay()` is unchanged.
- `VersionEdit` does not currently have a `toMap()` method and one is needed.

### CLI integration

- A new `UtilCommand` acts as a parent for `sstable`, `wal`, and `manifest`
  subcommands.
- All subcommands open files directly via `StorageAdapterNative` — **no
  `KvStore.open()`, no lock acquisition**. This allows inspection of a database
  that is currently open in another process, which is a primary use case.
- Path resolution: SSTable and WAL filenames are resolved relative to `sst/` and
  the WAL directory under `store.stats().dbDir`.
- Output respects the global `--mode` flag (`json` vs `table`).

### Package boundary

The engine types required by the `util` subcommands (`SstableReader`,
`WalReader`, `ManifestReader`, etc.) are not exported from `kmdb.dart` and must
not be added there. The solution is a separate sub-library,
`lib/kmdb_analysis.dart`, described in the implementation plan below.

## Implementation plan

### Step 1: Create `lib/kmdb_analysis.dart` sub-library (`packages/kmdb`)

The storage-engine types required by the `util` subcommands are not part of the
primary public API and must not be added to `kmdb.dart`. Adding storage
internals to the public application barrel would impose an ongoing maintenance
burden and pollute the API surface that library consumers see.

The solution is a separate Dart sub-library: `lib/kmdb_analysis.dart`. This is
an idiomatic Dart pattern for exposing a wider API surface to specific consumers
(tooling, test utilities, advanced integrations) without widening the primary
user-facing library. The CLI imports `package:kmdb/kmdb_analysis.dart` alongside
`package:kmdb/kmdb.dart` where both are needed; neither proxies the other.

**Why `kmdb_analysis.dart`:**

- `util` is too vague — it signals a grab-bag of miscellaneous helpers.
- `internals` implies "no guarantees", which is not the right contract for a
  deliberate, tested diagnostic API.
- `debug` implies runtime gating behind `kDebugMode` — not appropriate for a CLI
  tool that runs in all contexts.
- `diagnostics` has strong Flutter-framework connotations (the `DiagnosticsNode`
  / `debugFillProperties` tree) that would mislead Flutter developers.
- `analysis` is precise, matches the plan's own language, carries no misleading
  connotations, and reads naturally at the import site.

**Exports:**

```dart
// lib/kmdb_analysis.dart  (diagnostic API — no backwards-compatibility guarantee)
export 'src/engine/sstable/sstable_reader.dart' show SstableReader, SstEntry, BlockRef, CorruptedSstableException;
export 'src/engine/sstable/sstable_writer.dart' show SstableFooter;
export 'src/engine/wal/wal_reader.dart' show WalReader, WalRecord, WalRecordType;
export 'src/engine/wal/wal_exceptions.dart' show CorruptedWalException;
export 'src/engine/manifest/manifest_reader.dart' show ManifestReader, ManifestState;
export 'src/engine/manifest/version_edit.dart' show VersionEdit, SstableMeta;
```

The library file carries the standard Apache 2.0 license header and a doc
comment stating this is a diagnostic API with no backwards-compatibility
guarantee beyond the stable versioning of the `kmdb` package itself.

- [ ] Create `lib/kmdb_analysis.dart` with the exports above.

### Step 2: Engine changes (`packages/kmdb`)

- [ ] **Rename `_BlockRef` to `BlockRef`** (public): it is a `final class`
      defined in `sstable_reader.dart`. Rename it and add a doc comment. This is
      required because returning `List<_BlockRef>` from any public getter is a
      Dart compilation error outside the defining library file.
- [ ] **SSTable analysis support**:
  - Update `SstableReader` to expose `SstableFooter footer`,
    `BloomFilter filter`, and `List<BlockRef> index` via public getters.
  - Add `toMap()` to `SstableFooter`.
  - `SstableMeta.toMap()` and `SstableRef.toMap()` already exist — do not
    re-implement them.
- [ ] **WAL analysis support**:
  - Add `toMap()` to `WalRecord` and `WalRecordType`.
  - `WalRecord.toMap()` must hex-encode the key (raw 16-byte UUIDv7 binary).
  - The value must appear as `{"compressionFlag": N, "byteLength": N}` — full
    CBOR decode is out of scope for `util wal`.
- [ ] **Manifest analysis support**:
  - Add `toMap()` to `VersionEdit`. (`SstableMeta.toMap()` already exists.)
  - Add `ManifestReader.replayEdits()` returning `List<VersionEdit>` without
    updating any `ManifestState`. The existing `replay()` method is unchanged.
    `replayEdits()` is used exclusively by `util manifest --full`.

### Step 3: CLI changes (`packages/kmdb_cli`)

- [ ] **Implement `UtilCommand`**:
  - Create `lib/src/commands/util_command.dart`.
  - Import `package:kmdb/kmdb_analysis.dart` for engine types.
  - Support subcommands: `sstable`, `wal`, `manifest`.
  - Add a `--full` flag to emit complete record-level output. Summary (metadata
    and counts) is the default.
- [ ] **`util sstable <filename>`**:
  - Resolve the filename relative to the `sst/` subdirectory of
    `store.stats().dbDir`.
  - Open the file directly via `StorageAdapterNative` — no `KvStore.open()`, no
    lock acquisition.
  - Summary output (default): footer fields, Bloom filter stats (`numBits`,
    `numHashFunctions`, estimated FPR), count of index entries.
  - Full output (`--full`): all of the above plus each `BlockRef` (offset and
    length) and every key/value pair from every data block.
  - On `CorruptedSstableException`: emit a structured error — in JSON mode as a
    top-level `"error"` field; in table mode as a stderr message.
  - On file not found: emit a clear error in the same manner.
- [ ] **`util wal <filename>`**:
  - Open the file directly via `StorageAdapterNative` — no lock acquisition.
  - Use `WalReader.replayStrict` to surface corruption immediately rather than
    silently skipping bad records.
  - Summary output (default): total record count, HLC range (min/max, formatted
    as ISO-8601 physical + logical counter), list of distinct namespaces seen.
  - Full output (`--full`): every record with type, HLC, namespace, hex-encoded
    key, and value summary (`{"compressionFlag": N, "byteLength": N}`).
  - On `CorruptedWalException`: output all records decoded before the failure,
    then emit `"corruptedAt": {"recordIndex": N, "reason": "..."}` as a
    top-level JSON field. This ensures the partial output is not lost when
    copy-pasted into a bug ticket.
- [ ] **`util manifest`**:
  - Open the Manifest directly via `StorageAdapterNative` — no lock acquisition.
    Resolve the active manifest filename from the `CURRENT` file in `dbDir`.
  - Summary output (default): current `ManifestState` via
    `ManifestReader.replay()` — level → list of SSTable filenames. No edit
    sequence is loaded for the summary path.
  - Full output (`--full`): complete `VersionEdit` sequence via
    `ManifestReader.replayEdits()`, each edit rendered via
    `VersionEdit.toMap()`.
- [ ] **Registration**:
  - Register `UtilCommand` in `cli_runner.dart`.

### Step 4: Verification and testing

- [ ] **Unit tests** in `packages/kmdb_cli/test/util_command_test.dart` using
      mock storage. Required scenarios:
  - File not found for each subcommand.
  - Corruption mid-stream for `util wal` — confirm records before the corruption
    point are emitted and the `"corruptedAt"` marker is present in JSON output.
  - Summary vs full output for each subcommand.
  - `util manifest` on an empty database (no edits).
- [ ] **Manual verification** on a real database:
  - Confirm `util manifest`, `util sstable <file>`, and `util wal <file>` all
    produce correct output.
  - Confirm `--full` and summary-default behavior are correct.
  - Confirm that a database currently open in another process can be inspected
    (no lock contention).

## Summary

{Dot points highlighting the work undertaken}
