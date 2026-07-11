# Database Encryption

## Overview

KMDB supports at-rest encryption for document values using AES-256-GCM with
random nonces. Encryption is applied at the Value Encoding layer, immediately
before the encoded bytes enter the storage engine and after they emerge from it.

The design follows the **envelope-encryption** model:

- A randomly-generated 256-bit **Data Encryption Key (DEK)** encrypts every
  document value.
- The DEK itself is **wrapped** (encrypted) under two Key Encryption Keys
  (KEKs): one derived from the user's passphrase using Argon2id, and one derived
  from a random recovery entropy using HKDF-SHA256.
- Both wrapped DEK copies are stored in a single CBOR-encoded record called the
  `enc:blob`, persisted in the `$meta` namespace via `MetaStore`.
- The DEK never leaves memory in plaintext outside of the running process.

This means:

- Rotating the passphrase requires only re-wrapping the DEK (no re-encryption of
  data).
- A user can regain access to their database using a 16-word recovery code, even
  if the passphrase is lost.

## Algorithms

| Purpose                | Algorithm   | Parameters                                                     |
| :--------------------- | :---------- | :------------------------------------------------------------- |
| Data encryption        | AES-256-GCM | 256-bit key, 96-bit random nonce, 128-bit tag                  |
| Passphrase → KEK       | Argon2id    | m = 64 MiB (65536 KiB), t = 3 rounds, p = 1 lane               |
| Recovery entropy → KEK | HKDF-SHA256 | Salt = SHA-256(recovery_entropy), info = `"kmdb-recovery-kek"` |
| DEK wrapping           | AES-256-GCM | Same as data encryption, different key                         |
| DEK generation         | CSPRNG      | `SecureRandom` from `package:cryptography`                     |

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
active. This prevents an observer from distinguishing compressed from
uncompressed values without the key, hiding any algorithm information that could
assist cryptanalysis.

The `EncryptionFlag` byte values:

| Byte   | Meaning     |
| :----- | :---------- |
| `0x00` | Plaintext   |
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

Encryption is bootstrapped in `KmdbDatabase.open()`, between
`KvStoreImpl.open()` and the construction of higher-level collaborators
(CacheLayer, IndexManager, FtsManager, VecManager, VaultStore, VersionManager).

The bootstrap implements a **4-state matrix** based on the presence of
`enc:blob` in the database and whether the caller supplies an
`EncryptionConfig`:

| State | enc:blob present? | EncryptionConfig supplied? | Action                                                        |
| :---- | :---------------- | :------------------------- | :------------------------------------------------------------ |
| 1     | No                | No                         | Open plaintext — `encryption` field is `null`                 |
| 2     | Yes               | No                         | Throw `EncryptionError.databaseIsEncrypted`                   |
| 3     | No                | Yes (unlock mode)          | Throw `EncryptionError.databaseIsNotEncrypted`                |
| 4     | No                | Yes (provisioning mode)    | Write fresh `enc:blob`, derive DEK, set `encryption` provider |
| 5     | Yes               | Yes (unlock mode)          | Derive/unwrap DEK from passphrase or recovery code            |

States 4 and 5 both yield an `AesGcmEncryptionProvider` stored in
`KmdbDatabase.encryption`.

### Provisioning Guard

State 4 (provisioning an empty database) rejects databases that already contain
any KV entries. The check is performed by scanning the `$meta` namespace for
existing records and verifying the database is truly empty. A non-empty database
that lacks `enc:blob` cannot be safely retroactively encrypted — it would
produce a mix of plaintext and encrypted values. The caller receives
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
exactly once. They are not stored anywhere in the database — only the DEK
wrapped under the recovery-derived KEK is stored in `enc:blob`.

To unlock with a recovery code, KMDB decodes the mnemonic back to 16 bytes,
derives the recovery-KEK via HKDF-SHA256, and unwraps the `wrapped_dek_recovery`
field.

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

If the DEK is found in the cache, Argon2id is skipped and the cached DEK is used
directly (only AES-GCM decryption of `enc:blob` is still performed to confirm
the cached key is correct). Clearing the cache requires re-derivation on the
next open.

## Vault Encryption

When encryption is active, the `VaultStore` encrypts blob bytes before writing
them to disk. The SHA-256 content address and CRC32C checksum are always
computed over the **plaintext** bytes, preserving the deduplication guarantee:

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

When reading a blob, `VaultStore.getBytes()` checks this flag. If
`encrypted: true` but no `EncryptionProvider` is available, a `StateError` is
thrown.

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

All call sites in `KmdbCollection`, `IndexManager`, `VersionManager`, and
`VaultRefInterceptor` receive the provider from `KmdbDatabase.encryption`.

System namespace values vary in their sync behaviour. `$ver:` and `$vault:`
entries ride in syncable SSTables and reach the cloud. `$$index:`, `$$fts:`,
and `$$vec:` entries are **local-only** — they are stored in `.local.sst` files
and never uploaded (see §6 Flush Partitioning, §12). The **design intent** is
that all index values are encrypted so disk storage never sees plaintext document
content. In practice there is a known gap: `FtsManager` and `VecManager`
currently write their index values via raw `cbor.encode()`, not
`ValueCodec.encode(encryption:)`, so `$$fts:` and `$$vec:` values are **not yet
encrypted**. This is tracked as a defect in the v0.08
encryption reconciliation work item and will be corrected before the v1 beta.
See the "Threat Model & Confidentiality Boundaries" section for the full picture
of protected and unprotected surfaces.

## Error Codes

`EncryptionError.code` is one of:

| Code                              | Meaning                                                                                       |
| :-------------------------------- | :-------------------------------------------------------------------------------------------- |
| `databaseIsEncrypted`             | `enc:blob` found but no config supplied (State 2)                                             |
| `databaseIsNotEncrypted`          | Config supplied but no `enc:blob` found (State 3)                                             |
| `badCredentials`                  | Argon2id/HKDF succeeded but AES-GCM authentication failed (wrong passphrase or recovery code) |
| `cannotProvisionNonEmptyDatabase` | Attempt to provision encryption on a non-empty database                                       |
| `decryptionFailed`                | Decryption failed for a reason other than wrong credentials                                   |
| `encryptionFailed`                | Encryption failed during a write                                                              |

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
- Argon2id is pure-Dart (`package:cryptography`) — no native build hook
  required. On web, it runs in the same isolate and can take several seconds per
  derivation. Applications should show a loading indicator and perform
  derivation off the main isolate when possible.
- The `kmdb_flutter` add-on package provides:
  - `FlutterSecureDekCache` — caches the DEK in iOS Keychain / Android Keystore.
  - `KmdbFlutter.initialize()` — registers `cryptography_flutter` for
    hardware-accelerated AES-GCM on iOS (Secure Enclave) and Android (Keystore).

### Flutter Integration

Flutter apps should use the `kmdb_flutter` add-on package to enable both
persistent DEK caching and hardware-accelerated cryptography. Add it to your
`pubspec.yaml`:

```yaml
dependencies:
  kmdb: ...
  kmdb_flutter:
    path: packages/kmdb_flutter # or a pub.dev version once published
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
using `kmdb_dek_<base64url(utf8(path))>` (no padding). The key is stable as long
as the database path is byte-identical across launches.

**Path-stability caveat (iOS):** On iOS, the app sandbox container path can
change after an OS restore or device migration. If it does, `read` returns
`null` and the user is re-prompted for their passphrase — a graceful
degradation, not data loss. The roadmap 0.07 `PlatformIdStore` abstraction is
designed to provide a stable cross-path device identifier that will resolve this
limitation; `FlutterSecureDekCache` is its intended first consumer.

#### Web

Web does not use `FlutterSecureDekCache`. The project's position is that DEKs
are not persisted in browser storage (v1). Flutter web apps should omit the
`dekCache` parameter (or use the default `InMemoryDekCache`) and re-derive the
DEK from the passphrase on each page load. See RC-16 in
`docs/spec/28_release_checklist.md` for the web Argon2id timing verification.

#### Accessibility defaults

| Platform | Default                                          |
| :------- | :----------------------------------------------- |
| iOS      | `KeychainAccessibility.first_unlock_this_device` |
| macOS    | `KeychainAccessibility.first_unlock_this_device` |
| Android  | `AndroidOptions()` (AES-GCM/NoPadding, RSA-OAEP) |

The "this device" variant on iOS/macOS ensures the DEK is **never synced to
iCloud Keychain**. Hosts that need tighter access control (biometric gate,
Secure Enclave) can supply custom `IOSOptions`/`MacOsOptions`/`AndroidOptions`
to the `FlutterSecureDekCache` constructor.

#### `KmdbFlutter.initialize()` idempotency

`initialize()` is safe to call more than once (e.g. across hot-reloads or in
tests) — a static guard ensures `FlutterCryptography.enable()` is called at most
once per process. As of `cryptography_flutter` 2.3.4 Flutter auto-registers the
plugin, so `initialize()` is technically optional; calling it explicitly remains
the recommended pattern to document intent and ensure activation before
`runApp()`.

## Threat Model & Confidentiality Boundaries

### Threat Model

Encryption in KMDB is designed to protect **document content** against two
specific adversaries:

1. **The cloud storage provider** (and anyone with access to the synced files).
   KMDB syncs whole SSTable files — the provider receives the complete on-disk
   representation of every flushed and consolidated SSTable. The encryption
   scheme ensures that the provider cannot read document values from those files
   without the DEK.
2. **Physical access to a device** by an adversary who does **not** know the
   passphrase (e.g. a lost or stolen phone). Because the DEK is wrapped under a
   passphrase-derived (Argon2id) KEK and never persisted in plaintext, an
   attacker who cannot supply the passphrase or recovery code cannot decrypt
   document values from the on-disk database.

Encryption is **not** designed to:

- Conceal **metadata** — file sizes, timing, device identities, document
  existence, indexed values, or search vocabulary. Several structural surfaces
  remain plaintext by design or by current limitation (enumerated below).
- Resist a **fully-compromised local OS** or a process that can read the running
  KMDB process's memory. The DEK is held in plaintext in process memory for the
  lifetime of an open database; an adversary with that level of access has
  already won.

The remainder of this section honestly enumerates what is and is not protected.

### Protected (encrypted)

When encryption is active, the following are encrypted at rest and in cloud
sync:

- **Document values** — encrypted via `ValueCodec.encode(encryption:)` before
  they enter the storage engine (see _Encoding Pipeline with Encryption_).
- **System namespace values that pass through `ValueCodec`** — the _values_
  stored under `$$index:`, `$ver:`, `$vault:` ref-count entries, and `$cache:`
  materialised views (when the materialised-view cache is implemented) are
  encrypted, because their write paths thread the `EncryptionProvider` through
  `ValueCodec.encode` (see _Provider Threading_).
- **Vault blob bytes** — the `VaultStore` encrypts blob payloads with the DEK
  before writing them to disk and to the cloud (see _Vault Encryption_).
- **Vault `extract/` filesystem artifacts (WI-10, gap 6 below)** — `text.txt`,
  `chunks_v1.json`, and `vectors_*.bin` are encrypted with the DEK when
  written *after* an `EncryptionProvider` is configured. This protection is
  **per-file, not database-wide**: artifacts written before encryption was
  provisioned remain plaintext until the owning blob is reindexed (see gap 6
  for the full toggle-on/mixed-state behaviour).

> **Note on namespace _names_ vs. _values_.** Encryption protects the _value_
> bytes of a KV slot. It does **not** protect the _key_ of the slot, of which
> the namespace name is a part. Where a namespace name embeds content-derived
> data (see gaps 2 and 3 below), that data is not protected even when the
> corresponding value is.

### Known gaps and unprotected surfaces

The following surfaces are **not** protected when encryption is enabled. Some
are intentional design trade-offs; others are code defects or architectural
limitations under active work. Each is documented honestly so that callers can
reason about the true confidentiality boundary.

#### 1. FTS and Vec index _values_ are not encrypted (code defect)

`FtsManager` and `VecManager` currently serialise their index entries with a
direct `cbor.encode()` call rather than `ValueCodec.encode(encryption:)`. As a
result, the _values_ stored under the `$$fts:` and `$$vec:` namespaces are **not
encrypted**, even when encryption is active.

This **contradicts the claim made above in _Provider Threading_** (the statement
that `$$fts:` and `$$vec:` values are encrypted). That claim is currently
incorrect for FTS and Vec; it is accurate for `$$index:`, `$ver:`, and `$vault:`.
This is a code defect to be fixed by routing the FTS and Vec write paths through
`ValueCodec`. Until it is fixed, `$$fts:doc:` values in particular **leak the
full tokenised term list of every document** to anyone with local SSTable access.

The same defect extends to the vault-search writers (`VaultBm25Writer`,
`VaultVecWriter`, `VaultExtractionState`), which serialise `$$vault:fts:`,
`$$vault:vec:idx:{sha256}`, and `$$vault:extract:{sha256}` the same
unencrypted way — including `$$vault:vec:idx:`, the per-chunk SQ8 vector
index missed by the original WI-3 audit (see `docs/roadmap/0_06.md`'s
correction). **Progress note (Encryption confidentiality reconciliation
plan, Phase 1 — in progress, see `docs/roadmap/0_08.md`):** the FTS, Vec, and
vault-search write paths (via `EncryptionEnvelope` for scalar/opaque values
and `ValueCodec` for the remaining map-shaped ones) now encrypt these values
when a provider is configured; this section is updated to mark the gap
resolved once all four gaps in that plan have landed.

#### 2. FTS namespace names embed search terms (architectural limitation)

The lexical index uses a namespace-per-term layout,
`$$fts:{ns}:{field}:{hexTerm}`, which embeds the (hex-encoded) search term
directly in the namespace name. Namespace names are part of the SSTable _key_
and are **never encrypted**. An adversary with local SSTable access can therefore
enumerate the entire **search vocabulary** of the database — every distinct term
that appears in any indexed field — simply by scanning namespace names. (These
SSTables are local-only and never uploaded; the threat is a compromised local
filesystem.)

Closing this requires an architectural change to the FTS key layout and is under
active research. It is documented here as a known limitation rather than a
defect that can be fixed by threading a provider.

#### 3. Secondary index namespace names embed indexed values

Secondary indexes use the layout `$$index:{ns}:{field}:{value}`, which embeds the
**indexed field value** in the namespace name. As with FTS namespaces (gap 2),
namespace names are part of the SSTable key and are never encrypted. This is not
document content per se, but the indexed values drawn from documents — e.g.
every distinct value of an indexed `status` or `email` field — are visible to
anyone with SSTable access.

#### 4. `MetaStore` values are not encrypted

`MetaStore` bypasses `ValueCodec` entirely and writes raw CBOR directly to
`_engine.put()`. For the `enc:blob` entry this is **intentional and required**:
the blob is already protected by the wrapped DEK, and decrypting any value
requires first reading `enc:blob`, so it cannot itself be encrypted (see
_enc:blob Structure_).

For **all other** `$meta` entries — device ID, the namespace registry,
generation counters, HLC timestamps, and model identity — the lack of encryption
is a previously-undocumented gap. These values reveal **operational metadata**
(which namespaces exist, write activity via generation counters, device
identity, timing) but **not document content**.

#### 5. Vault `manifest.json` is plaintext

Each vault blob is accompanied by a plaintext `manifest.json` on disk and in
cloud sync, containing `mediaType`, `size`, `hlcTimestamp`, `sha256`, and
`originalName`.

- The `sha256` content address is **intentionally** computed over the plaintext
  blob bytes so that deduplication continues to work across devices (documented
  in _Vault Encryption_).
- `originalName`, `mediaType`, and `size` are plaintext surfaces that are
  **not** otherwise acknowledged. They leak the original filename, content type,
  and size of every stored blob to anyone with sync or disk access.

#### 6. Vault `extract/` filesystem artifacts (resolved — WI-10)

Vault search (WI-3) writes three per-blob filesystem artifacts alongside each
encrypted blob's `extract/` subdirectory: `text.txt` (full extracted text),
`chunks_v1.json` (chunk byte-offset metadata), and `vectors_{modelId}_sq8.bin`
(SQ8-quantised embedding vectors, semantic mode only). No fourth
`extract_status.json` file is ever written — extraction status is persisted
solely to the `$$vault:extract:{sha256}` KV entry (see gap 1's sibling
discussion of unencrypted KV _values_, which is a separate, still-open defect
tracked as v0.08 Gap 1).

WI-10 encrypts these three files when a database `EncryptionProvider` is
configured, using `VaultSearchManager.writeExtractArtifact` /
`readExtractArtifact`. Because `extract/` files have no accompanying manifest
(unlike vault blobs, which use `manifest.json`'s `encrypted` field), each file
is **self-describing**: it is prefixed with a single `EncryptionFlag` byte —
the same enum used by the `ValueCodec` wire format (see _Wire Format_ above),
applied here to whole files:

```
[EncryptionFlag.none  (0x00)] plaintext body follows verbatim
[EncryptionFlag.aesGcm (0x01)] nonce(12B) || AES-256-GCM ciphertext || tag(16B)
```

This makes every artifact independently readable regardless of the database's
*current* encryption state or *when* the file was written, which matters for
the toggle-on transition: a database that already has plaintext `extract/`
artifacts from before encryption was provisioned keeps those files readable
(flag byte `0x00`) without any migration step. Newly indexed or re-indexed
blobs (via `VaultSearchManager.reindexVault()`) are written with the encrypted
flag (`0x01`) once a provider is configured. Both flag states can coexist
across blobs in the same database indefinitely — there is no requirement to
reindex old blobs, though doing so is recommended to close the plaintext gap
for previously-indexed content.

These files are read/written whole-file only — an AES-GCM-encrypted artifact
cannot be range-read, since the entire ciphertext is required to verify the
authentication tag before any plaintext is released.

A decrypt failure is handled differently depending on the read site: startup
recovery (`VaultSearchManager.recover()`) treats it identically to any other
filesystem read failure — the blob resets to `pending` and is re-queued for a
full re-extraction (self-healing, no crash). `KmdbCollection.searchVault()`
snippet/BM25-length reads propagate the failure instead of silently dropping
the hit or returning an empty snippet, since a decrypt failure at query time
(the DEK having already been validated once at `KmdbDatabase.open()`)
indicates genuine on-disk corruption the caller should learn about.

#### 7. SSTable filenames and WAL structure are plaintext

SSTable filenames encode `deviceId`, `minHlc`, and `maxHlc` (see _SSTable
Naming_ in §08) and are never encrypted. WAL files contain plaintext key names
(namespace + document ID). These surfaces reveal **timing**, **device
identity**, and **document existence**, but not document content.

#### 8. UUIDv7 document keys embed creation timestamps

All document IDs are UUIDv7 values, which embed a millisecond-precision creation
timestamp (see §04). This is an **intentional design feature** — it gives keys a
natural time order — but it has a confidentiality consequence not otherwise
framed in this section: anyone who can see a document key can recover the
document's creation time to the millisecond.

### Summary

Encryption gives a strong guarantee about **document value confidentiality**
against a cloud provider or a passphrase-less device thief. It gives **no
guarantee** about metadata: search vocabulary, indexed values, filenames, blob
manifests, operational `$meta`, document existence, timing, and creation
timestamps all remain observable. Gap 1 is additionally a **content** leak
(tokenised terms) that is tracked as a defect/work item rather than an
accepted trade-off. Gap 6 (vault `extract/` filesystem artifacts, including
the full extracted plaintext in `text.txt`) was the other content-leak gap in
this category — it is now resolved by WI-10.

## Crash Safety

The `enc:blob` provisioning write enters the WAL before `KmdbDatabase.open()`
returns. User data writes can only happen after `open()` completes. Therefore,
in the WAL, `enc:blob` is always written before any encrypted user value.

After a crash:

- If no data was fsynced: the database is empty, unencrypted — safe to
  re-provision.
- If `enc:blob` was fsynced but user data was not: the database is consistently
  encrypted and empty — unlock with the passphrase to verify.
- If both were fsynced: full recovery possible.
- The scenario "encrypted user data present, enc:blob absent" **cannot occur**
  by construction.
