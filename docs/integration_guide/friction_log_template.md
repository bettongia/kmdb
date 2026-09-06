---
title: Integration Guide Friction Log
subtitle: Template — copy this file, do not edit it in place
toc-title: "Contents"
...

# How to use this template

This is a **blank template**. Do not fill it in here — copy it to
`docs/integration_guide/friction_logs/YYYY-MM-DD_your-description.md` and fill
in the copy as you follow the [Integration Guide](README.md). Record **every**
place the guide fails you, however small — a friction log with zero entries
usually means friction wasn't captured, not that there wasn't any.

This template exists for two audiences: the cold-read validation run that is
this guide's own acceptance gate (see the plan's "Guide-validation additions"
section), and any real user who hits a rough edge and wants to report it. Both
use the same format.

# Run header

Fill this in once per copy, before you start.

| Field | Value |
| :---- | :---- |
| Guide version / commit | |
| Date | |
| Tester identity (human, or agent type/model) | |
| Overall outcome (did a working app build end-to-end?) | |

# Friction entries

Copy the table row template below once per friction point. Every column is
required — if a column genuinely doesn't apply, write "n/a" rather than
leaving it blank, so a missing entry can't be mistaken for an omission.

| Guide section / step reference | What the guide said to do | What actually happened | Severity | Self-resolvable? (yes/no, how) | Time lost | Suspected root cause | Suggested guide fix | Environment |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| | | | | | | | | |

## Column reference

- **Guide section / step reference** — which heading or numbered step in
  [README.md](README.md) this entry is about.
- **What the guide said to do** — the instruction as written, quoted or
  closely paraphrased.
- **What actually happened** — the observed behaviour, error message, or gap.
  Be specific: exact error text, not "it didn't work."
- **Severity** — one of:
  - `blocker` — could not proceed without outside help or guesswork.
  - `major` — proceeded, but only by doing something wrong or by unusual
    effort.
  - `minor` — cosmetic, a nit, or a small inefficiency that didn't block
    progress.
- **Self-resolvable?** — `yes` or `no`, and if `yes`, *how*: what did you have
  to figure out, and from where? (A real user only has the guide and `kmdb`'s
  public API/doc comments — note if you had to go beyond that, e.g. reading
  `kmdb`'s internal source, the spec, or asking someone.)
- **Time lost** — a rough estimate in minutes.
- **Suspected root cause** — your best guess: wrong instruction, a missing
  step, a stale API reference, an unstated prerequisite, an environment
  mismatch, etc.
- **Suggested guide fix** — the concrete edit you would make to the guide.
- **Environment** — OS (macOS/Linux/Windows + version), Flutter version, Dart
  version, and whether `kmdb` was consumed via a path dependency or from
  pub.dev.
