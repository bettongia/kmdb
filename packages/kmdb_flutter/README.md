# kmdb_flutter

Flutter add-on for [KMDB](https://github.com/bettongia/kmdb) — the pieces that
need the Flutter SDK and so cannot live in the pure-Dart `kmdb` package.

**Platform:** Flutter hosts. Optional and opt-in — `kmdb` itself works without
it; this package adds native crypto acceleration and biometric-gated unlock on
top.

---

## Overview

`package:kmdb_flutter` provides two things:

1. **`KmdbFlutter.initialize()`** — registers `cryptography_flutter` as the
   active cryptography implementation, enabling hardware-accelerated
   AES-256-GCM and Argon2id on iOS and Android. Call it once in `main()`,
   after `WidgetsFlutterBinding.ensureInitialized()` and before `runApp()`, so
   the acceleration covers every operation including an encrypted database open
   during startup. Safe to call more than once.

2. **`FlutterBiometricKekProvider`** — a native `BiometricKekProvider` for the
   unlock-policy wrapped-DEK model. It backs biometric-gated unlock with
   `flutter_secure_storage`, defaulting to biometry-current-set access control
   on iOS/macOS and strong-biometric enforcement on Android. There is no
   persistent DEK session cache in this package (or in `kmdb` core): every
   unlock — passphrase, recovery code, or biometric — is an authenticated
   unwrap.

---

## Installation

```yaml
dependencies:
  kmdb: ^0.1.0
  kmdb_flutter: ^0.1.0
```

---

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_flutter/kmdb_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  KmdbFlutter.initialize(); // enable native crypto acceleration

  final db = await KmdbDatabase.open(
    path: dbPath,
    adapter: adapter,
    encryptionConfig: EncryptionConfig(passphrase: 'my-passphrase'),
  );

  // Optionally enrol biometric unlock (native platforms only):
  await db.enableBiometricUnlock(
    FlutterBiometricKekProvider(dbDir: dbPath),
  );

  runApp(MyApp(db: db));
}
```

`FlutterBiometricKekProvider` is secure-by-default; pass
`iosOptions` / `macosOptions` / `androidOptions` only to customise the prompt
or access-control behaviour. `dbDir` must be the same path given to
`KmdbDatabase.open(path:)` so distinct databases on one device never collide.

See the [encryption spec](../../docs/spec/31_encryption.md) for the key model
and bootstrap sequence.

---

## License

Apache 2.0 — see the root [LICENSE](../../LICENSE) file.
