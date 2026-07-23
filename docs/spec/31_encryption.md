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

### Database Format-Version Gate

The Encryption confidentiality reconciliation plan's Phase 2 (Gap 3) made
every general `$meta` accessor route through `EncryptionEnvelope`. This is a
**pre-v1-beta breaking on-disk format change for every existing database, not
just encrypted ones**: a database created by pre-plan code stores `$meta`
values as bare CBOR with no leading flag byte, but the post-plan read path
always expects one — and several of those values are authoritative and not
rebuildable (`device_id` in particular; a changed device identity breaks sync
continuity), so silently reinterpreting a legacy value's first CBOR byte as
an `EncryptionFlag` would be actively dangerous, not just wrong.

`KvStoreImpl.open()` therefore checks a `formatVersion` marker
(`MetaStore.kFormatVersionMarkerName`, itself read/written via the same
raw, non-circular path as `enc:blob` — see `MetaStore.
getFormatVersionMarker`/`putFormatVersionMarker`) immediately after crash
recovery, before any other `$meta`/index/FTS/Vec/vault value is read through
`EncryptionEnvelope`/`ValueCodec`. Three-way discrimination (marker absence
alone is not sufficient — a brand-new database also has no marker until this
gate writes one):

1. **Looks fresh** (`CrashRecovery`'s `isNewDatabase`, or `$meta` scans as
   completely empty even if `CURRENT` exists — the widened check needed for
   `fsyncOnWrite: false` test configs where a crash can leave `CURRENT`
   durable but every `$meta` write lost) → write the marker
   (`kCurrentFormatVersion = 1`) and proceed normally. This is the only path
   a brand-new database takes.
2. **Marker present and current** → proceed normally. This is the steady
   state for every database opened after this plan landed.
3. **Marker absent and the database is not empty** → the database predates
   this plan. Throw `LegacyDatabaseFormatException` — a clean, explicit
   failure (not a silent misparse of a legacy value as encrypted garbage).

**There is no migration path, consistent with the original Phase 12
encryption precedent (no in-place migration for encryption either): a
database created before this plan landed must be recreated.** This applies
to every pre-plan database, encrypted or not, since the format break is in
the general `$meta` framing, not specifically in encryption. See
`docs/spec/28_release_checklist.md` RC-22 for anyone upgrading a
pre-existing dev/test database.

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
  "schemaVersion": "1",
  "sha256": "...",
  "size": 1024,
  "crc32c": "a1b2c3d4",
  "mediaType": "image/jpeg",
  "originalName": "photo.jpg",
  "createdAt": "...",
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

System namespace values vary in their sync behaviour. `$meta`, `$ver:`, and
`$vault:` entries (all single-`$`) ride in syncable SSTables and reach the
cloud. `$$index:`, `$$fts:`, and `$$vec:` entries (double-`$$`) are
**local-only** — they are stored in `.local.sst` files and never uploaded (see
§6 Flush Partitioning, §12). The syncable/local-only split is decided **only**
by the `$$` prefix via the flush-time `.local.sst` partitioning, not by the
`syncNamespaces` parameter: `syncNamespaces` defaults to the user (non-`$`)
collections and is deliberately **not** applied as a per-entry upload filter,
so `$meta` — despite being `$`-prefixed and thus excluded from that default set
— still rides synced SSTables and reaches the cloud. This is exactly why `$meta`
encryption (Gap 3) closes a genuine cloud-provider exposure, not merely a
local-disk one. See §12 _Namespace-Scoped Sync_ for the full mechanism. All index values are
encrypted so disk storage never sees plaintext document content: `FtsManager`
and `VecManager` route their index values through `EncryptionEnvelope`/
`ValueCodec` per value shape, and `MetaStore` (the `$meta` system namespace —
device ID, namespace registry, generation counters, index/FTS/Vec state) is
encrypted end to end except the one documented `enc:blob` exemption (see
_enc:blob Structure_ above). The vault-search writers
(`VaultBm25Writer`/`VaultVecWriter`/`VaultExtractionState`) are likewise
encrypted at the `VaultSearchManager` call site. **This closes what was
previously documented here as a known gap** (`FtsManager`/`VecManager`
writing raw `cbor.encode()`) — see the Encryption confidentiality
reconciliation plan (`docs/roadmap/completed/0_08.md`), Gap 1.

Beyond value encryption, the `$$fts:`/`$$index:`/`$$vault:fts:` namespace
_names_ themselves are also protected when a provider is configured: the
`{term}`/`{value}` segment is an HMAC-SHA256 token
(`EncryptionProvider.indexToken`) rather than a plaintext hex encoding, so
local SSTable access can no longer enumerate the search vocabulary or
indexed field values by reading namespace names alone (Gap 2). See the
"Threat Model & Confidentiality Boundaries" section for the full picture of
protected and unprotected surfaces, including the residual statistical
leakage this token scheme does not close (term frequency, search-pattern
access, co-occurrence).

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
- **FTS, Vec, and vault-search index values** — the _values_ stored under
  `$$fts:`, `$$vec:`, `$$vault:fts:`, `$$vault:vec:idx:`, and `$$vault:extract:`
  are encrypted via `EncryptionEnvelope` (scalars/opaque bytes — term-frequency
  ints, SQ8 vectors, the BM25 corpus sentinel) or `ValueCodec` (`Map`-shaped
  values — `$$fts:doc:`, `VaultExtractionState`) per value shape (Encryption
  confidentiality reconciliation, Gap 1 — see gap 1 below). These namespaces
  are local-only, so this protects against local disk theft, not a cloud
  provider.
- **Secondary-index, FTS, and Vec index *state*** — `IndexState`,
  `FtsIndexState`, and `VecIndexState` (the `status`/`builtThrough` records
  tracking whether *this device* has built a derived index) are encrypted via
  `EncryptionEnvelope` and stored in the local-only `$$indexstate`/
  `$$ftsstate`/`$$vecstate` namespaces respectively (moved out of `$meta` by
  0.10.01 WI-11, SC-10 — see `docs/spec/12_sync.md`'s "`$meta` vs `$$`
  classification rule"). Like the sibling bullet above, this protects against
  local disk theft, not a cloud provider, since these namespaces never
  upload.
- **Tombstone GC floor** — likewise moved out of `$meta` into the local-only
  `$$gcstate` namespace (0.10.01 WI-11, Q-D), still `EncryptionEnvelope`-wrapped.
  Local-disk-theft protection only, for the same reason.
- **`$meta` operational metadata** — device ID, the namespace registry, and
  generation counters are encrypted via `EncryptionEnvelope` (Gap 3), the one
  documented exemption being `enc:blob` itself (see _enc:blob Structure_).
  Because `$meta` rides synced SSTables, this is genuine cloud-provider
  protection. (The dirty-open flag is also currently in `$meta`, encrypted the
  same way — but 0.10.01 WI-11's audit found it is likely mis-placed there for
  a different, non-confidentiality reason; see WI-14 on
  `docs/roadmap/0_10_01.md`.)
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

#### 1. FTS and Vec index _values_ are not encrypted (resolved — Encryption confidentiality reconciliation, Gap 1)

`FtsManager` and `VecManager` previously serialised their index entries with a
direct `cbor.encode()` call rather than `ValueCodec.encode(encryption:)`, so
the _values_ stored under the `$$fts:` and `$$vec:` namespaces were **not
encrypted**, even when encryption was active — including `$$fts:doc:` values,
which leaked the full tokenised term list of every document to anyone with
local SSTable access. The same defect extended to the vault-search writers
(`VaultBm25Writer`, `VaultVecWriter`, `VaultExtractionState`), which
serialised `$$vault:fts:`, `$$vault:vec:idx:{sha256}`, and
`$$vault:extract:{sha256}` the same unencrypted way — including
`$$vault:vec:idx:`, the per-chunk SQ8 vector index missed by the original
WI-3 audit (see `docs/roadmap/completed/0_06.md`'s correction).

**Resolved** by the Encryption confidentiality reconciliation plan's Phase 1
(`docs/roadmap/completed/0_08.md`, Gap 1; see `docs/plans/completed/
plan_0_08_encryption_confidentiality_reconciliation.md`). The FTS, Vec, and
vault-search write paths now route every index value through
`EncryptionEnvelope` (scalar/opaque values — term-frequency ints, SQ8
vectors, the BM25 corpus sentinel) or `ValueCodec` (the remaining
`Map`-shaped values — `$$fts:doc:`, `VaultExtractionState`) when a provider
is configured, matching the _Provider Threading_ section's claim above. The
one narrow, documented deviation from a literal per-value-shape split:
`FtsManager`'s overlay namespace (`_writeOverlayEntry`/`_writeTombstone`
share one namespace/key slot) keeps producing raw, self-describing CBOR with
only the outer `EncryptionEnvelope` layer added uniformly, since mixing
`ValueCodec`'s and `EncryptionEnvelope`'s distinct plaintext framings on a
shared slot would make the wire format ambiguous to readers.

#### 2. FTS namespace names embed search terms (resolved for encrypted databases — Encryption confidentiality reconciliation, Gap 2)

The lexical index uses a namespace-per-term layout,
`$$fts:{ns}:{field}:{token}`, which embeds the search term in the namespace
name. Namespace names are part of the SSTable _key_ and are **never
encrypted** as a byte sequence — the confidentiality property below comes
from what value is placed there, not from encrypting the namespace name
itself. Prior to Gap 2, `{token}` was a plaintext hex encoding of the term,
so an adversary with local SSTable access could enumerate the entire
**search vocabulary** of the database — every distinct term that appears in
any indexed field — simply by scanning namespace names. (These SSTables are
local-only and never uploaded; the threat is a compromised local
filesystem.)

**Resolved for encrypted databases** by the Encryption confidentiality
reconciliation plan's Phase 4 (`docs/roadmap/completed/0_08.md`, Gap 2): when a
database `EncryptionProvider` is configured, `{token}` is an HMAC-SHA256
token derived via `EncryptionProvider.indexToken` — a sub-key distinct from
(but derived from) the DEK via HKDF-SHA256 (`info = "kmdb-index-token"`),
never the raw DEK directly. The HMAC input is domain-separated as
`"{ns}:{field}:" + term`, so the same term in a different field or
collection never produces the same token. This closes the
**vocabulary-enumeration** attack this gap originally documented: an
adversary with local SSTable access can no longer recover which terms
appear anywhere in the database just by reading namespace names.
**Unencrypted databases are unaffected and remain a known, accepted
limitation** — they continue to use plaintext hex tokens, since there is no
DEK to derive a sub-key from and no confidentiality property claimed for an
unencrypted database in the first place.

This does **not** close every namespace-based side channel, only the specific
one this gap names (recovering the literal term/value from the namespace
name). The following statistical leakage remains, as an accepted limitation,
even on an encrypted database:

- **Term/value frequency** — the number of chunks in a base-term or
  secondary-index namespace (its "posting list" size) reveals how often that
  (unknown) term/value occurs, without revealing what it is.
- **Per-term/per-value document count** — the number of distinct document
  keys within a namespace reveals how many documents contain that (unknown)
  term/value.
- **Search-pattern / access-pattern leakage** — repeated queries against the
  same namespace over time reveal that the same (unknown) term/value is being
  searched for repeatedly, which combined with external context could narrow
  down what it is.
- **Co-occurrence** — an adversary who can correlate which namespaces are
  read together within a single query (e.g. a multi-term BM25 search) can
  infer that those (unknown) terms co-occur in the corpus, without knowing
  the terms themselves.

None of these reveal document *content* — they are the same class of
metadata leakage the rest of this section already documents for `$meta`,
manifests, and filenames (operational/statistical, not content). Closing them
would require a materially different index structure (e.g. oblivious RAM or
padding/bucketing schemes) that is out of scope for this plan.

**DEK-rotation interaction:** passphrase or recovery-code rotation re-wraps
the DEK under a new KEK but does not change the DEK itself (see _Key
Derivation_ above), so `EncryptionProvider.indexToken`'s HKDF sub-key —
derived from the DEK — is unchanged and every existing HMAC token remains
valid across rotation; no index rebuild is triggered or needed. A future
"change the DEK" feature (not currently implemented — there is no supported
way to replace the DEK on an existing database) would invalidate every
previously-derived token and require a full `$$fts:`/`$$index:`/`$$vault:fts:`
rebuild, exactly as a software-version upgrade of the tokenisation scheme
itself does today (see the `tokenMode` migration described next).

**Format-version migration:** `FtsIndexState`, the secondary index's `$meta`
state, and `VaultExtractionState` each persist a `tokenMode` (`hex` | `hmac`)
discriminator alongside their existing status fields. At
`KmdbDatabase.open()`, `FtsManager.checkAndTransitionOnOpen`,
`IndexManager.checkTokenModeOnOpen`, and `VaultSearchManager.recover` each
compare the persisted `tokenMode` against what the currently-running code
would produce (`hmac` when a provider is configured, `hex` otherwise). A
mismatch — which can only arise from a software-version upgrade of an
already-encrypted database whose indexes were built by pre-Gap-2 code, since
encryption itself cannot be toggled on an existing database
(`KmdbDatabase.open()` throws `cannotProvisionNonEmptyDatabase` on non-empty
databases) — triggers a purge of the stale-mode sub-namespaces (not merely a
`stale` marking; the entries are unreachable by the new scheme's writes and
reads, so leaving them in place would defeat this gap by keeping
plaintext-derivable tokens on disk indefinitely) followed by a lazy rebuild,
mirroring WI-1's model-identity invalidation for `VecIndexState`. `VecIndexState`
itself carries no `tokenMode` — `VecManager`'s `$$vec:{ns}:{field}` and
`$$vault:vec:idx:{sha256}` namespaces are keyed by document ID / chunk index,
never by an embedded term or value, so there is no hex-tokenised namespace
scheme for it to migrate away from.

#### 3. Secondary index namespace names embed indexed values (resolved for encrypted databases — Encryption confidentiality reconciliation, Gap 2)

Secondary indexes use the layout `$$index:{ns}:{field}:{token}`, which
embeds the **indexed field value** in the namespace name. As with FTS
namespaces (gap 2 above), namespace names are part of the SSTable key. This
is not document content per se, but the indexed values drawn from
documents — e.g. every distinct value of an indexed `status` or `email`
field — were, prior to Gap 2, visible in plaintext hex to anyone with
SSTable access.

**Resolved for encrypted databases**, identical fix and identical residual
limitations to gap 2 above — `{token}` becomes an HMAC-SHA256 token
(`EncryptionProvider.indexToken`, message domain-separated as
`"{ns}:{path}:" + hexEncodedValue`) when a provider is configured;
unencrypted databases remain a known, accepted limitation on plaintext hex.
One additional, index-specific consequence: `IndexWriter`'s hex encoding for
`int`/`double` values is deliberately sort-order-preserving (documented for
a *future* range-scan use — no current query path performs a range scan
over a secondary index, only equality lookup via `IndexReader`), but an HMAC
token is not order-preserving. This is a deferred limitation, not a
regression: range-scan support for encrypted secondary indexes does not
exist yet in either mode, so nothing that worked before stops working.

#### 4. `MetaStore` values are not encrypted (resolved — Encryption confidentiality reconciliation, Gap 3)

`MetaStore` previously bypassed `ValueCodec` entirely and wrote raw CBOR
directly to `_engine.put()`. For the `enc:blob` entry this remains
**intentional and required**: the blob is already protected by the wrapped
DEK, and decrypting any value requires first reading `enc:blob`, so it
cannot itself be encrypted (see _enc:blob Structure_) — `getEncryptionBlob`/
`putEncryptionBlob` call the engine directly, bypassing the general
`$meta` accessors entirely, so this exemption is enforced structurally, not
just by convention.

For **all other** `$meta` entries at the time — device ID, the namespace
registry, generation counters, the dirty flag, the tombstone-GC floor, and
index/FTS/Vec state — the previous lack of encryption was a
previously-undocumented gap: these values reveal **operational metadata**
(which namespaces exist, write activity via generation counters, device
identity, timing) but **not document content**.

> **Update (0.10.01 WI-11).** The tombstone-GC floor and index/FTS/Vec state
> have since moved out of `$meta` into local-only `$$gcstate`/`$$indexstate`/
> `$$ftsstate`/`$$vecstate` namespaces (SC-10, Q-D — see
> `docs/spec/12_sync.md`'s "`$meta` vs `$$` classification rule"). The
> `EncryptionEnvelope` wrapping this section describes was **preserved**
> across that move — these values are still encrypted when a provider is
> configured, just no longer under `$meta`, and now for local-disk-theft
> protection rather than cloud-provider protection (see the _Value-Level
> Encryption Coverage_ list above). Device ID, the namespace registry, and
> generation counters remain in `$meta` as described here.

**Resolved** by the Encryption confidentiality reconciliation plan's Phase 2
(`docs/roadmap/completed/0_08.md`, Gap 3): every general `$meta` accessor now routes
through `EncryptionEnvelope` when a provider is configured. This introduced
a database-level format-version marker gate at `KvStoreImpl.open()` (a
`$meta` write itself, so it must precede every other `$meta` read/write) to
safely distinguish a legacy pre-plan database (bare CBOR, no leading flag
byte) from a genuinely new or already-migrated one — see the _Bootstrap
Sequence_ section and the "Existing databases must be recreated" note below
for the resulting breaking on-disk format change.

#### 5. Vault `manifest.json` is plaintext (`originalName` resolved — Encryption confidentiality reconciliation, Gap 4)

Each vault blob is accompanied by a `manifest.json` on disk and in cloud
sync, containing `schemaVersion`, `sha256`, `size`, `crc32c`, `mediaType`,
`originalName`, `createdAt`, and (when encryption is active) `encrypted`.

**Resolved for `originalName`** by the Encryption confidentiality
reconciliation plan's Phase 3 (`docs/roadmap/completed/0_08.md`, Gap 4):
`originalName` is now encrypted in place when a database
`EncryptionProvider` is configured. `VaultStore.ingest` wraps it with
`EncryptionEnvelope` and base64-encodes the result before it is written
into `manifest.json` (keeping the manifest's JSON shape stable — the field
is still a JSON string, just ciphertext rather than plaintext);
`VaultStore.getManifest` is the sole decryption point and transparently
returns the plaintext name to every caller. The existing `encrypted` boolean
field governs both the blob ciphertext and this field together — a database
is either born encrypted or never encrypted, so the two are always set in
lockstep; there is no scenario where one is encrypted and the other is not.
This closes the `originalName` leak this gap originally documented. The
remaining plaintext surfaces below are **accepted, not defects** — see each
bullet's stated functional reason.

The following fields remain **intentionally plaintext**, each for a stated
functional reason rather than by omission:

- **`sha256`** — computed over the plaintext blob bytes (not ciphertext) so
  that content-addressed deduplication continues to work identically across
  encrypted and unencrypted devices, and so two devices holding the same
  logical content converge on the same address regardless of encryption
  state (documented in _Vault Encryption_ above).
- **`mediaType` and `size`** — read directly from `manifest.json` without
  decryption by sync routing and by consumers (e.g. vault search's extractor
  selection, `kmdb_cli`'s `export`/`dump` commands) that only need to know
  *what kind* and *how large* an object is, not its content or name. Forcing
  decryption to answer those questions would require every such consumer to
  hold the DEK, which is a materially larger change than this plan's scope.
- **`crc32c` and `createdAt`** — secondary identity/provenance metadata with
  no confidentiality value beyond what `sha256`/`size` already expose.

These are accepted, documented plaintext surfaces, not open defects — they
leak *metadata about* a stored object (its type, size, and content address)
but never its name or content.

#### 6. Vault `extract/` filesystem artifacts (resolved — WI-10)

Vault search (WI-3) writes three per-blob filesystem artifacts alongside each
encrypted blob's `extract/` subdirectory: `text.txt` (full extracted text),
`chunks_v1.json` (chunk byte-offset metadata), and `vectors_{modelId}_sq8.bin`
(SQ8-quantised embedding vectors, semantic mode only). No fourth
`extract_status.json` file is ever written — extraction status is persisted
solely to the `$$vault:extract:{sha256}` KV entry, whose _value_ is now
encrypted via `ValueCodec` at the `VaultSearchManager` call site (gap 1,
resolved — a distinct surface from the `extract/` files this gap covers).

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

#### 9. `kmdb_cli` cloud sync credentials are plaintext (resolved — CLI credential store)

`remote_config.dart` stores `AccessCredentials.toJson()` (Google Drive OAuth
tokens) as JSON under `local/` — a per-machine, non-synced, CLI-only
directory (see _Local Directory Layout_ in §03/§06). These credentials live
**entirely outside the database encryption boundary**: never synced, never
written into an SSTable, and not reachable from any
`EncryptionProvider`-protected code path, so there is no `enc:blob`/DEK
relationship to leverage even in principle. This was originally accepted as a
distinct, local-secret-at-rest surface out of scope for the Encryption
confidentiality reconciliation plan (Q7), naming a future CLI-hardening item
as the right place to close it.

That item shipped as the `kmdb_cli` credential store (§33): rather than
database-level encryption, the file and its containing `local/` directory are
now permission-hardened (POSIX: `chmod 700`/`600`, hard-refuse on read if
either has drifted looser — the OpenSSH/`gcloud` model) via
`CredentialStore`/`DirectoryCredentialStore`. This closes the "plaintext,
no protection at all" gap the file's contents (a live OAuth token) had before;
see §33 for the full design, including why directory-permission hardening was
chosen over OS-native keychain integration (deferred, see
`docs/roadmap/9_99.md`).

#### 10. `MetaStore.appendTombstoneFloorAdvance` writes unencrypted (accepted, dead code)

`getTombstoneFloor` decrypts via `EncryptionEnvelope.unwrap` (Encryption
confidentiality reconciliation, Gap 3), but its `WriteBatch`-based
counterpart, `appendTombstoneFloorAdvance`, still writes raw, unencrypted
bytes. This is deliberate, not an oversight: the method has zero production
call sites today — `LsmEngine._compactAll` calls the standalone
`setTombstoneFloor`, which does encrypt, directly. Wiring encryption into
unreachable code was judged premature. A doc comment on
`appendTombstoneFloorAdvance` (`packages/kmdb/lib/src/engine/kvstore/meta_store.dart`)
records this asymmetry so that whoever gives the method its first real
caller is warned to add encryption at that point — otherwise a future
encrypted-database read of a batch-written tombstone floor would silently
misparse. (Identified during Phase 2 QA of Encryption confidentiality
reconciliation, 2026-07-11; re-verified 2026-07-16 — still zero callers,
still documented. Closed out as will-not-fix in `docs/roadmap/0_09.md`'s
Housekeeping section — tracked here, not there.)

#### 11. `EncryptionProvider.indexToken`'s domain separator has a theoretical concatenation ambiguity (accepted, low risk)

FTS/index HMAC token domains are built as `"{ns}:{field}:" + term` /
`"{ns}:{path}:" + value` (Encryption confidentiality reconciliation, Gap 2);
the components are not escaped against an embedded literal `:`, so in
principle a collection namespace or FTS term containing a literal colon
could collide with a different `(ns, field, term)` triple that produces the
same concatenated string. Vault-FTS (fixed 64-hex `sha256` domain) and
secondary-index (hex-encoded final component) domains are structurally
immune; only the FTS `ns`/`field`/raw-term domain is theoretically exposed.
Documented as an acknowledged, deliberately-unfixed limitation in
`EncryptionProvider.indexToken`'s doc comment
(`packages/kmdb/lib/src/encryption/encryption_provider.dart`), since KMDB
namespace names are developer-controlled (not user input) and FTS terms are
post-tokenisation (unlikely to contain a raw `:`) — low practical risk.
Worth a proper escaping scheme (e.g. length-prefixing each component) if
this primitive is ever reused for a domain where either constraint doesn't
hold. (Identified during Phase 4 QA of Encryption confidentiality
reconciliation, 2026-07-13; re-verified 2026-07-16 — still accurate. Closed
out as will-not-fix in `docs/roadmap/0_09.md`'s Housekeeping section —
tracked here, not there.)

### Summary

Encryption gives a strong guarantee about **document value confidentiality**
against a cloud provider or a passphrase-less device thief, and — for
encrypted databases as of the Encryption confidentiality reconciliation
plan (`docs/roadmap/completed/0_08.md`) — about **index value and namespace-name
confidentiality** too: FTS/Vec/vault-search index values (gap 1), FTS and
secondary-index namespace tokens (gaps 2/3), `$meta` operational metadata
(gap 4), and vault manifest `originalName` (gap 5) are all encrypted or
HMAC-tokenised. It gives **no guarantee** about the metadata that remains:
document existence, filenames, blob `mediaType`/`size`/`crc32c`/`createdAt`,
SSTable/WAL structure, creation timestamps (via UUIDv7 keys), and — even on
an encrypted database — the residual statistical leakage the HMAC token
scheme does not close (term/value frequency, search-pattern/access
leakage, co-occurrence; see gap 2's residual-leakage list). Gap 6 (vault
`extract/` filesystem artifacts, including the full extracted plaintext in
`text.txt`) was the other content-leak gap in this category — it is
resolved by WI-10. Unencrypted databases claim none of these
properties and are unaffected by any of gaps 1–6.

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
