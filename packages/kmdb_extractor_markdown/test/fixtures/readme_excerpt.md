# KMDB

A Local-First Document Database for Dart & Flutter

KMDB is a local-first document database for Dart and Flutter applications
targeting mobile, desktop, and web platforms. It provides a typed, reactive
query API over a key-value storage engine, with multi-device sync via commodity
cloud storage (Google Drive, iCloud) without requiring a central server.

The storage layer is a Log-Structured Merge Tree (LSM) with a write-ahead log
(WAL), in-memory memtable, and immutable Sorted String Table (SSTable) files.
This architecture was chosen specifically because immutable SSTables serve as
the natural sync unit for cloud storage — file creation is atomic in cloud
storage, file mutation is not.
