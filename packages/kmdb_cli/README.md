# kmdb CLI

A command-line interface for [KMDB](../kmdb/) — a local-first document database
for Dart and Flutter.

## Installation

From the workspace root:

```bash
dart pub get
dart compile exe packages/kmdb_cli/bin/kmdb.dart -o kmdb
```

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
dart run bin/kmdb.dart mydb put notes --value '{"title": "New Note"}'

# Retrieve it by the ID shown in the output
dart run bin/kmdb.dart mydb get notes 019242f4aac07b8fb7e8f1bfb2c3d4e5

dart run bin/kmdb.dart mydb collections

dart run bin/kmdb.dart mydb count notes

dart run bin/kmdb.dart mydb scan notes
```

### Global options

| Flag                  | Short | Description                                        |
| --------------------- | ----- | -------------------------------------------------- |
| `--mode <mode>`       | `-m`  | Output format (default: `json`)                    |
| `--output <file>`     | `-o`  | Write output to a file instead of stdout           |
| `--read <file>`       | `-r`  | Read commands from a script file                   |
| `--continue-on-error` |       | Keep running after a command error (default: stop) |
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

## Commands

### Data commands

#### `get <namespace> <key>`

Retrieve a single document by its key.

```bash
kmdb mydb get notes 019242f4aac07b8fb7e8f1bfb2c3d4e5
```

#### `put <namespace> [--value <json>]`

Insert a new document. A new system-generated UUIDv7 identifier is automatically
assigned to the document's `id` field. To update an existing document, use the
`import` command or the typed API.

The JSON document is read from `--value` (inline) or from stdin.

```bash
kmdb mydb put notes --value '{"title":"Hello"}'

# From stdin
echo '{"title":"Hello"}' | kmdb mydb put notes
```

#### `delete <namespace> <key>`

Delete a document by key (idempotent — succeeds even if the key does not exist).

```bash
kmdb mydb delete notes 019242f4aac07b8fb7e8f1bfb2c3d4e5
```

#### `scan <namespace> [options]`

Scan all documents in a namespace with optional filtering, ordering, and
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

#### `count <namespace> [--filter <json>]`

Count documents in a namespace, optionally filtered.

```bash
kmdb mydb count notes
kmdb mydb count notes --filter '{"field":"status","op":"eq","value":"active"}'
```

---

### Introspection commands

#### `collections`

List all user-visible namespaces (collections) in the database.

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

#### `export <namespace> [--output <file>]`

Export a namespace to newline-delimited JSON (NDJSON). Writes to stdout if
`--output` is omitted.

```bash
kmdb mydb export notes --output notes.ndjson
```

#### `import <namespace> [options]`

Import NDJSON documents into a namespace. Each line must be a JSON object with a
string `id` field. Reads from stdin if `--input` is omitted.

| Flag                   | Description                               |
| ---------------------- | ----------------------------------------- |
| `--input <file>`       | Read from a file instead of stdin         |
| `--on-conflict <mode>` | `replace` (default), `ignore`, or `error` |

```bash
kmdb mydb import notes --input notes.ndjson
kmdb mydb import notes --input notes.ndjson --on-conflict ignore
```

#### `dump [--output <file>]`

Dump the entire database (all namespaces) as NDJSON with namespace header
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

Scan all documents in all namespaces and attempt to decode each one. Reports any
documents that cannot be decoded (corrupt values).

```bash
kmdb mydb verify
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

put categories --value '{"name":"Work"}'
put categories --value '{"name":"Personal"}'
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
kmdb mydb export notes --mode ndjson \
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
