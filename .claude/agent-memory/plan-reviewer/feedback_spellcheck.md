---
name: IDE spell-checker false positives on technical terms
description: Spell-check warnings on kmdb, SSTable, CBOR, etc. in plan/doc files are informational only — no action needed
type: feedback
---

IDE diagnostics flagging `kmdb`, `SSTable`, `Sstable`, `CBOR`, `underspecified`,
and similar technical terms as "Unknown word" in Markdown files are false
positives from the spell checker.

**Why:** These are established project-specific and domain terms used consistently
throughout the codebase and documentation.

**How to apply:** When PostToolUse diagnostics appear after editing a plan or doc
file and all messages are spell-check "Unknown word" warnings at severity
"Information", no changes are needed. Do not attempt to reword technical terms
to satisfy the spell checker.
