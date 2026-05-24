# Per-user KMDB configuration directory

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

See also:

- [plan_repl_issues.md](plan_repl_issues.md)
- [plan_cli_repl.md](completed/plan_cli_repl.md)

## Problem statement

The KMDB CLI and REPL currently have no dedicated per-user configuration
directory. Session history is written to `~/.kmdb_history` (a flat file next to
the home directory), and there is nowhere to write session logs or capture crash
diagnostics for later debugging.

A per-user configuration directory — placed at the OS-conventional location —
would provide a structured home for:

- **Command history** (migrate from `~/.kmdb_history`).
- **Session logs** — a rolling log of CLI and REPL commands, outputs, and
  timestamps that persists across invocations.
- **Crash/error capture** — when the REPL or CLI encounters an unhandled
  exception, write the full stack trace to a dated file in the config directory
  rather than (or in addition to) printing it to stderr. This aids debugging
  without alarming end-users with raw stack traces in their terminal.

The target OS-conventional paths are:

| Platform | Path |
|----------|------|
| macOS    | `~/Library/Application Support/kmdb/` |
| Linux    | `$XDG_CONFIG_HOME/kmdb/` (fallback: `~/.config/kmdb/`) |
| Windows  | `%APPDATA%\kmdb\` |

The CLI and REPL target technical desktop users (skill level: shell, psql,
sqlite3). The directory must be created lazily on first use, and any failure to
create or write to it must degrade gracefully — the CLI should never fail to
start because the config directory is unavailable (e.g. due to OS-level
permissions).

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
