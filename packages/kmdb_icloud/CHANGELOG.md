# Changelog

## 0.1.0

First stable release. Targets `kmdb` `^0.1.0`. Hand-published (see
`docs/releasing/0.1.0.md`).

Apple iCloud (CloudKit) `SyncStorageAdapter` for KMDB, connecting the adapter
interface to CloudKit via a Flutter MethodChannel plugin (iOS and macOS only).
Carries the authenticated sync-artefact format introduced in `kmdb` 0.1.0. See
`docs/spec/30_icloud_adapter.md` for the zone model, ETag/CAS semantics, and
developer setup.

### Requirements

- Dart SDK `^3.13.0`, Flutter `>=3.29.0`. iOS / macOS only.
