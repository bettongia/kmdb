# Changelog

## 0.1.0

First stable release. Targets `kmdb` `^0.1.0`. Hand-published (see
`docs/releasing/0.1.0.md`).

Flutter add-on for KMDB:

- `KmdbFlutter.initialize()` — registers `cryptography_flutter` to enable
  hardware-accelerated AES-256-GCM and Argon2id on iOS and Android.
- `FlutterBiometricKekProvider` — a native `BiometricKekProvider` for
  biometric-gated unlock, backed by `flutter_secure_storage`.

### Requirements

- Dart SDK `^3.13.0`, Flutter `>=3.29.0`.
