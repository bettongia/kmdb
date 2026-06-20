# Database Encryption (§31)

## Overview

KMDB supports at-rest encryption for document values using AES-256-GCM with
random nonces. Encryption is applied at the Value Encoding layer, immediately
before the encoded bytes enter the storage engine and after they emerge from it.

The design follows the **envelope-encryption** model:

- A randomly-generated 256-bit **Data Encryption Key (DEK)** encrypts every
  document value.
- The DEK itself is **wrapped** (encrypted) under two Key Encryption Keys (KEKs):
  one derived from the user's passphrase using Argon2id, and one derived from a
  random recovery entropy using HKDF-SHA256.
- Both wrapped DEK copies are stored in a single CBOR-encoded record called the
  `enc:blob`, persisted in the `$meta` namespace via `MetaStore`.
- The DEK never leaves memory in plaintext outside of the running process.

This means:
- Rotating the passphrase requires only re-wrapping the DEK (no re-encryption of
  data).
- A user can regain access to their database using a 16-word recovery code, even
  if the passphrase is lost.

## Algorithms

| Purpose                   | Algorithm         | Parameters                              |
| :------------------------ | :---------------- | :-------------------------------------- |
| Data encryption           | AES-256-GCM       | 256-bit key, 96-bit random nonce, 128-bit tag |
| Passphrase → KEK          | Argon2id          | m = 64 MiB (65536 KiB), t = 3 rounds, p = 1 lane |
| Recovery entropy → KEK    | HKDF-SHA256       | Salt = SHA-256(recovery\_entropy), info = `"kmdb-recovery-kek"` |
| DEK wrapping              | AES-256-GCM       | Same as data encryption, different key  |
| DEK generation            | CSPRNG            | `SecureRandom` from `package:cryptography` |

Argon2id parameters were chosen to require ~1–2 s on a mid-range mobile device
(m = 64 MiB is the plan-reviewed floor; the stored parameters are always read
from `enc:blob` so they can be upgraded in a future version without breaking
existing databases).

## Wire Format

Encryption extends the existing Value Encoding pipeline (§5) from a one-byte
prefix to a two-byte prefix scheme.

### Plaintext wire format (no encryption)

```
[EncryptionFlag 0x00] [CompressionFlag 1B] [CBOR payload ...]
```

### Encrypted wire format

```
[EncryptionFlag 0x01] [AES-GCM nonce 12B] [ciphertext ...] [GCM tag 16B]
```

Where the ciphertext is the encryption of:

```
[CompressionFlag 1B] [CBOR payload ...]
```

The CompressionFlag byte is moved **inside** the ciphertext when encryption is
active. This prevents an observer from distinguishing compressed from uncompressed
values without the key, hiding any algorithm information that could assist
cryptanalysis.

The `EncryptionFlag` byte values:

| Byte   | Meaning    |
| :----- | :--------- |
| `0x00` | Plaintext  |
| `0x01` | AES-256-GCM |

Any other `EncryptionFlag` byte is rejected with `ArgumentError`.

## Encoding Pipeline with Encryption

```
Dart object (T)
    ↓  codec.encode(value)
Map<String, dynamic>
    ↓  cbor.encode()
Uint8List (CBOR bytes)
    ↓  Zstd (optional)
[CompressionFlag][CBOR or compressed payload]
    ↓  AesGcmEncryptionProvider.encrypt()  (if encryption is active)
[0x01 nonce(12B) ciphertext tag(16B)]
    ↓  (or, without encryption)
[0x00 CompressionFlag CBOR payload]
SSTable slot value
```

## enc:blob Structure

The `enc:blob` is a CBOR-encoded map stored in the `$meta` namespace under the
key `enc:blob`. It is read and written via `MetaStore.getEncryptionBlob()` and
`MetaStore.putEncryptionBlob()`, which bypass the normal ValueCodec path (no
encryption applied to the blob itself — it is already protected by the wrapped
DEK). This avoids a circular dependency: decrypting values requires the DEK,
which requires reading `enc:blob`, which must not itself be encrypted.

```
{
  "v": 1,                          ← schema version
  "salt": <bytes 32B>,             ← Argon2id salt
  "wrapped_dek_passphrase": <bytes>, ← DEK wrapped under passphrase-derived KEK
  "wrapped_dek_recovery":   <bytes>, ← DEK wrapped under recovery-derived KEK
  "argon2_memory":      65536,     ← KiB; default 64 MiB
  "argon2_iterations":  3,         ← time cost
  "argon2_parallelism": 1,         ← lane count
}
```

All fields are required. Unknown keys are ignored to allow forward extension.

## Bootstrap Sequence

Encryption is bootstrapped in `KmdbDatabase.open()`, between `KvStoreImpl.open()`
and the construction of higher-level collaborators (CacheLayer, IndexManager,
FtsManager, VecManager, VaultStore, VersionManager).

The bootstrap implements a **4-state matrix** based on the presence of `enc:blob`
in the database and whether the caller supplies an `EncryptionConfig`:

| State | enc:blob present? | EncryptionConfig supplied? | Action |
| :---- | :---------------- | :------------------------- | :----- |
| 1     | No                | No                         | Open plaintext — `encryption` field is `null` |
| 2     | Yes               | No                         | Throw `EncryptionError.databaseIsEncrypted` |
| 3     | No                | Yes (unlock mode)          | Throw `EncryptionError.databaseIsNotEncrypted` |
| 4     | No                | Yes (provisioning mode)    | Write fresh `enc:blob`, derive DEK, set `encryption` provider |
| 5     | Yes               | Yes (unlock mode)          | Derive/unwrap DEK from passphrase or recovery code |

States 4 and 5 both yield an `AesGcmEncryptionProvider` stored in
`KmdbDatabase.encryption`.

### Provisioning Guard

State 4 (provisioning an empty database) rejects databases that already contain
any KV entries. The check is performed by scanning the `$meta` namespace for
existing records and verifying the database is truly empty. A non-empty database
that lacks `enc:blob` cannot be safely retroactively encrypted — it would produce
a mix of plaintext and encrypted values. The caller receives
`EncryptionError.cannotProvisionNonEmptyDatabase`.

## Key Derivation

### Passphrase → KEK

```dart
final kek = await KeyDerivation.deriveKekFromPassphrase(passphrase, salt);
```

Uses Argon2id with the parameters stored in `enc:blob`. Output: 32 bytes.

### Recovery Entropy → KEK

```dart
final kek = await KeyDerivation.deriveKekFromRecovery(recoveryEntropy);
```

Uses HKDF-SHA256. Input: 16 bytes of recovery entropy. Output: 32 bytes.

### DEK Wrap / Unwrap

The DEK is wrapped and unwrapped using AES-256-GCM with a random nonce:

```
wrapped_dek = nonce(12B) || AES-GCM-256(key=kek, plaintext=dek) || tag(16B)
```

An authentication failure during unwrapping (`AesGcmSecretBox.authenticate`)
surfaces as `EncryptionError.badCredentials`.

## Recovery Code

The recovery code is a 16-word mnemonic derived from 16 bytes (128 bits) of
CSPRNG-generated entropy. It uses a fixed 256-word wordlist (one word per byte
value, 8 bits per word).

Recovery codes are generated at provisioning time and displayed to the user
exactly once. They are not stored anywhere in the database — only the DEK wrapped
under the recovery-derived KEK is stored in `enc:blob`.

To unlock with a recovery code, KMDB decodes the mnemonic back to 16 bytes,
derives the recovery-KEK via HKDF-SHA256, and unwraps the
`wrapped_dek_recovery` field.

The `RecoveryCode` utility class handles encoding and decoding:

```dart
// Provisioning: generate entropy, encode to mnemonic.
final entropy = await KeyDerivation.generateRecoveryEntropy();
final code = RecoveryCode.encode(entropy);  // "able acid aged ... zone"

// Unlock: decode mnemonic back to entropy.
final decoded = RecoveryCode.decode(code); // Uint8List(16)
```

`RecoveryCode.decode` throws `FormatException` if the code has the wrong number
of words or contains an unknown word. It is case-insensitive and tolerant of
extra whitespace.

## DEK Cache

The `DekCache` interface provides a session-scoped cache for the decrypted DEK
so that Argon2id derivation is only run once per database open.

```dart
abstract interface class DekCache {
  Future<Uint8List?> read(String dbId);
  Future<void> store(String dbId, Uint8List dek);
  Future<void> clear(String dbId);
}
```

The default implementation `InMemoryDekCache` stores the DEK in a `Map` in
process memory. The `FlutterSecureDekCache` from the `kmdb_flutter` add-on
package stores the DEK in Flutter's `FlutterSecureStorage` (iOS Keychain /
Android Keystore) — recommended for production mobile apps.

If the DEK is found in the cache, Argon2id is skipped and the cached DEK is
used directly (only AES-GCM decryption of `enc:blob` is still performed to
confirm the cached key is correct). Clearing the cache requires re-derivation on
the next open.

## Vault Encryption

When encryption is active, the `VaultStore` encrypts blob bytes before writing
them to disk. The SHA-256 content address and CRC32C checksum are always computed
over the **plaintext** bytes, preserving the deduplication guarantee:

```
sha256 = SHA-256(plaintext)   // used as the content address
stored = nonce(12B) || AES-GCM-256(key=dek, plaintext=blob) || tag(16B)
```

The `manifest.json` for each blob gains an `encrypted: boolean` field:

```json
{
  "sha256": "...",
  "crc32c": 12345678,
  "mimeType": "image/jpeg",
  "size": 1024,
  "hlcTimestamp": "...",
  "encrypted": true
}
```

When reading a blob, `VaultStore.getBytes()` checks this flag. If `encrypted:
true` but no `EncryptionProvider` is available, a `StateError` is thrown.

KVLT archive export (`VaultStore.exportKvlt`) decrypts blobs to plaintext before
packing them. KVLT import re-encrypts blobs if the destination database has
encryption active.

## Provider Threading

`EncryptionProvider?` is threaded as a named optional parameter through all
`ValueCodec.encode` / `ValueCodec.decode` call sites:

```dart
final bytes = await ValueCodec.encode(doc, encryption: _db.encryption);
final doc   = await ValueCodec.decode(bytes, encryption: _db.encryption);
```

All call sites in `KmdbCollection`, `IndexManager`, `FtsManager`, `VecManager`,
`VersionManager`, and `VaultRefInterceptor` receive the provider from
`KmdbDatabase.encryption`.

System namespace values (indexes, FTS, vector, versioning) are encrypted when
encryption is active. This is intentional: `$index:`, `$fts:`, `$vec:`,
`$ver:`, and `$vault:` namespaces are whole-file synced to the cloud — there is
no server-side namespace filtering. Encrypting index entries ensures that cloud
storage never sees plaintext document content in any form.

## Error Codes

`EncryptionError.code` is one of:

| Code                             | Meaning |
| :------------------------------- | :------ |
| `databaseIsEncrypted`            | `enc:blob` found but no config supplied (State 2) |
| `databaseIsNotEncrypted`         | Config supplied but no `enc:blob` found (State 3) |
| `badCredentials`                 | Argon2id/HKDF succeeded but AES-GCM authentication failed (wrong passphrase or recovery code) |
| `cannotProvisionNonEmptyDatabase`| Attempt to provision encryption on a non-empty database |
| `decryptionFailed`               | Decryption failed for a reason other than wrong credentials |
| `encryptionFailed`               | Encryption failed during a write |

## API Reference

### `EncryptionConfig`

```dart
// Unlock with passphrase (State 5):
EncryptionConfig(passphrase: 'my-secure-passphrase')

// Unlock with recovery code (State 5):
EncryptionConfig(recoveryCode: 'able acid aged ...')

// Provision (State 4 — use the result to show the recovery code):
final result = await EncryptionConfig.createResult(passphrase: '...');
final db = await KmdbDatabase.open(..., encryptionConfig: result.config);
// Show result.recoveryCode to the user (one-time event).
```

### `KmdbDatabase.open()` — encryption parameter

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/db',
  adapter: adapter,
  encryptionConfig: EncryptionConfig(passphrase: 'passphrase'),
);
```

The `encryptionConfig` parameter is `null` for plaintext databases.

### `EncryptionProvider` / `AesGcmEncryptionProvider`

```dart
final dek = await KeyDerivation.generateDek(); // 32 random bytes
final provider = AesGcmEncryptionProvider(dek);

final ciphertext = await provider.encrypt(plaintext);
final recovered  = await provider.decrypt(ciphertext);
```

## Platform Notes

- Encryption is supported on all platforms (native and web).
- Argon2id is pure-Dart (`package:cryptography`) — no native build hook required.
  On web, it runs in the same isolate and can take several seconds per derivation.
  Applications should show a loading indicator and perform derivation off the main
  isolate when possible.
- The `kmdb_flutter` add-on package provides:
  - `FlutterSecureDekCache` — caches the DEK in iOS Keychain / Android Keystore.
  - `KmdbFlutter.initialize()` — registers `cryptography_flutter` for
    hardware-accelerated AES-GCM on iOS (Secure Enclave) and Android (Keystore).

### Flutter Integration

Flutter apps should use the `kmdb_flutter` add-on package to enable both
persistent DEK caching and hardware-accelerated cryptography.  Add it to your
`pubspec.yaml`:

```yaml
dependencies:
  kmdb: ...
  kmdb_flutter:
    path: packages/kmdb_flutter  # or a pub.dev version once published
```

Then wire it in `main()`:

```dart
import 'package:flutter/material.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_flutter/kmdb_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register native AES-256-GCM / Argon2id acceleration.
  // Must be called before any KmdbDatabase.open() with encryption enabled.
  KmdbFlutter.initialize();

  final db = await KmdbDatabase.open(
    path: '/path/to/db',
    adapter: adapter,
    encryptionConfig: EncryptionConfig(
      passphrase: 'my-secure-passphrase',
      // Persist the DEK in Keychain/Keystore so the user is only prompted
      // once per device, not on every app launch.
      dekCache: FlutterSecureDekCache(),
    ),
  );

  runApp(MyApp(db: db));
}
```

#### DEK storage key

`FlutterSecureDekCache` derives a Keychain/Keystore key from the database path
using `kmdb_dek_<base64url(utf8(path))>` (no padding).  The key is stable as
long as the database path is byte-identical across launches.

**Path-stability caveat (iOS):** On iOS, the app sandbox container path can
change after an OS restore or device migration.  If it does, `read` returns
`null` and the user is re-prompted for their passphrase — a graceful degradation,
not data loss.  The roadmap 0.07 `PlatformIdStore` abstraction is designed to
provide a stable cross-path device identifier that will resolve this limitation;
`FlutterSecureDekCache` is its intended first consumer.

#### Web

Web does not use `FlutterSecureDekCache`.  The project's position is that DEKs
are not persisted in browser storage (v1).  Flutter web apps should omit the
`dekCache` parameter (or use the default `InMemoryDekCache`) and re-derive the
DEK from the passphrase on each page load.  See RC-16 in
`docs/spec/28_release_checklist.md` for the web Argon2id timing verification.

#### Accessibility defaults

| Platform | Default                                           |
| :------- | :------------------------------------------------ |
| iOS      | `KeychainAccessibility.first_unlock_this_device`  |
| macOS    | `KeychainAccessibility.first_unlock_this_device`  |
| Android  | `AndroidOptions()` (AES-GCM/NoPadding, RSA-OAEP) |

The "this device" variant on iOS/macOS ensures the DEK is **never synced to
iCloud Keychain**.  Hosts that need tighter access control (biometric gate,
Secure Enclave) can supply custom `IOSOptions`/`MacOsOptions`/`AndroidOptions`
to the `FlutterSecureDekCache` constructor.

#### `KmdbFlutter.initialize()` idempotency

`initialize()` is safe to call more than once (e.g. across hot-reloads or in
tests) — a static guard ensures `FlutterCryptography.enable()` is called at most
once per process.  As of `cryptography_flutter` 2.3.4 Flutter auto-registers the
plugin, so `initialize()` is technically optional; calling it explicitly remains
the recommended pattern to document intent and ensure activation before `runApp()`.

## Crash Safety

The `enc:blob` provisioning write enters the WAL before `KmdbDatabase.open()`
returns. User data writes can only happen after `open()` completes. Therefore, in
the WAL, `enc:blob` is always written before any encrypted user value.

After a crash:
- If no data was fsynced: the database is empty, unencrypted — safe to
  re-provision.
- If `enc:blob` was fsynced but user data was not: the database is consistently
  encrypted and empty — unlock with the passphrase to verify.
- If both were fsynced: full recovery possible.
- The scenario "encrypted user data present, enc:blob absent" **cannot occur**
  by construction.
