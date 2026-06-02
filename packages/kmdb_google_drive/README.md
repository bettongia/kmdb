# kmdb_google_drive

Google Drive sync adapter for [KMDB](https://github.com/bettongia/kmdb) — a
`SyncStorageAdapter` implementation that backs the KMDB sync protocol against
the Google Drive REST API (Drive v3).

---

## Overview

`package:kmdb_google_drive` provides `GoogleDriveAdapter`, which implements
`SyncStorageAdapter` from `package:kmdb`.  Drop it in wherever KMDB expects a
sync backend:

```dart
await db.sync(syncAdapter: adapter);
```

The adapter is native-only (uses `dart:io`).  Flutter web callers should use
`package:google_sign_in` to obtain an `AuthClient` and pass it directly to the
adapter constructor.

---

## Authentication

The adapter is **auth-agnostic**: it accepts any `AuthClient` from
`package:googleapis_auth`.  Two ready-made helpers are provided via
`GoogleDriveAuthHelper`:

### 1. User consent (CLI / desktop)

Runs a local-server OAuth 2.0 redirect flow, opens the user's browser, and
persists the resulting credentials to disk for automatic reuse:

```dart
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:kmdb_google_drive/kmdb_google_drive.dart';

final authClient = await GoogleDriveAuthHelper.fromUserConsent(
  ClientId('YOUR_CLIENT_ID.apps.googleusercontent.com', 'YOUR_CLIENT_SECRET'),
  credentialsCachePath: '/home/user/.config/myapp/drive_credentials.json',
);
```

Credentials are cached at `credentialsCachePath`.  On subsequent calls the
cached credentials are loaded and refreshed automatically; the user does not
need to re-authorise.

### 2. Service account (server / automated testing)

```dart
import 'dart:io';
import 'package:kmdb_google_drive/kmdb_google_drive.dart';

final authClient = await GoogleDriveAuthHelper.fromServiceAccount(
  File('service_account.json').readAsStringSync(),
);
```

### 3. Bring your own `AuthClient`

Pass any `AuthClient` directly to the adapter — useful for custom flows such as
Flutter `google_sign_in`:

```dart
final adapter = GoogleDriveAdapter(myAuthClient, syncRoot: 'myapp-kmdb-sync');
```

---

## Drive folder layout

All KMDB sync files live under a single top-level Drive folder (the `syncRoot`
parameter).  The structure mirrors the standard KMDB sync layout:

```
{syncRoot}/
  highwater/
    {deviceId}.hwm         ← per-device high-water mark
  sstables/
    {deviceId}-{minHlc}-{maxHlc}.sst          ← regular flush
    {deviceId}-{epoch}-{minHlc}-{maxHlc}.sst  ← consolidation output
  .consolidation-lease     ← coordinator lock
```

The adapter creates the folder hierarchy lazily on first use.

---

## `providesAtomicCas == false` — what it means

Drive does not guarantee that **create-if-absent** is exclusive: if two devices
simultaneously create a file with the same name in the same folder, both
operations succeed, producing two distinct Drive files.

The adapter declares `providesAtomicCas = false` to signal this limitation.
As a result, `ConsolidationCoordinator` **skips consolidation** when this
adapter is in use (H5 invariant).  This is the correct loss-free posture:
consolidation is simply not attempted rather than risked.

**Update-if-match** (where `ifMatchEtag != null`) **is** atomic: the adapter
sends a raw HTTP `PATCH` with an `If-Match` header, and Drive returns
`412 Precondition Failed` if the ETag has changed — exactly one writer wins.

---

## Minimal usage snippet

```dart
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_google_drive/kmdb_google_drive.dart';

Future<void> syncWithDrive({
  required KmdbDatabase db,
  required ClientId clientId,
  required String credentialsCache,
}) async {
  final authClient = await GoogleDriveAuthHelper.fromUserConsent(
    clientId,
    credentialsCachePath: credentialsCache,
  );

  final adapter = GoogleDriveAdapter(
    authClient,
    syncRoot: 'myapp-kmdb-sync', // Drive folder name
  );

  await db.sync(syncAdapter: adapter);

  authClient.close();
}
```

---

## Rate limiting and retries

The adapter automatically retries on `429 Rate Limited` and `503 Service
Unavailable` responses with exponential back-off and random jitter (following
Google's recommended strategy).  The default configuration allows up to 5
attempts with a 1 s initial delay and a 32 s cap.

Back-off respects `SyncContext` cancellation: if the sync is cancelled, the
back-off sleep wakes immediately rather than waiting for the full delay.

---

## CLI integration

When using the `kmdb` CLI, add a Google Drive remote with:

```bash
kmdb <db> remote add origin \
  --type google-drive \
  --folder myapp-kmdb-sync \
  --client-id YOUR_CLIENT_ID.apps.googleusercontent.com \
  --client-secret YOUR_CLIENT_SECRET
```

The CLI runs the OAuth consent flow automatically, persists the credentials to
`{dbDir}/local/google_credentials.json`, and stores the remote configuration
in `{dbDir}/local/config.json`.

**Note:** The credentials file is stored in the `local/` subdirectory of the
database directory, which is never uploaded to Drive and never read by the sync
engine.

---

## License

Apache 2.0 — see the root [LICENSE](../../LICENSE) file.
