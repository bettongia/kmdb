---
title: KMDB Design and Specification
subtitle: A Local-First Document Database for Dart & Flutter
toc-title: "Contents"
abstract: |
  This document consolidates the full KMDB design: storage engine (LSM-based KV store),
  query API, sync protocol, and platform adaptation layer. It supersedes all previous
  separate design documents and incorporates findings from a comprehensive architectural
  review. Major revisions in v2.0: Revised scale targets (100K–500K documents), updated sync
  protocol with per-device WAL and SSTable-based primary sync, per-device high-water mark
  files, Dart platform modernisation (dart:js_interop, build hooks, WASM), and specific
  technical recommendations (XXH64 checksums, Zstd dictionary compression, Xor filters).
...
---
