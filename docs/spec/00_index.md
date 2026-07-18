---
title: KMDB Design and Specification
subtitle: A Local-First Document Database for Dart & Flutter
toc-title: "Contents"
abstract: |
  This document consolidates the full KMDB design: storage engine (LSM-based KV store),
  query API, sync protocol, platform adaptation layer, and text search (lexical, semantic,
  and hybrid). It supersedes all previous separate design documents and incorporates
  findings from a comprehensive architectural review. Major revisions in v2.0: Revised
  scale targets (100,000 documents upper bound — see §2 for the full workload
  profile), updated sync protocol with per-device WAL and SSTable-based primary
  sync, per-device high-water mark files, Dart platform modernisation
  (dart:js_interop, build hooks, WASM), and specific technical recommendations (XXH64
  checksums, Zstd dictionary compression, Xor filters). v2.1 adds §20–23: text search
  (BM25 inverted index, BGE embedding model, Reciprocal Rank Fusion). v2.2 adds §24:
  vault — content-addressable binary object store with deduplication, stub-based sync,
  on-demand hydration, and GC via reference counting. v2.3 adds §25 (collection
  schemas — a JSON Schema admission gate for collection writes), §27 (the
  multi-device sync test harness), and §28 (the release checklist cataloguing
  manual / out-of-band tests that the automated suite cannot cover). v2.4 adds
  §26 (document versioning — a full audit trail of prior writes with promote
  support), §29–30 (Google Drive and Apple iCloud cloud adapters), §31
  (value-level AES-256-GCM encryption), §32 (vault search — extracted-text
  indexing over attached files), and §33 (CLI credential store hardening). §1
  is now a System Overview, absorbing the former standalone primer.
...

## Contents by Part

Spec sections keep their original numbers as they were added (see each
file's own history); the groupings below are a reading order, not a
renumbering.

- **Part 0 — Orientation:** §1 System Overview, §2 Target Workload Profile,
  §3 Architecture Overview
- **Part 1 — Storage engine:** §4–§11
- **Part 2 — Sync & consistency:** §12, §17, §18
- **Part 3 — Query, cache & reactivity:** §13, §14, §15, §16
- **Part 4 — Platform:** §19
- **Part 5 — Text search:** §20–§23
- **Part 6 — Content, schema & versioning:** §24, §25, §26, §32
- **Part 7 — Security:** §31, §33
- **Part 8 — Cloud adapters:** §29, §30
- **Part 9 — Testing & release:** §27, §28
- **Part 10 — Reference:** §99 Glossary

## Subsystem Status

A quick cross-check between what's specified and what's actually built —
see [`CLAUDE.md`](../../CLAUDE.md)'s Implementation Status table for the
authoritative, actively-maintained version of this list.

| Subsystem | Spec section(s) | Status |
| :-------- | :--------------- | :----- |
| Primitives & platform layer | §4, §19 | Implemented |
| Storage engine (WAL, memtable, SSTable, compaction) | §6–§9 | Implemented |
| LSM orchestration & crash recovery | §10, §17, §18 | Implemented |
| Value encoding | §5 | Implemented |
| Sync protocol | §12 | Implemented |
| Cache layer | §15 | Implemented |
| Query API, reactivity & secondary indexes | §13, §14, §16 | Implemented |
| Lexical / semantic / hybrid search | §21, §22, §23 | Implemented |
| Vault | §24 | Implemented |
| Collection schemas | §25 | Implemented |
| Document versioning | §26 | Implemented |
| Google Drive adapter | §29 | Implemented |
| iCloud adapter | §30 | Implemented |
| Encryption | §31 | Implemented |
| Vault search | §32 | Implemented |
| CLI credential store | §33 | Implemented |
| Test harness | §27 | Implemented |
| Release checklist | §28 | Living document — updated per release |
