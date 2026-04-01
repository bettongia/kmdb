# CLI - REPL functionality

**Status**: Open

**PR link**: {A link to the PR submitted for this plan}

## Problem statement

This plan breaks out the REPL functionality originally raised in
[plan_cli.md](completed/plan_cli.md). That plan included both the batch CLI
(which was completed) and an interactive REPL feature (that this plan
describes).

These are the goals for the interactive REPL:

- A persistent interactive shell for exploring and editing KMDB databases.
- Readline-style input: line editing, command history persisted to
  `~/.kmdb_history`.
- Dot-commands to control session state (output mode, active namespace,
  pagination, etc.).
- Multi-line query support with a continuation prompt.
- A `watch` mode that re-runs a query on every database change.
- Colour-coded output when stdout is a tty.
- Context-aware tab completion (dot-commands, namespace names, field names).

Refer to the "Phase 2: Interactive REPL" section of
[plan_cli.md](completed/plan_cli.md) for a complete specification.

## Open questions

{A checklist of open questions, mark each one off as they are answered}

## Investigation

{Investigation notes}

## Implementation plan

{Checklists and notes for the implementation work}

## Summary

{Dot points highlighting the work undertaken}
