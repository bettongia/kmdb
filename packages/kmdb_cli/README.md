# kmdb CLI

A command-line interface for [KMDB](../kmdb/) — a local-first document database
for Dart and Flutter.

## Installation

`kmdb_cli` (via `kmdb`) depends on packages with native-asset build hooks
(`betto_onnxrt`, `betto_zstd`, `betto_pdfium`), so `dart compile exe` **does
not work** — it refuses outright with `'dart compile' does not support build
hooks, use 'dart build' instead.` Use `dart build cli` instead, from inside
`packages/kmdb_cli`:

```bash
cd packages/kmdb_cli
dart pub get
dart build cli
```

This produces `build/cli/<platform>/bundle/bin/kmdb` plus a sibling
`bundle/lib/` directory containing the native libraries (`libonnxruntime`,
`libzstd`, `libpdfium`, per-platform extensions). **The unit of distribution
is the whole `bundle/` directory, not the lone binary** — copying only
`bundle/bin/kmdb` away from its sibling `bundle/lib/` breaks native library
loading (`dlopen` failure) at runtime. Copy or archive `bundle/` as a whole
when distributing the CLI.

Or run directly without compiling:

```bash
dart run packages/kmdb_cli/bin/kmdb.dart <database-path> <command>
```

## Invocation

```
kmdb [options] <database-path> <command> [args...]
kmdb [options] <database-path> --read <script-file>
echo "<command>" | kmdb [options] <database-path>
```

The database path is a directory. It is created automatically on first use.

Here's an example

```bash
# Insert a new document (ID is automatically assigned)
dart run bin/kmdb.dart mydb insert notes --value '{"title": "New Note"}'

# Retrieve it by the ID shown in the output
dart run bin/kmdb.dart mydb get notes 019242f4aac07b8fb7e8f1bfb2c3d4e5

# Update a field on an existing document
dart run bin/kmdb.dart mydb update notes 019242f4aac07b8fb7e8f1bfb2c3d4e5 --set '{"title": "Updated Note"}'

dart run bin/kmdb.dart mydb collections

dart run bin/kmdb.dart mydb count notes

dart run bin/kmdb.dart mydb scan notes
```

### Global options

| Flag                  | Short | Description                                        |
| --------------------- | ----- | -------------------------------------------------- |
| `--format <format>`   | `-f`  | Output format (default: `json`)                    |
| `--output <file>`     | `-o`  | Write output to a file instead of stdout           |
| `--read <file>`       | `-r`  | Read commands from a script file                   |
| `--continue-on-error` |       | Keep running after a command error (default: stop) |
| `--flush`             |       | Flush memtable to SSTable on exit (default)        |
| `--no-flush`          |       | Skip flush on exit (data stays in WAL)             |
| `--version`           |       | Print version and exit                             |
| `--help`              | `-h`  | Print help and exit                                |

### Output modes

| Mode      | Description                                               |
| --------- | --------------------------------------------------------- |
| `json`    | Indented JSON array (default)                             |
| `compact` | Single-line JSON array                                    |
| `ndjson`  | One JSON object per line (newline-delimited JSON)         |
| `table`   | Fixed-width ASCII table                                   |
| `csv`     | Comma-separated values with header row                    |
| `line`    | `field = value` pairs, documents separated by blank lines |

## Interactive mode (REPL)

Run `kmdb` with only a database path and no inline command to enter the
interactive shell:

```bash
kmdb mydb
```

```
kmdb 0.1.0  •  mydb
Type .help for dot-commands or .quit to exit.
kmdb[mydb]>
```

The REPL is a document-focused shell for exploring and editing a single
database. All 20 document-focused batch commands work unchanged inside the
session. Diagnostic, maintenance, and setup commands (`flush`, `compact`,
`verify`, `stats`, `info`, `util`, `init`, `new_device_id`) remain batch-only.

### Prompt format

| State | Prompt |
|---|---|
| Default | `kmdb[mydb]> ` |
| Active collection set | `kmdb[mydb:notes]> ` |
| Continuation line | `   ...> ` |

### Line editing

- **Left / Right** — move cursor
- **Ctrl+A / Home** — jump to start of line
- **Ctrl+E / End** — jump to end of line
- **Ctrl+K** — delete to end of line
- **Ctrl+U** — delete to start of line
- **Up / Down** — navigate command history
- **Tab** — context-aware completion
- **Ctrl+C** — cancel current line
- **Ctrl+D** (empty line) — exit

### Tab completion

| Cursor position | Completions offered |
|---|---|
| First token, `.` prefix | Dot-command names |
| First token, no `.` | Command names |
| After `scan`/`get`/`count`/`delete`/`update` | Collection names |
| After `schema` | `set show list remove validate` |
| After `schema show\|remove\|validate` | Collections with registered schemas |
| After `search` | Collection names + `list create delete` |
| After `search create` | Collection names |
| After `index` | `list create info delete` |
| After `index <sub>` | Collection names |
| After `--order-by` | Field names sampled from the collection |
| After `.mode` | Output mode names |
| After `.collection` | Collection names |
| After `vault` | `get` |
| After `remote` | `add list remove` |

### Command history

History is persisted to `~/.kmdb_history` (UTF-8, 1000-entry cap) and loaded
on startup. Use **Up/Down** to navigate previous entries. Use `!n` to
re-execute entry number `n` (`.history` shows the numbered list).

### Multi-line input

A line ending with `\` continues on the next line. A JSON argument with
unbalanced `{` or `[` also triggers continuation until the expression is
balanced — useful for long `--filter` values:

```
kmdb[mydb]> scan notes --filter '{"field":"status",
   ...>   "op":"eq","value":"active"}'
```

### Dot-commands

Dot-commands control the session. They are intercepted before dispatch and
never reach the batch command layer.

#### Session settings

| Command | Description |
|---|---|
| `.mode <mode>` | Set output format: `json` `compact` `ndjson` `table` `csv` `line` |
| `.output [file]` | Redirect all output to a file; no arg resets to stdout |
| `.once [file]` | Redirect only the next command's output to a file |
| `.compact on\|off` | Toggle compact output |
| `.color on\|off\|auto` | Control ANSI colour (default: `auto`) |
| `.headers on\|off` | Show/hide column headers in table/csv mode |
| `.nullvalue <str>` | String to display for null values (default: empty) |
| `.limit <n>` | Default row limit for scan (0 = no limit) |
| `.collection [name]` | Set active collection; no arg clears it |
| `.echo on\|off` | Echo each command before executing |
| `.bail on\|off` | Exit on first error |
| `.timer on\|off` | Print execution time after each command |

#### Introspection

| Command | Description |
|---|---|
| `.collections` | List all collections |
| `.indexes [collection]` | List indexes for a collection |
| `.schema [collection]` | Show schema for a collection |
| `.show` | Print all current session settings |
| `.history [n]` | Print last n history entries (default 20) |

#### I/O and scripting

| Command | Description |
|---|---|
| `.read <file>` | Execute commands from a script file |
| `.export <collection> [file]` | Export collection to NDJSON |
| `.import <collection> <file>` | Import NDJSON into a collection |
| `.dump [file]` | Dump entire database as NDJSON |
| `.restore <file>` | Restore database from a dump |

#### Database

| Command | Description |
|---|---|
| `.open <path>` | Close current database and open a new one |
| `.close` | Close the current database |

#### Help and exit

| Command | Description |
|---|---|
| `.help [command]` | List all dot-commands, or show help for one |
| `.quit` | Exit with code 0 |
| `.exit [code]` | Exit with the given code (default 0) |

### Schema validation errors

When an `insert` or `update` violates a registered collection schema, the REPL
pretty-prints the error with per-field colour highlighting (field names in
yellow, messages in red) rather than dumping the raw exception.

### Sync commands

`push`, `pull`, and `sync` show an animated spinner while running. The spinner
is suppressed when stdout is not a terminal.

---

## Commands

### Data commands

#### `get <collection> <key>`

Retrieve a single document by its key.

```bash
kmdb mydb get notes 019242f4aac07b8fb7e8f1bfb2c3d4e5
```

#### `insert <collection> [--value <json>] [--file <path>]`

Insert one or more new documents. A new system-generated UUIDv7 identifier is
automatically assigned to each document's `_id` field. Any `_id` supplied by the
caller is replaced.

Input is read from `--value` (inline JSON), `--file` (path to a JSON or NDJSON
file), or stdin (auto-detected as JSON or NDJSON).

| Flag            | Description                                                         |
| --------------- | ------------------------------------------------------------------- |
| `--value <json>`| Inline JSON object or array                                         |
| `--file <path>` | File path; `.ndjson`/`.jsonl` files are parsed as NDJSON, others as JSON |

```bash
# Single document
kmdb mydb insert notes --value '{"title":"Hello"}'

# Multiple documents from a JSON array
kmdb mydb insert notes --value '[{"title":"Hello"},{"title":"World"}]'

# From an NDJSON file
kmdb mydb insert notes --file docs.ndjson

# From stdin
echo '{"title":"Hello"}' | kmdb mydb insert notes
```

#### `update <collection> [<id> | --id <ids> | --filter <json> | --all] --set <json>`

Partially update one or more documents using a shallow merge. The fields in
`--set` are merged into the top-level of each matching document. Nested objects
are replaced wholesale. The `_id` field is always preserved and cannot be
overwritten.

Exactly one targeting mode is required. The modes are mutually exclusive.

| Targeting mode           | Description                                      |
| ------------------------ | ------------------------------------------------ |
| Positional `<id>`        | Update a single document by key                  |
| `--id <id1,id2,...>`     | Update a comma-separated list of documents by key |
| `--filter <json>`        | Update all documents matching the filter         |
| `--all`                  | Update every document in the collection          |

The `--set` flag is always required and must be a JSON object (not an array or
scalar).

Reports `{"updated": N}` on success.

```bash
# Update a single document by ID
kmdb mydb update notes 019242f4aac07b8fb7e8f1bfb2c3d4e5 --set '{"status":"done"}'

# Update multiple specific IDs
kmdb mydb update notes --id 019abc...,019def... --set '{"archived":true}'

# Update all documents matching a filter
kmdb mydb update notes \
  --filter '{"field":"status","op":"eq","value":"active"}' \
  --set '{"flagged":true}'

# Update every document in the collection
kmdb mydb update notes --all --set '{"migrated":true}'
```

> **Note:** `update` operates at the KvStore layer and does not update
> secondary indexes defined via `KmdbDatabase.collection`. Indexes will be
> stale until the next Query Layer write or index rebuild. Each document write
> is independent — there is no atomicity guarantee across multiple documents.

#### `put <collection> [--value <json>] [--file <path>]` *(deprecated)*

> **Deprecated** — use `insert` instead.
>
> `put` is a deprecated alias for `insert`. It still works but prints a
> deprecation warning to stderr. Update any scripts to use `insert`.

```bash
# This still works but emits a warning:
kmdb mydb put notes --value '{"title":"Hello"}'
# Warning: `put` is deprecated, use `insert` instead.
```

#### `delete <collection> <key>`

Delete a document by key (idempotent — succeeds even if the key does not exist).

```bash
kmdb mydb delete notes 019242f4aac07b8fb7e8f1bfb2c3d4e5
```

#### `scan <collection> [options]`

Scan all documents in a collection with optional filtering, ordering, and
pagination.

| Flag                 | Description                                      |
| -------------------- | ------------------------------------------------ |
| `--filter <json>`    | JSON filter expression (see [Filters](#filters)) |
| `--order-by <field>` | Sort by field (string or numeric comparison)     |
| `--desc`             | Reverse sort order                               |
| `--limit <n>`        | Return at most n documents                       |
| `--offset <n>`       | Skip the first n documents                       |
| `--key-prefix <str>` | Restrict scan to keys beginning with this prefix |

```bash
# All documents
kmdb mydb scan notes

# Active notes, most recent first, page 2
kmdb mydb scan notes \
  --filter '{"field":"status","op":"eq","value":"active"}' \
  --order-by updatedAt --desc --limit 20 --offset 20
```

#### `count <collection> [--filter <json>]`

Count documents in a collection, optionally filtered.

```bash
kmdb mydb count notes
kmdb mydb count notes --filter '{"field":"status","op":"eq","value":"active"}'
```

---

### Introspection commands

#### `collections`

List all user-visible collections in the database.

```bash
kmdb mydb collections
```

#### `stats`

Show storage statistics: SSTable counts per level and byte totals.

```bash
kmdb mydb stats
```

#### `info`

Show database identity: directory path, device ID, and current HLC timestamp.

```bash
kmdb mydb info
```

---

### Import / Export commands

#### `export <collection> [--output <file>]`

Export a collection to newline-delimited JSON (NDJSON). Writes to stdout if
`--output` is omitted.

```bash
kmdb mydb export notes --output notes.ndjson
```

#### `import <collection> [options]`

Import NDJSON documents into a collection. Each line must be a JSON object with
a string `id` field. Reads from stdin if `--input` is omitted.

| Flag                   | Description                               |
| ---------------------- | ----------------------------------------- |
| `--input <file>`       | Read from a file instead of stdin         |
| `--on-conflict <mode>` | `replace` (default), `ignore`, or `error` |

```bash
kmdb mydb import notes --input notes.ndjson
kmdb mydb import notes --input notes.ndjson --on-conflict ignore
```

#### `dump [--output <file>]`

Dump the entire database (all collections) as NDJSON with collection header
comments. Writes to stdout if `--output` is omitted. The output is compatible
with `restore`.

```bash
kmdb mydb dump --output backup.ndjson
```

#### `restore [--input <file>]`

Restore the entire database from a dump file produced by `dump`. Reads from
stdin if `--input` is omitted.

```bash
kmdb mydb restore --input backup.ndjson
```

---

### Maintenance commands

#### `flush`

Force the current in-memory memtable to flush to an SSTable on disk.

```bash
kmdb mydb flush
```

#### `compact`

Run full compaction — merges SSTables across all levels until stable.

```bash
kmdb mydb compact
```

#### `verify`

Scan all documents in all collections and attempt to decode each one. Reports
any documents that cannot be decoded (corrupt values).

```bash
kmdb mydb verify
```

---

### Diagnostics commands

The `util` subcommands inspect raw storage-engine files without acquiring the
database lock, so they are safe to run against a live database. They are
**read-only** — they never write to or flush the database.

#### `util sstable <filename> [--full] [--full --data]`

Inspect a single SSTable file. The filename is resolved relative to the `sst/`
subdirectory of the database directory.

| Flag     | Description                                                     |
| -------- | --------------------------------------------------------------- |
| _(none)_ | Summary: footer fields, Bloom filter stats, index entry count   |
| `--full` | Adds index block references and all key/value entries           |
| `--data` | Requires `--full`. Decodes user-collection entry values as JSON |

```bash
# Summary
kmdb mydb util sstable abc123-....sst

# Full record-level output
kmdb mydb util sstable abc123-....sst --full

# Full output with decoded document values
kmdb mydb util sstable abc123-....sst --full --data
```

System-collection entries (`$meta`, `$cache`, `$index:*`) use internal binary
encodings and are not decoded even with `--data`.

#### `util wal <filename> [--full] [--full --data]`

Inspect a single WAL file. The filename is resolved relative to the database
directory (e.g. `wal-00001.log`).

| Flag     | Description                                                            |
| -------- | ---------------------------------------------------------------------- |
| _(none)_ | Summary: record count, HLC range, distinct collections                 |
| `--full` | Every record with type, sequence, collection, key, and value metadata  |
| `--data` | Requires `--full`. Decodes user-collection `put` record values as JSON |

```bash
# Summary
kmdb mydb util wal wal-00001.log

# Full record listing
kmdb mydb util wal wal-00001.log --full

# Full listing with decoded document values
kmdb mydb util wal wal-00001.log --full --data
```

System-collection records (`$meta`, `$cache`, `$index:*`) use internal binary
encodings and are not decoded even with `--data`.

#### `util manifest [--full]`

Inspect the active Manifest file. Resolves it automatically from the `CURRENT`
pointer in the database directory.

| Flag     | Description                                                     |
| -------- | --------------------------------------------------------------- |
| _(none)_ | Current level state: each level mapped to its SSTable filenames |
| `--full` | Complete `VersionEdit` history with all added/removed entries   |

```bash
# Current level state
kmdb mydb util manifest

# Full VersionEdit history
kmdb mydb util manifest --full
```

---

## Filters

The `--filter` flag accepts a JSON filter expression. Filters can be simple
field comparisons or logical combinations of multiple conditions.

### Field comparisons

```json
{"field": "status",    "op": "eq",      "value": "active"}
{"field": "score",     "op": "gt",      "value": 10}
{"field": "score",     "op": "between", "value": [1, 100]}
{"field": "tags",      "op": "in",      "value": ["dart", "flutter"]}
{"field": "deletedAt", "op": "isNull"}
```

| Operator      | Description                                    |
| ------------- | ---------------------------------------------- |
| `eq`          | Equal to value                                 |
| `ne`          | Not equal to value                             |
| `lt`          | Less than value                                |
| `lte`         | Less than or equal to value                    |
| `gt`          | Greater than value                             |
| `gte`         | Greater than or equal to value                 |
| `between`     | Inclusive range — value must be `[min, max]`   |
| `in`          | Field value is one of the listed values        |
| `notIn`       | Field value is not in the listed values        |
| `isNull`      | Field is absent or null                        |
| `isNotNull`   | Field is present and non-null                  |
| `isTrue`      | Field is boolean `true`                        |
| `isFalse`     | Field is boolean `false`                       |
| `startsWith`  | String field starts with value                 |
| `endsWith`    | String field ends with value                   |
| `contains`    | String field contains value as a substring     |
| `containsAll` | Array field contains all listed values         |
| `containsAny` | Array field contains at least one listed value |

### Nested field paths

Use dot notation to reach into nested objects:

```json
{ "field": "address.city", "op": "eq", "value": "London" }
```

### Logical combinators

```json
{"and": [
  {"field": "status", "op": "eq",  "value": "active"},
  {"field": "score",  "op": "gte", "value": 50}
]}

{"or": [
  {"field": "priority", "op": "eq", "value": "high"},
  {"field": "due",      "op": "lt", "value": "2026-04-01"}
]}

{"not": {"field": "archived", "op": "isTrue"}}
```

Combinators can be nested to any depth.

---

## Script files

Use `--read` to execute a series of commands from a file. Each line is a command
exactly as you would type it on the terminal. Lines beginning with `#` are
treated as comments and ignored.

```
# migrations/001.kmdb
# Seed initial categories

insert categories --value '{"name":"Work"}'
insert categories --value '{"name":"Personal"}'
```

```bash
kmdb mydb --read migrations/001.kmdb
```

By default execution stops on the first error. Pass `--continue-on-error` to
process all lines regardless.

---

## Scripting and pipelines

`kmdb` is designed to compose well with standard Unix tools.

```bash
# Count active documents across two databases
for db in shard1 shard2; do
  kmdb "$db" count tasks --filter '{"field":"status","op":"eq","value":"active"}'
done

# Export, transform with jq, and re-import
kmdb mydb export notes --format ndjson \
  | jq -c '. + {"migrated": true}' \
  | kmdb mydb import notes_v2

# Backup all databases to timestamped files
for db in *; do
  kmdb "$db" dump --output "backups/$(basename "$db" )-$(date +%Y%m%d).ndjson"
done
```

---

## Exit codes

| Code | Meaning                                               |
| ---- | ----------------------------------------------------- |
| `0`  | All commands succeeded                                |
| `1`  | One or more commands failed (error written to stderr) |
