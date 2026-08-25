# Changelog

## 0.1.0

First stable release, published to pub.dev. Targets `kmdb` `^0.1.0`.

The CLI tracks the `kmdb` 0.1.0 API. Notable consequences for command users:

- **Authenticated sync.** Enrolling a device against an existing remote now
  requires the `remote pair` flow — `remote pair show` on an already-enrolled
  device to mint a code, then `remote pair import <remote> <code>` on the
  joining device. An un-enrolled remote raises a sync-auth error on pull.
- Tracks the tightened `insert` / `put` / `replace` write semantics and the
  `PullResult` / `SyncResult` reporting from `kmdb` 0.1.0.

See the `kmdb` `0.1.0` changelog for the full list of underlying changes.

### Requirements

- Dart SDK `^3.13.0`.
