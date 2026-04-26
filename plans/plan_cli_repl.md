# CLI - REPL functionality

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

This plan breaks out the REPL functionality originally raised in
[plan_cli.md](completed/plan_cli.md). That plan included both the batch CLI
(which was completed) and an interactive REPL feature (that this plan
describes).

Since plan_cli.md was written, the CLI has grown substantially beyond the
original scope. The current implementation includes schema management, full-text
and semantic search, vault (content-addressable blob store), sync (push/pull),
secondary index management, and utility/diagnostic commands.

The REPL is scoped as a document-focused interactive tool — for exploring,
querying, and editing the contents of a single database. Diagnostic, setup, and
low-level maintenance commands (`util`, `stats`, `info`, `flush`, `compact`,
`verify`, `init`, `new_device_id`) are intentionally excluded; those remain
batch-only.

### Goals

- A persistent interactive shell for exploring and editing KMDB databases.
- Readline-style input: line editing, command history persisted to
  `~/.kmdb_history`.
- Dot-commands to control session state (output mode, active collection,
  pagination, schema display, etc.).
- Multi-line query support with a continuation prompt.
- Colour-coded output when stdout is a tty.
- Context-aware tab completion (dot-commands, collection names, field names,
  schema subcommands, search subcommands, vault subcommands).

The original detailed specification in [plan_cli.md](completed/plan_cli.md)
(Phase 2 section) remains the primary reference. This document updates that
specification to reflect the current codebase.

---

## Open questions

- [x] **History storage format**: Plain newline-delimited UTF-8 text file
      (`~/.kmdb_history`). Up/down arrows navigate history in-session (via the
      readline-style `InputReader`); the file is loaded on REPL start and written
      on clean exit. No per-database filtering needed.
- [x] **Collection info on switch**: When the user runs `.collection <name>`,
      the REPL prints a brief summary: document count (via `count`) and the name
      of any registered schema (or nothing if none). Example:
      `notes  42 documents  schema: note_v1`
- [x] **Search index awareness in completion**: The completer queries the live
      `FtsManager` (via `CommandContext`) rather than reading `local/config.json`
      directly. This keeps completions in sync with `search create`/`search delete`
      mutations made during the current session.
- [x] **Vault URI completion**: No tab completion for `vault get` — URIs are
      opaque and not worth completing upfront. Revisit if a clear need emerges
      from real REPL usage.
- [x] **Sync commands in REPL**: Show a text spinner (`|/-\` cycling via
      `Timer.periodic`, overwriting with `\r`) while `push`, `pull`, and `sync`
      run. Spinner is suppressed when `stdout.hasTerminal` is false. Implemented
      in `repl/spinner.dart`.
- [x] **`.watch` removed**: KMDB holds an exclusive lock for a single
      process/thread. No other writer can trigger `writeEvents` while the REPL is
      open, so `.watch` has no useful purpose and will not be implemented.

---

## Investigation

### Current CLI structure

All commands share a `CommandContext` (database, config, output/error sinks,
active output mode) and a common `CliCommand` base class with an
`execute(ctx, args, flags)` contract. `CliRunner` performs argument parsing and
dispatch. This is clean foundation for REPL re-use: the REPL loop need only
construct a `CommandContext` once and call `CliRunner.dispatch()` on each input
line.

### Commands available in the REPL (20 commands)

**Data:** `get`, `insert`, `update`, `delete`, `scan`, `count`  
**Collections:** `collections`, `create_collection`  
**Import/export:** `export`, `import`, `dump`, `restore`  
**Schema:** `schema set|show|list|remove|validate`  
**Search:** `search <query>`, `search list|create|delete`  
**Index:** `index list|create|info|delete`  
**Vault:** `vault get`  
**Sync:** `remote add|list|remove`, `push`, `pull`, `sync`

**Excluded (batch-only):** `flush`, `compact`, `verify`, `stats`, `info`,
`util`, `init`, `new_device_id` — these are diagnostic, setup, or low-level
maintenance operations outside the REPL's document-focused scope.

All included commands are available inside the REPL with no extra work — the
existing dispatch layer already handles them.

### Dot-command prefix reservation

`CliRunner` already rejects input starting with `.` in batch mode (lines
379–384 of `cli_runner.dart`). The REPL can intercept dot-prefixed lines before
dispatch, keeping the two paths clean.

### `local/config.json` and per-session state

FTS/vector index definitions are persisted in `local/config.json` and loaded
into `CommandContext` at open time. The REPL does not need to reload this file
between commands unless the user runs `search create|delete` or similar
mutation commands — those already update the in-memory config via
`ctx.config`.

### Schema interaction

`KmdbDatabase.schemaManager` is available on `CommandContext.db`. The REPL
should surface schema state in two places:

1. The `.schema` dot-command (alias for the existing `schema` batch command).
2. Optionally, after `.collection <name>`, if a schema is registered, print a
   brief notice (`Schema: active — use 'schema show <name>' to inspect`).

Schema violations during `insert` / `update` produce `SchemaValidationException`
with structured `SchemaViolation` objects. The REPL should pretty-print these
in colour when on a tty (field name in yellow, message in red) rather than
dumping the raw exception.

### Terminal / tty handling

Dart's `dart:io` provides `stdin.hasTerminal` and supports `RawSynchronousReader`
for raw-mode input. A thin `InputReader` abstraction (with a fake implementation
for tests) should wrap this, consistent with the original plan. ANSI codes must
be suppressed when `stdout.hasTerminal` is false.

### Tab completion

The existing command set is large enough that completion is high value. Proposed
completion tree:

| Cursor position | Completions |
|:---|:---|
| First token, starts with `.` | All dot-command names |
| First token, no `.` | REPL command names (20) |
| After `scan` / `get` / `count` / `delete` / `update` / `create_collection` | Collection names (live from `db.collections()`) |
| After `schema` | `set show list remove validate` |
| After `schema show|remove|validate` | Collection names with registered schemas |
| After `search` | Collection names, then `list create delete` |
| After `search create` | Collection names, then field names |
| After `index` | `list create info delete` |
| After `index create|list|info|delete` | Collection names |
| After `--order-by` | Field names from the active/named collection |
| After `.mode` | `json compact ndjson table csv line` |
| After `.collection` | Collection names |
| After `vault` | `get` |
| After `remote` | `add list remove` |

---

## Implementation plan

### Step 1 — Infrastructure

- [ ] Add `dart_readline` (or equivalent) to `kmdb_cli` pubspec for
      readline-style line editing and history. Evaluate alternatives:
      `dart_readline`, manual raw-mode `stdin` loop, or a pure-Dart
      implementation. Choose based on cross-platform support (macOS, Linux).
- [ ] Create `packages/kmdb_cli/lib/src/repl/input_reader.dart` — abstract
      `InputReader` interface with a tty implementation and a fake implementation
      for tests.
- [ ] Create `repl/colorizer.dart` — ANSI escape helpers; auto-disables when
      `stdout.hasTerminal` is false or `.color off` is set. Used for key/value
      highlighting, error messages, and timing output.
- [ ] Create `repl/spinner.dart` — `Spinner` class using `Timer.periodic` to
      cycle `|/-\` frames on a single line via `\r`. Auto-suppressed when
      `stdout.hasTerminal` is false. Used by `push`, `pull`, and `sync`.
- [ ] Create `repl/prompt.dart` — constructs the prompt string:
      - Default: `kmdb[{dbName}]> `
      - With active collection: `kmdb[{dbName}:{collection}]> `
      - Continuation: `   ...> `

### Step 2 — Session state

- [ ] Create `repl/session_state.dart` — holds all mutable REPL settings:
  - `outputMode` (mirrors batch `--mode`)
  - `activeCollection` (nullable; used as default namespace for applicable commands)
  - `compact` bool
  - `colorEnabled` bool (tri-state: `on | off | auto`)
  - `headers` bool
  - `nullValue` String
  - `defaultLimit` int (0 = no limit)
  - `echo` bool
  - `bail` bool
  - `timer` bool
  - `outputSink` (nullable; set by `.output`)
  - `onceSink` (nullable; consumed after one command, set by `.once`)

### Step 3 — Dot-commands

Create `repl/dot_command.dart` — `DotCommand` interface with `name`, `helpText`,
and `execute(SessionState, CommandContext, List<String> args)`.

Create `repl/dot_commands/` with one file per dot-command:

**Session state:**
- [ ] `.mode <mode>` — set output mode
- [ ] `.output [file]` — redirect output; no args resets to stdout
- [ ] `.once [file]` — redirect next command's output only
- [ ] `.compact on|off`
- [ ] `.color on|off|auto`
- [ ] `.headers on|off`
- [ ] `.nullvalue <str>`
- [ ] `.limit <n>`
- [ ] `.collection [name]` — set active collection (renamed from `.namespace` in
      original plan to match current "collection" terminology)
- [ ] `.echo on|off`
- [ ] `.bail on|off`
- [ ] `.timer on|off`

**Introspection (delegate to existing commands):**
- [ ] `.collections` — alias for `collections` command
- [ ] `.indexes [collection]` — alias for `index list`
- [ ] `.schema [collection]` — alias for `schema show`
- [ ] `.show` — print all current session settings in a compact table
- [ ] `.history [n]` — print last n history entries (default 20)

**I/O and scripting:**
- [ ] `.read <file>` — execute Phase 1 script file
- [ ] `.export <collection> [file]` — alias for `export` command
- [ ] `.import <collection> <file>` — alias for `import` command
- [ ] `.dump [file]` — alias for `dump` command
- [ ] `.restore <file>` — alias for `restore` command

**Database:**
- [ ] `.open <path>` — close current database, open a new one (creates a fresh
      `CommandContext`; session settings are preserved)
- [ ] `.close` — close database; REPL remains open but commands requiring a db
      will error until `.open` is used

**Help and exit:**
- [ ] `.help [command]` — list all dot-commands or show help for one
- [ ] `.quit` / `.exit [code]`

### Step 4 — Command history

- [ ] Create `repl/history.dart`:
  - Read/write `~/.kmdb_history` (UTF-8, one entry per line).
  - Cap at 1,000 entries; trim oldest on overflow.
  - Write on clean exit and on SIGINT.
  - `.history [n]` prints last n entries with 1-based line numbers.
  - `!n` re-executes entry number n.

### Step 5 — Multi-line input

- [ ] Implement continuation detection in `ReplRunner`:
  - A line ending with `\` triggers continuation.
  - If a JSON filter argument has unbalanced `{`, `[`, or `'`, continue
    accumulating until balanced.
  - Prompt switches to `   ...> ` during continuation.

### Step 6 — Tab completion

- [ ] Create `repl/completer.dart` — `CompletionProvider` interface +
      `LiveCompletionProvider` backed by the live database.
- [ ] Implement completion tree as described in the investigation section above.
- [ ] Wire completions into `InputReader`'s tab-key handler.

### Step 7 — REPL loop

- [ ] Create `repl/repl_runner.dart` — the main loop:
  1. Detect tty: `stdin.hasTerminal`. If false and no inline commands given,
     fall through to existing batch stdin behaviour (no change to current path).
  2. Print welcome banner with database name and version.
  3. Loop: read line → handle dot-command or dispatch to `CliRunner` →
     print output → write history entry.
  4. Apply `SessionState` settings to `CommandContext` before each dispatch
     (output mode, active collection as default namespace, output sink).
  5. Handle `SchemaValidationException` with coloured field-level error output.
  6. On `.bail on`, exit on first error; otherwise print error and continue.
  7. Exit cleanly on `.quit`, `.exit`, or Ctrl+D; write history file.

- [ ] Update `bin/kmdb.dart` and `CliRunner` entry point to invoke `ReplRunner`
      when `stdin.hasTerminal` is true and no inline commands are given.

### Step 8 — Tests

- [ ] `test/repl/repl_runner_test.dart` — use fake `InputReader` + `StringBuffer`
      sink for headless REPL testing. Cover:
  - Basic command execution (delegates to existing batch commands)
  - Dot-command parsing and execution
  - Session state mutations visible to subsequent commands
  - Multi-line input with `\` continuation
  - Balanced-brace JSON continuation
  - `!n` history recall
  - `.bail on` exits on error; `.bail off` continues
  - `.open` switches database mid-session
  - `SchemaValidationException` pretty-printing
- [ ] `test/repl/dot_commands/` — one test file per dot-command covering happy
      path and invalid arguments.
- [ ] `test/repl/history_test.dart` — read/write temp file; cap enforcement;
      survives restart.
- [ ] `test/repl/completer_test.dart` — test against known collections and fields
      using `MemoryStorageAdapter`.
- [ ] Maintain ≥ 90% test coverage across the package.

### Step 9 — Documentation

- [ ] Update `packages/kmdb_cli/README.md` with a "REPL / Interactive Mode"
      section covering: how to launch, prompt format, dot-commands reference, tab
      completion, history, and watch mode.
- [ ] Update or create `docs/cli.md` to include interactive mode detail.

---

## Acceptance criteria

- [ ] REPL launches when no inline commands are given and `stdin.hasTerminal` is
      true.
- [ ] All dot-commands implemented with `.help` text.
- [ ] All 20 document-focused commands work unchanged inside the REPL session.
- [ ] `SchemaValidationException` is pretty-printed with field-level detail.
- [ ] Multi-line input with `\` continuation and balanced-brace JSON detection
      works.
- [ ] Tab completion covers commands, collections, subcommand keywords, and
      `--order-by` field names.
- [ ] Command history persisted to `~/.kmdb_history`; survives restart; `!n`
      re-executes.
- [ ] Colour output active on tty; suppressed when piping or stdout is not a tty.
- [ ] `.read <file>` executes Phase 1 script files from inside the REPL.
- [ ] `.open` switches database without restarting the shell.
- [ ] Test coverage ≥ 90%.

---

## Summary

{Dot points highlighting the work undertaken}
