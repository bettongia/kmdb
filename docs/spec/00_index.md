---
title: KMDB Design and Specification
subtitle: A Local-First Document Database for Dart & Flutter
toc-title: "Contents"
abstract: |
  This document consolidates the full KMDB design: storage engine (LSM-based KV store),
  query API, sync protocol, platform adaptation layer, and text search (lexical, semantic,
  and hybrid). It supersedes all previous separate design documents and incorporates
  findings from a comprehensive architectural review. Major revisions in v2.0: Revised
  scale targets (100K–500K documents), updated sync protocol with per-device WAL and
  SSTable-based primary sync, per-device high-water mark files, Dart platform modernisation
  (dart:js_interop, build hooks, WASM), and specific technical recommendations (XXH64
  checksums, Zstd dictionary compression, Xor filters). v2.1 adds §20–23: text search
  (BM25 inverted index, BGE embedding model, Reciprocal Rank Fusion). v2.2 adds §24:
  vault — content-addressable binary object store with deduplication, stub-based sync,
  on-demand hydration, and GC via reference counting.
...
---
