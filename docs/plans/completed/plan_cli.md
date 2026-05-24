---
title: KMDB CLI
subtitle: Implementation Plan
toc-title: "Contents"
...

# Agent Instructions

Work through the implementation of each plan phase.

- Make sure you keep this document up-to-date as you progress.
- Make sure test coverage is at least 90%
- Ensure that appropriate documentation has been provided, especially a brief user guide in the packages/kmdb_cli/README.md file
- Commit each phase to Git when the phase has been completed

# Overview

This plan covers the implementation of `kmdb`, a command-line interface for
the KMDB database engine. The design follows the SQLite CLI model: a simple,
composable tool that works well in both human-interactive and scripted contexts.

The CLI will live in a separate Dart package (`packages/kmdb_cli/`) and the
root repository will be converted to a **Pub Workspace** so both packages share
a single `dart pub get` invocation and resolve dependencies together.

The work is split into two phases:

- **Phase 1 — Batch CLI**: A single executable that accepts commands as
  arguments or reads them from stdin/a file. No interactive features.
- **Phase 2 — Interactive REPL**: A persistent shell with a readline-style
  interface, command history, dot-commands, and a watch mode.

---

# Background: SQLite CLI Design Principles

The SQLite `sqlite3` shell is a useful model because:

1. **Two modes, one binary.** The same binary runs interactively or in batch
   depending on whether stdin is a tty and whether commands were given on the
   command line.
2. **Dot-commands augment the query language.** Commands like `.tables`,
   `.mode json`, and `.output file.json` are CLI-level primitives that control
   output, manage state, and introspect the database — they are not part of the
   database's own API.
3. **Output modes decouple data from presentation.** The same query can emit
   table, JSON, CSV, or Markdown by changing a single setting.
4. **Script files are first-class.** A `.read file` dot-command (or stdin
   redirect) feeds a sequence of commands into the CLI as if typed.

KMDB's CLI follows the same principles, adapted for a document database: queries
return documents (JSON objects), collections replace tables, and the filter DSL
replaces SQL.

---

# Monorepo & Workspace Setup

Before writing any CLI code, the repository must adopt **Pub Workspaces** so the
CLI package can depend on the core `kmdb` package by path while sharing a single
lockfile.

**Target layout:**

```
kmdb/                          ← workspace root
  pubspec.yaml                 ← workspace manifest (workspace: packages: [...])
  packages/
    kmdb/                      ← existing library (moved here)
      pubspec.yaml
      lib/
      test/
    kmdb_cli/                  ← new CLI package
      pubspec.yaml             ← dep: kmdb: {path: ../kmdb}
      bin/
        kmdb.dart              ← entry point
      lib/
        src/
      test/
```

The workspace root `pubspec.yaml` declares no code of its own; it is a pure
workspace coordinator. All `dart test`, `dart analyze`, and `dart format`
invocations work from the root and apply to all packages.

> **Note:** This restructuring touches the existing `kmdb` package's import
> paths (e.g. CI scripts, README examples). Those must be updated as part of the
> workspace migration step.

---

# Phase 1: Batch CLI

## Goals

- Accept a database path and one or more commands as positional arguments.
- Read commands from stdin or a file when no inline commands are given.
- Emit well-structured output (JSON by default; table and CSV modes also
  supported).
- Exit with a nonzero status code on any error unless `--continue-on-error` is
  set.
- Be fully scriptable: no prompts, no colour codes unless stdout is a tty.

## Invocation Forms

```bash
# Execute a single inline command
kmdb mydb.kmdb get notes <key>

# Execute multiple inline commands (processed in order, then exit)
kmdb mydb.kmdb ".mode table" "scan notes"

# Read commands from a file
kmdb mydb.kmdb --read script.kmdb

# Pipe commands in
echo "scan notes --limit 5" | kmdb mydb.kmdb

# Print database statistics and exit
kmdb mydb.kmdb stats
```

## Global Flags

| Flag                  | Default | Description                                          |
| :-------------------- | :------ | :--------------------------------------------------- |
| `--mode` / `-m`       | `json`  | Output format: `json`, `table`, `csv`, `line`, `raw` |
| `--output` / `-o`     | stdout  | Write output to this file instead of stdout          |
| `--read` / `-r`       | —       | Read commands from file                              |
| `--continue-on-error` | false   | Keep running after a command error (batch mode)      |
| `--no-color`          | auto    | Disable ANSI colour codes                            |
| `--compact`           | false   | Compact JSON output (no indentation)                 |
| `--version`           | —       | Print version and exit                               |
| `--help` / `-h`       | —       | Print usage and exit                                 |

## Commands

Commands are short verb-noun phrases. Each command prints its result to stdout
in the active output mode and exits 0 on success.

### Data Commands

```bash
# Retrieve a document by key
kmdb <db> get <namespace> <key>

# Upsert a document. Value is read from --value, a file, or stdin
kmdb <db> put <namespace> --value '{"id":"...","title":"hello"}'
kmdb <db> put <namespace> < doc.json

# Delete a document
kmdb <db> delete <namespace> <key>

# Scan a namespace, optionally filtered
kmdb <db> scan <namespace> [options]
  --filter '<json filter expression>'   Filter DSL expression (see below)
  --order-by <field>                    Sort field
  --desc                                Descending order
  --limit <n>                           Maximum results
  --offset <n>                          Skip first n results
  --key-prefix <str>                    Only keys with this prefix

# Count documents
kmdb <db> count <namespace> [--filter '<expr>']
```

### Introspection Commands

```bash
# List all user-visible namespaces
kmdb <db> collections

# Show index definitions for a namespace
kmdb <db> indexes <namespace>

# Show database statistics (file sizes, level info, SSTable count, etc.)
kmdb <db> stats

# Show engine version info, device ID, HLC clock value
kmdb <db> info
```

### Import / Export Commands

```bash
# Export a namespace to newline-delimited JSON (NDJSON)
kmdb <db> export <namespace> [--output file.ndjson]

# Import NDJSON documents into a namespace
kmdb <db> import <namespace> [--input file.ndjson]
  --on-conflict ignore|replace|error    Default: replace

# Dump the entire database as NDJSON to stdout (one namespace per header line)
kmdb <db> dump [--output archive.ndjson]

# Restore from a dump
kmdb <db> restore [--input archive.ndjson]
```

### Maintenance Commands

```bash
# Force a memtable flush
kmdb <db> flush

# Run full compaction
kmdb <db> compact

# Verify SSTable checksums and Bloom filters
kmdb <db> verify
```

## Filter Expression Format

The `--filter` flag accepts a JSON representation of the filter DSL. This is a
simple recursive structure:

```json
// Field comparison
{"field": "status", "op": "eq", "value": "active"}

// Logical combination
{"and": [
  {"field": "status", "op": "eq", "value": "active"},
  {"field": "address.city", "op": "eq", "value": "London"}
]}

// Available ops: eq, ne, lt, lte, gt, gte,
//                startsWith, endsWith, contains,
//                containsAll, containsAny, isNull, isNotNull
```

The CLI parses this JSON and constructs the appropriate `Filter` objects from
the `kmdb` library. This avoids inventing a new query language for Phase 1 while
keeping the filter human-readable.

## Output Modes

| Mode      | Description                                     |
| :-------- | :---------------------------------------------- |
| `json`    | Indented JSON array of documents (default)      |
| `compact` | Single-line JSON array                          |
| `ndjson`  | One JSON object per line (newline-delimited)    |
| `table`   | Column-aligned ASCII table; keys as columns     |
| `csv`     | RFC 4180 CSV with header row                    |
| `line`    | Each field on its own line: `field = value`     |
| `raw`     | Raw bytes (for single-key get on binary values) |

For `table`, `csv`, and `line` modes the set of columns is derived from the
union of keys seen in the first 100 documents (configurable). Documents with
missing keys show an empty cell.

## Script File Format

A script file (`.kmdb`) contains one command per line, with blank lines and `#`
comment lines ignored. Dot-commands (Phase 2) are not supported in Phase 1
scripts.

```
# Export everything from notes
scan notes --order-by createdAt --desc
```

## Error Handling

- Any error (document not found, invalid filter, corrupt SSTable) prints a
  single-line error to stderr and exits with code 1.
- `--continue-on-error` prints the error but continues processing the next
  command in a script.
- Partial output (e.g. a scan that errors mid-stream) appends a trailing
  `{"error": "..."}` line in JSON mode so the reader can detect truncation.

## Package Structure

```
packages/kmdb_cli/
  bin/
    kmdb.dart                  ← main(); calls CliRunner.run(args)
  lib/
    src/
      cli_runner.dart          ← argument parsing (package:args), dispatch
      commands/
        get_command.dart
        put_command.dart
        delete_command.dart
        scan_command.dart
        count_command.dart
        collections_command.dart
        indexes_command.dart
        stats_command.dart
        info_command.dart
        export_command.dart
        import_command.dart
        dump_command.dart
        restore_command.dart
        flush_command.dart
        compact_command.dart
        verify_command.dart
      output/
        output_mode.dart       ← OutputMode enum + factory
        json_formatter.dart
        table_formatter.dart
        csv_formatter.dart
        line_formatter.dart
      filter/
        filter_parser.dart     ← JSON → Filter DSL objects
      database_opener.dart     ← open KmdbDatabase from a path
  test/
    commands/
      get_command_test.dart
      scan_command_test.dart
      import_export_test.dart
      ...
    output/
      table_formatter_test.dart
      csv_formatter_test.dart
      ...
    filter/
      filter_parser_test.dart
```

## Key Dependencies (kmdb_cli pubspec)

```yaml
dependencies:
  kmdb: { path: ../kmdb }
  args: ^2.6.0 # CLI argument parsing

dev_dependencies:
  test: ^1.25.6
  lints: ^6.0.0
```

## Testing Strategy

- All commands are tested against a `MemoryStorageAdapter` to avoid disk I/O.
- A `CliRunner` test helper captures stdout/stderr as strings.
- Output format tests use golden files for table and CSV modes.
- Error-path tests verify exit codes and stderr messages.
- At least one integration test opens a real on-disk database to verify the
  `database_opener.dart` path.

## Phase 1 Acceptance Criteria

- [x] Workspace migration complete; `dart test` and `dart analyze` pass from the
      root for both packages.
- [x] All 15 commands implemented with `--help` text.
- [x] All 6 output modes implemented.
- [x] Filter expression JSON parser covers all DSL operators.
- [x] Import/export roundtrip test: export a namespace, clear it, re-import,
      verify all documents match.
- [x] Script file execution works via `--read`.
- [x] Stdin pipe execution works.
- [x] Exit codes are correct (0 = success, 1 = error).
- [x] Test coverage ≥ 90%.

---

# Phase 2: Interactive REPL

## Goals

- A persistent interactive shell for exploring and editing KMDB databases.
- Readline-style input: line editing, command history persisted to
  `~/.kmdb_history`.
- Dot-commands to control session state (output mode, active namespace,
  pagination, etc.).
- Multi-line query support with a continuation prompt.
- A `watch` mode that re-runs a query on every database change.
- Colour-coded output when stdout is a tty.
- Context-aware tab completion (dot-commands, namespace names, field names).

## Launching the REPL

```bash
# Open database in interactive mode
kmdb mydb.kmdb

# Same binary — REPL activates when no inline commands are given
# and stdin is a tty
```

## Prompt Design

```
kmdb[mydb]> _                  ← default prompt
kmdb[mydb:notes]> _            ← with active namespace set
   ...> _                      ← continuation prompt (multi-line input)
```

The database name (last path component without extension) appears in the prompt
to orient the user. Setting an active namespace shortens subsequent commands.

## Dot-Commands

Dot-commands begin with `.` and are processed entirely by the CLI (not sent to
the database). They are always single-line.

### Session State

| Command                | Description                                                   |
| :--------------------- | :------------------------------------------------------------ |
| `.mode <mode>`         | Set output mode (`json`, `table`, `csv`, `line`, `ndjson`)    |
| `.output [file]`       | Redirect output to file; `.output` (no args) resets to stdout |
| `.once [file]`         | Redirect only the next command's output                       |
| `.compact on\|off`     | Toggle compact JSON vs. pretty-printed                        |
| `.color on\|off\|auto` | Toggle ANSI colour output                                     |
| `.headers on\|off`     | Toggle column headers in table/csv modes                      |
| `.nullvalue <str>`     | String shown for null/missing fields in table mode            |
| `.limit <n>`           | Default `--limit` for scan commands (0 = no limit)            |
| `.namespace [ns]`      | Set the active namespace; bare commands use it by default     |
| `.echo on\|off`        | Echo each command before executing it                         |
| `.bail on\|off`        | Exit on error vs. print and continue (default: continue)      |
| `.timer on\|off`       | Print execution time after each command                       |

### Introspection

| Command                | Description                                                |
| :--------------------- | :--------------------------------------------------------- |
| `.collections`         | List all user namespaces                                   |
| `.indexes [namespace]` | Show index definitions                                     |
| `.stats`               | Database statistics (file size, SSTable count, level info) |
| `.info`                | Engine version, device ID, HLC value                       |
| `.show`                | Print all current session settings                         |
| `.history [n]`         | Print last n history entries (default: 20)                 |

### I/O and Scripting

| Command                      | Description                                                   |
| :--------------------------- | :------------------------------------------------------------ |
| `.read <file>`               | Execute commands from a file (supports Phase 1 script format) |
| `.export <namespace> [file]` | Export namespace to NDJSON                                    |
| `.import <namespace> <file>` | Import NDJSON into namespace                                  |
| `.dump [file]`               | Full database dump                                            |
| `.restore <file>`            | Restore from dump                                             |

### Reactive Queries

| Command            | Description                                           |
| :----------------- | :---------------------------------------------------- |
| `.watch [command]` | Re-run [command] on every write event; Ctrl+C to stop |

Example:

```
kmdb[mydb:notes]> .watch scan notes --limit 5 --order-by updatedAt --desc
```

This subscribes to `writeEvents` on the `notes` namespace and re-executes the
scan on each event, clearing and redrawing the output. Useful during development
for watching a collection in real time.

### Maintenance

| Command        | Description                                     |
| :------------- | :---------------------------------------------- |
| `.flush`       | Force memtable flush to SSTable                 |
| `.compact`     | Run full compaction                             |
| `.verify`      | Verify SSTable checksums                        |
| `.open <path>` | Close current database and open a different one |
| `.close`       | Close the current database (prompt remains)     |

### Help and Exit

| Command                  | Description                                       |
| :----------------------- | :------------------------------------------------ |
| `.help [command]`        | Show help for all dot-commands, or a specific one |
| `.quit` / `.exit [code]` | Exit the REPL with optional exit code             |

## Multi-Line Input

A command is considered complete when:

1. It does not end with `\` (line continuation character), **or**
2. For JSON filter arguments, all braces and brackets are balanced.

```
kmdb[mydb]> scan notes \
   ...>   --filter '{"and": [
   ...>     {"field": "status", "op": "eq", "value": "active"}
   ...>   ]}' \
   ...>   --limit 10
```

## Tab Completion

Completions are context-sensitive:

| Position                                    | Completions offered                           |
| :------------------------------------------ | :-------------------------------------------- |
| First token starts with `.`                 | Dot-command names                             |
| First token (no `.`)                        | Command names (`get`, `scan`, `put`, …)       |
| After `scan` / `get` / `count` / `delete`   | Namespace names (from live DB)                |
| After `--order-by` or `--filter '{"field":` | Field names from namespace's recent documents |
| After `.mode`                               | Available mode names                          |
| After `.namespace`                          | Namespace names                               |

Completion is offered via `dart:io`'s `stdin` raw mode or a lightweight
`readline`-style wrapper. A `CompletionProvider` interface will abstract this so
it can be tested without a real tty.

## Command History

- History is stored in `~/.kmdb_history` (one entry per line, UTF-8).
- Up to 1,000 entries retained; oldest entries are dropped.
- History is shared across all database sessions.
- `.history [n]` prints the last n entries with line numbers.
- `!n` re-executes history entry number n.
- History is written on clean exit (`.quit`, `.exit`, Ctrl+D) and on SIGINT.

## Colour and Formatting

When stdout is a tty:

- Document keys are highlighted in one colour, values in another.
- Null/missing values are shown in a muted colour.
- Error messages are red.
- Timing output (`.timer on`) is displayed in a muted style after each result.

When stdout is not a tty (pipe or file), no ANSI codes are emitted regardless of
`.color` setting.

## Package Additions (Phase 2)

```
packages/kmdb_cli/
  lib/
    src/
      repl/
        repl_runner.dart       ← REPL loop: read → dispatch → print
        dot_command.dart       ← DotCommand interface + registry
        dot_commands/
          mode_command.dart
          namespace_command.dart
          watch_command.dart
          read_command.dart
          ... (one file per dot-command)
        session_state.dart     ← output mode, active namespace, flags
        history.dart           ← read/write ~/.kmdb_history
        completer.dart         ← CompletionProvider interface + impl
        input_reader.dart      ← tty detection, raw-mode line reader
        prompt.dart            ← prompt string construction
        colorizer.dart         ← ANSI codes, tty detection
```

## Testing Strategy (Phase 2)

- `ReplRunner` tests use a fake `InputReader` that emits pre-defined lines and a
  `StringBuffer` as the output sink, enabling headless REPL testing.
- `CompletionProvider` is tested against a known set of namespaces/fields using
  a `MemoryStorageAdapter`.
- History read/write uses a temp file; tests clean up after themselves.
- `.watch` tests inject a fake `writeEvents` stream that emits at controlled
  times.
- All dot-commands have at least one test covering the happy path and one
  covering invalid arguments.

## Phase 2 Acceptance Criteria

- [ ] REPL launches when no inline commands are given and stdin is a tty.
- [ ] All dot-commands implemented with `.help` text.
- [ ] Multi-line input with `\` continuation works.
- [ ] Tab completion covers commands, namespaces, and flag values.
- [ ] Command history persisted to `~/.kmdb_history`; survives restart.
- [ ] `.watch` re-renders results on `writeEvents` emission; Ctrl+C stops it.
- [ ] Colour output works on tty; is suppressed when piping.
- [ ] `.read <file>` executes Phase 1 script files from inside the REPL.
- [ ] `.open` switches database without restarting the shell.
- [ ] Test coverage ≥ 90%.

---

# Shared Considerations

## Codec Strategy

The CLI has no knowledge of the application's `KmdbCodec<T>`. It operates at the
raw `Map<String, dynamic>` level by using an identity codec that treats every
document as a plain JSON object. Documents are decoded from CBOR storage bytes
using the engine's internal `ValueCodec` and presented as-is. The user provides
JSON on input, and the CLI encodes it.

This means the CLI cannot enforce application-level schema validation, but it
can read and write any KMDB database regardless of the application's type model.

## Device Identity

The CLI uses a stable device ID derived from the machine's hostname + a random
UUID suffix stored in `~/.kmdb_device_id`. This ensures CLI writes are
attributable to the correct device in a multi-device sync scenario and don't
collide with the application's own device ID.

## File Locking

KMDB acquires an exclusive `LOCK` file on `open()`. If the application already
has the database open, the CLI will fail to open it with a clear error:

```
Error: database is locked by another process.
       Close the application before using the CLI.
```

This is correct and intentional. A future `--readonly` flag (using a read-only
`StorageAdapter`) is a possible enhancement that would allow inspection without
acquiring the write lock.

## Documentation

- Each command has a `--help` flag that prints a short description, all flags,
  and one usage example.
- A `docs/cli.md` developer guide covers invocation, output modes, the filter
  expression format, and scripting patterns.
- The `README` at `packages/kmdb_cli/` covers installation and quick-start
  examples.

---

# Implementation Order

```
Phase 1
  1. Workspace migration (pubspec, CI, README updates)
  2. Package scaffold (bin/kmdb.dart, CliRunner, database_opener)
  3. Output formatters (json, table, csv, line, ndjson)
  4. Filter parser (JSON → Filter DSL)
  5. Data commands (get, put, delete, scan, count)
  6. Introspection commands (collections, indexes, stats, info)
  7. Import/export commands (export, import, dump, restore)
  8. Maintenance commands (flush, compact, verify)
  9. Script file / stdin pipe support (--read, piped stdin)
 10. Tests + coverage check

Phase 2
 11. tty detection, raw-mode InputReader, Colorizer
 12. SessionState, prompt construction
 13. REPL loop (ReplRunner)
 14. Dot-command registry + all dot-commands
 15. Multi-line input handling
 16. Tab completion (CompletionProvider)
 17. Command history (~/.kmdb_history)
 18. .watch implementation
 19. Tests + coverage check
 20. docs/cli.md
```
