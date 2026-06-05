# Technical Proposal: Database Encryption

## 1. Overview

KMDB stores documents in immutable SSTables that are uploaded verbatim to
cloud storage as part of the sync protocol (§12). OS disk encryption and
cloud-provider transport encryption protect the local device and bytes in
flight, but they do not provide **end-to-end confidentiality**: the cloud
provider (or anyone with account access) can read the user's plaintext data.
This proposal defines an opt-in encryption subsystem that provides zero-knowledge
E2E confidentiality for both the document store and the vault (§24), requiring no
cryptographic expertise from the end user.

### Goals

- Protect document and vault content from a cloud provider, a compromised cloud
  account, or a shared/NAS sync folder — the threat that OS/transport encryption
  does not cover.
- Derive encryption keys from a user passphrase. No key files, no PGP/GPG, no
  manual key management.
- Provide a recovery path (generated recovery code) for forgotten passphrases.
- Work across all target platforms: macOS, Linux, Windows, iOS, Android, and web.
- Compose cleanly with the existing sync, compaction, and consolidation
  machinery without requiring changes to those subsystems.
- Be opt-in; the default is no encryption, consistent with KMDB's role as a
  library (not a vertically-integrated app).

### Non-goals (v1)

- Default-on encryption. See §2 for rationale.
- Encrypting secondary indexes, FTS indexes (`$fts:`), or vector indexes
  (`$vec:`). These are local-only and excluded from sync; OS disk encryption
  covers them.
- In-place migration of an existing plaintext database to encrypted (set-at-
  creation only in v1).
- Key rotation or DEK re-keying during compaction (deferred to a future proposal).
- Adding file-level encryption to WAL files. WAL values are already ciphertext
  by construction when encryption is enabled — the value pipeline encrypts before
  `KvStore.put`, so the WAL write receives ciphertext. What remains plaintext in
  WAL records are key metadata (UUIDv7, HLC timestamps), the same metadata that
  is plaintext in SSTable index blocks. Note: on mobile, OS-level WAL protection
  varies — iOS defaults to `NSFileProtectionCompleteUntilFirstUserAuthentication`
  (not re-encrypted on lock, only on power-off) and Android FBE protection
  depends on whether files land in CE vs. DE storage. Downstream apps on mobile
  should consider setting the appropriate data protection class on the database
  directory if key-metadata confidentiality on a locked-but-powered device is a
  requirement.
- Multi-user or shared-key scenarios.

---

## 2. Do We Need Encryption?

### 2.1 What the user already gets for free

- **OS disk encryption** (FileVault on macOS, BitLocker on Windows, LUKS on
  Linux, full-disk encryption on iOS/Android) protects the local database
  directory against a lost or stolen device. This is on-by-default on iOS,
  Android, and modern macOS; a checkbox on Windows and Linux.
- **Cloud transport and provider-at-rest encryption** protects bytes in transit
  and on the provider's servers.

### 2.2 What OS and cloud encryption do not cover

| Threat | OS disk crypto | Cloud provider crypto | App-level E2E |
| :-- | :-- | :-- | :-- |
| Lost/stolen device (OS crypto off, common on Linux/Windows) | ❌ | — | ✅ |
| Cloud provider reads your data (subpoena, breach, ML training) | — | ❌ (provider holds keys) | ✅ |
| Compromised cloud account (stolen password) | — | ❌ | ✅ |
| Sync folder on a shared NAS with broad permissions | — | — | ✅ |
| Another user/app on a shared machine | partial | — | ✅ |

The most material gap for KMDB specifically is the cloud-provider row. KMDB
uploads SSTable files verbatim to Google Drive, iCloud, and other adapters.
Without application-level encryption the user's entire dataset sits in
plaintext on a third-party server they do not control. Users who deliberately
choose a local-first database over a cloud-native product (Firestore, Notion)
are disproportionately privacy-conscious; a zero-knowledge sync option
addresses a real, if minority, demand.

### 2.3 Comparable systems

| System | Approach |
| :-- | :-- |
| Obsidian / LogSeq / Notion | No built-in at-rest encryption; rely on OS + transport |
| Google Firestore | Server-side encryption; provider holds keys. **Offline cache on the user's device is stored in plaintext.** |
| AnyType | Zero-knowledge E2E by default; BIP-39 recovery phrase |
| SQLCipher | Page-level AES-CBC from user passphrase (PBKDF2) |

AnyType is the local-first outlier that encrypts everywhere by default — but it
is a vertically-integrated app that owns the entire signup/onboarding UX. KMDB
is a library; its consumers span non-sensitive to privacy-critical use cases.

### 2.4 Recommendation

Implement encryption as an **opt-in feature**. When enabled it must be
**E2E** (encrypt before bytes leave the device). A half-measure that encrypts
locally but uploads plaintext would protect the wrong threat.

---

## 3. Encryption Granularity

Three granularities were evaluated against KMDB's immutable-SSTable / sync /
consolidation invariants.

### 3.1 Value-level encryption (recommended)

Encrypt the value bytes **after CBOR encoding and optional Zstd compression,
before `KvStore.put`** — extending the existing §5 value pipeline with one
additional stage and a corresponding flag byte:

```
KmdbCodec<T>.encode
  → CBOR encode
  → Zstd compress (optional, native only)
  → [compression flag byte]       ← existing
  → AES-256-GCM encrypt           ← new
  → [encryption flag byte]        ← new
  → KvStore.put
```

**What stays unchanged:** document and vault *keys* (UUIDv7 hex strings) remain
plaintext. The SSTable index block, Bloom filter, XXH64 checksums, key ordering,
range scans, the Manifest, the WAL, HWM files, and the consolidation lease are
all unaffected. The storage engine already treats values as opaque `Uint8List`
(§11), so it never needs to decrypt.

**Sync:** SSTables upload verbatim as today; their value payloads are ciphertext.
The consolidation coordinator operates on keys, HLCs, and sequence numbers only —
it never reads value contents (§12 merge iterator, tombstone-GC horizon). The
coordinator requires no key and no code changes.

**Vault:** encrypt blob bytes with the same DEK before writing to
`vault/blobs/.../blob`. The SHA-256 content address is computed over plaintext
(preserving dedup semantics) but the stored and uploaded blob is ciphertext.

**Per-value overhead:** 12-byte nonce + 16-byte GCM tag + 1 flag byte = 29 bytes.
Negligible relative to typical 1–10KB document sizes.

### 3.2 File-level encryption (rejected)

Encrypting entire `.sst` files at the storage adapter boundary is structurally
incompatible with the consolidation coordinator, which must read keys and HLCs
from every input SSTable. It would also encrypt the Bloom filter, index block, and
footer, defeating the table cache (§8) and forcing full-file decryption on every
open. No advantage over value-level; substantially larger cost.

### 3.3 Block-level encryption (rejected)

Encrypting 4KB data blocks (analogous to SQLCipher's per-page approach) has the
same fatal flaw as file-level: the merge iterator reads keys across blocks, so the
coordinator must hold the key and decrypt during consolidation. All of the
file-level objections apply at finer granularity with no compensating benefit for
an LSM.

### 3.4 Why value-level is the right fit

Value-level is the only granularity where the **DEK never has to leave the
originating device's trust boundary** during sync or consolidation. The cloud-facing
layer stays structurally dumb — the same property that motivated immutable
SSTables in the first place.

---

## 4. Key Management

### 4.1 Architecture overview

The hard problem in database encryption is not the cipher; it is key management
UX. The design separates two concerns: key derivation (done once per session)
and per-value encryption (done on every write).

```
User passphrase
  → Argon2id(salt=random 256-bit, m=64MB, t=3, p=1)
  → Key-Encryption-Key (KEK, 256-bit)
      → AES-GCM-unwrap ← Wrapped DEK  (stored in $meta + synced)
          ↓
      Data-Encryption-Key (DEK, 256-bit, held in memory / OS secure storage)
          → encrypts every value and every vault blob
```

Key points:

- **Random DEK with envelope encryption.** A random 256-bit DEK encrypts all
  data. The DEK is wrapped by a KEK derived from the passphrase. Passphrase
  changes only re-wrap the DEK — they do not re-encrypt the database.
- **Argon2id KDF.** Memory-hard (64 MB at the parameters above), so a weak
  passphrase resists brute-force against the cloud-stored wrapped key. The KDF
  runs once per session at unlock — per-value AES-GCM uses the cached DEK.
- **Random per-database salt.** Stored in `$meta` (non-secret); different
  databases produce different KEKs from the same passphrase.

### 4.2 Recovery code

Zero-knowledge means a forgotten passphrase cannot be recovered by KMDB or by
any sync provider. The mitigation is a **generated recovery code** presented at
database creation: a high-entropy random token (128 bits, displayed as a 24-word
BIP-39-compatible mnemonic or a 26-character Base32 string) that is a **second
independent wrapping** of the DEK.

```
Random 128-bit recovery entropy
  → HKDF-SHA256 → recovery-KEK (256-bit)
  → AES-GCM-wrap(DEK) → wrapped-DEK-recovery
      (stored alongside wrapped-DEK-passphrase in $meta)
```

If the user forgets their passphrase they can unlock with the recovery code, set
a new passphrase, and re-wrap the DEK under the new KEK. If *both* the passphrase
and the recovery code are lost, the data is permanently unrecoverable — this must
be surfaced loudly at setup (a downstream-app UX responsibility; KMDB provides
the primitive).

### 4.3 Session caching

After unlock, the unwrapped DEK is stored in OS secure storage so the user is not
prompted every session:

- **iOS / macOS:** Keychain (via `flutter_secure_storage`)
- **Android:** Keystore-backed EncryptedSharedPreferences
- **Windows:** DPAPI-backed credential store
- **Linux:** libsecret / GNOME Keyring
- **Web:** WebCrypto-wrapped `localStorage` — not hardware-backed and not portable
  across browsers. On web, **re-derive the DEK from the passphrase each
  session** rather than trusting browser storage. See §6.3 for web-specific
  considerations.

### 4.4 Wrapped DEK sync

The encryption metadata blob (Argon2id salt, wrapped-DEK-passphrase,
wrapped-DEK-recovery, KDF parameters) is stored in the `$meta` namespace and
syncs normally. A new device prompts for the passphrase (or recovery code),
unwraps the DEK, and can then decrypt all synced SSTables. This is the one new
synced artifact; it is safe to upload in plaintext because the DEK is wrapped.

---

## 5. Cipher and Library

### 5.1 Cipher: AES-256-GCM

AES-256-GCM is the recommended cipher:

- Authenticated encryption (AEAD) — integrity and confidentiality in one pass.
- Hardware-accelerated via AES-NI (Intel/AMD/ARM) and Web Crypto API (browsers).
- Well-understood, FIPS-approved, widely supported.
- Random 96-bit nonce per value; collision probability negligible at KMDB's scale
  (no practical bound on document count given 2^96 nonce space with random selection).

ChaCha20-Poly1305 is a strong alternative — faster in pure Dart and
constant-time without AES-NI — but AES-256-GCM's Web Crypto acceleration is
the deciding factor for web platform parity.

### 5.2 Library: `package:cryptography` + `cryptography_flutter`

`package:cryptography` (pub.dev, Apache-2.0) is the clear choice:

- Ships AES-GCM, ChaCha20-Poly1305, Argon2id, PBKDF2, HKDF — all required
  primitives.
- **Web:** delegates to the Web Crypto API (>500 MB/s AES). No FFI, no WASM,
  no native-asset hooks. Unlike `betto_zstd`, encryption works on web with no
  graceful-degradation gap.
- **Mobile:** sibling `cryptography_flutter` delegates to iOS/Android OS crypto
  for throughput.
- **Native desktop:** pure-Dart fallback (~20 MB/s AES-GCM); acceptable for
  document-scale writes.

`flutter_secure_storage` handles DEK caching in OS-native secure storage on all
platforms.

---

## 6. Platform Considerations

### 6.1 All platforms

The value pipeline extension (§3.1) is pure Dart and uses `package:cryptography`,
which has no FFI requirement. This is structurally different from Zstd
compression, which is native-only. **Encryption works on all platforms including
web without conditional exports or platform-specific build hooks.**

### 6.2 Native platforms (desktop and mobile)

`cryptography_flutter` provides hardware-accelerated AES-GCM on iOS and Android.
DEK is cached in OS secure storage via `flutter_secure_storage`. The Argon2id
unlock is ~300–500ms at the recommended parameters — acceptable for a one-time
session unlock.

### 6.3 Web platform

Web-specific constraints:

- `flutter_secure_storage` on web wraps `localStorage` with WebCrypto. This is
  not hardware-backed and is origin-scoped but not cross-tab secure. The DEK
  **must be re-derived from the passphrase each session** on web rather than
  stored. This means the user is prompted for their passphrase on every fresh
  page load.
- Argon2id in pure Dart on web takes 1–3 seconds (browser JS engine). This is
  acceptable for a session-unlock prompt; if it proves too slow, Argon2id
  parameters can be reduced for web only (with a corresponding note in the UX).
- AES-GCM via Web Crypto is fast (>500 MB/s); per-value encryption cost on web
  is dominated by JS/WASM overhead, not the cipher.

---

## 7. Vault Encryption

### 7.1 No compression step for vault blobs

Document values go through a compress-then-encrypt pipeline (CBOR → Zstd →
AES-GCM). Vault blobs are different: they are stored and uploaded as raw bytes
with no intermediate compression. This matters for the encryption pipeline
because there is no compression flag to compose with — the vault encrypt
pipeline is simply:

```
plaintext blob bytes → AES-256-GCM(DEK, nonce) → stored blob file
```

Cloud vendor APIs (Google Drive, iCloud, and equivalents) do **not** compress
file content in transit. They provide TLS for transport security but leave
content encoding to the caller. The existing Google Drive adapter (`kmdb_google_drive`)
uses the resumable upload protocol and sends raw bytes with no
`Content-Encoding` header. This means uncompressed vault blobs are transferred
at full size. For many vault payloads (images, video, audio) this is fine
because those formats are already compressed. For text-heavy or compressible
blobs it represents a missed opportunity. Optional Zstd compression for vault
blobs before encryption is deferred to future work (see §12).

### 7.2 Content-addressing invariant

Vault blobs (§24) must be encrypted with the same DEK. The content-addressing
invariant requires care:

- **SHA-256 is computed over plaintext** — preserving cross-device dedup
  semantics. Two devices that ingest the same file get the same content address
  and can share the blob.
- **The stored and uploaded blob is ciphertext** — a per-blob nonce (96 bits,
  random) is prepended to the ciphertext in the `blob` file. The GCM tag is
  appended. The `manifest.json` gains an `encrypted: true` flag.
- **Deterministic vs. non-deterministic ciphertext:** with random nonces, two
  encryptions of the same plaintext produce different ciphertexts. This means
  two devices that ingest the same file will upload different ciphertext blobs
  even though the content address is the same. The vault's dedup is by content
  address (§24), so they will not overwrite each other on the sync folder — both
  copies exist on the provider. This is a minor space waste; the alternative
  (deterministic nonces) introduces nonce-reuse hazards and is not recommended.
  A future refinement could use a DEK-derived, content-address-keyed nonce
  (`HKDF(DEK, sha256)`) to make ciphertext deterministic across devices while
  remaining safe, but this is deferred.

Vault metadata files (`manifest.json`, `tombstone.json`) store only the
SHA-256 address and reference counts — no user content. These are kept
plaintext in v1. Future work could encrypt them if metadata confidentiality
becomes a requirement.

The `extract/` subdirectory (vault search artifacts — §vault_search proposal)
is local-only and never synced. It may be stored in plaintext on local disk
(OS disk encryption covers it) or can be encrypted as a follow-on; v1 leaves
it plaintext.

---

## 8. API Design

### 8.1 `EncryptionConfig`

Encryption is configured at `KmdbDatabase.open()` time:

```dart
/// Controls database-at-rest encryption.
///
/// When provided, all document values and vault blobs are encrypted with
/// AES-256-GCM using a DEK derived from [passphrase] via Argon2id before
/// storage or sync upload.
final class EncryptionConfig {
  /// Creates a config for an existing encrypted database.
  ///
  /// Supply either [passphrase] or [recoveryCode] to unlock; the other may
  /// be null. Throws [EncryptionError] if neither matches the stored wrapped
  /// DEK.
  const EncryptionConfig({
    this.passphrase,
    this.recoveryCode,
  }) : assert(passphrase != null || recoveryCode != null);

  final String? passphrase;
  final String? recoveryCode;

  /// Creates a config for a new encrypted database.
  ///
  /// [passphrase] is used to wrap the newly generated DEK. The returned
  /// [EncryptionSetupResult] contains the recovery code that must be
  /// presented to the user.
  static Future<(EncryptionConfig, EncryptionSetupResult)> create({
    required String passphrase,
  });
}

final class EncryptionSetupResult {
  /// The recovery code mnemonic. Must be shown to the user and stored safely.
  final String recoveryCode;
}
```

Usage at database open:

```dart
// New database
final (config, setup) = await EncryptionConfig.create(passphrase: 'my phrase');
showRecoveryCode(setup.recoveryCode); // downstream app UX responsibility
final db = await KmdbDatabase.open(path: '/path/to/db', encryption: config);

// Existing database
final db = await KmdbDatabase.open(
  path: '/path/to/db',
  encryption: EncryptionConfig(passphrase: 'my phrase'),
);

// Recovery
final db = await KmdbDatabase.open(
  path: '/path/to/db',
  encryption: EncryptionConfig(recoveryCode: 'word1 word2 ... word24'),
);
```

A database opened without an `EncryptionConfig` that has encrypted values will
throw `EncryptionError.databaseIsEncrypted`. A database opened with an
`EncryptionConfig` that has no encrypted values is an error
(`EncryptionError.databaseIsNotEncrypted`). Mixing encrypted and plaintext
values in the same database is not supported.

### 8.2 `ValueCodec` pipeline integration

The encryption stage is a transparent transform applied at the `KvStore`
boundary inside `ValueCodec`. A `KvStoreConfig` gains an `encryptionProvider`
field (type `EncryptionProvider?`), injected at open time. The `EncryptionProvider`
wraps a cached in-memory DEK:

```dart
abstract interface class EncryptionProvider {
  Uint8List encrypt(Uint8List plaintext);
  Uint8List decrypt(Uint8List ciphertext);
}
```

The encryption flag byte (value `0x02`) is appended to the value after
encryption, parallel to the compression flag (`0x01`). Unrecognised flag bytes
are rejected with an error (consistent with §5 compression handling). A value
may carry both compression and encryption flags (compress-then-encrypt is the
correct order, already reflected in §3.1).

### 8.3 CLI support

The `kmdb` CLI (`kmdb_cli`) gains:

- `--passphrase` / `--recovery-code` flags on all subcommands that open a
  database, or prompts interactively if neither is supplied and the database is
  encrypted.
- `kmdb init --encrypted` — creates a new database with encryption enabled,
  prints the recovery code.
- `kmdb encryption change-passphrase` — re-wraps the DEK under a new passphrase.

---

## 9. App Developer Responsibilities

KMDB provides the cryptographic primitives — key derivation, value encryption,
DEK session management, and recovery-code generation. Integrating KMDB encryption
correctly requires app developers to fulfil responsibilities outside the library
boundary. This section defines that split and the per-platform requirements for
each security level.

### 9.1 Shared Responsibility

| Responsibility | KMDB | App developer |
| :-- | :-- | :-- |
| Value and vault blob encryption / decryption | ✅ | — |
| Argon2id key derivation and DEK wrapping | ✅ | — |
| DEK caching via `flutter_secure_storage` | ✅ | — |
| Wrapped DEK and salt stored and synced in `$meta` | ✅ | — |
| Passphrase entry UI | — | ✅ |
| Recovery code display and user acknowledgement | — | ✅ |
| Passphrase strength guidance or enforcement | — | ✅ |
| Database directory data protection class (iOS / Android) | — | ✅ |
| OS-level disk encryption guidance (desktop) | — | ✅ |

### 9.2 Security Levels

Three levels are useful when choosing a configuration.

**Level 1 — Cloud confidentiality**
Protects against cloud provider access, compromised cloud accounts, and shared
sync folders. This is the primary use case for KMDB encryption.

- Enable KMDB encryption at `KmdbDatabase.open()`.
- No additional platform configuration required.
- Sufficient on all platforms including web.

**Level 2 — Level 1 + local protection on powered-off device**
Adds protection if the physical device is powered off (seized laptop, lost phone).
OS disk encryption provides this; it is on by default on iOS and Android.

- Level 1 requirements, plus:
- **iOS / Android:** no additional app configuration — full-disk / file-based
  encryption is on by default.
- **Desktop:** advise users to enable OS disk encryption (FileVault on macOS,
  BitLocker on Windows, LUKS on Linux).

**Level 3 — Level 2 + local protection on a locked-but-powered device**
Adds protection if the device is on but the screen is locked. This is a more
demanding requirement; it affects app architecture because file access must be
suspended while the device is locked.

- Level 2 requirements, plus:
- **iOS:** set `NSFileProtectionComplete` on the database directory (§9.3).
- **Android:** back the DEK cache with a user-authentication-required Keystore
  key (§9.4).

### 9.3 iOS Data Protection Class

The default app sandbox data protection class —
`NSFileProtectionCompleteUntilFirstUserAuthentication` — leaves files accessible
after the first unlock and does not re-encrypt them when the screen locks. For
Level 3, set `NSFileProtectionComplete` on the database directory before
`KmdbDatabase.open()` creates any files:

```swift
try FileManager.default.setAttributes(
    [.protectionKey: FileProtectionType.complete],
    ofItemAtPath: dbDirectoryPath
)
```

**Trade-off:** With `NSFileProtectionComplete`, any file I/O while the device is
locked throws an error. Apps that perform background work (push-driven sync,
`BGAppRefreshTask`) must handle
`UIApplicationDelegate.applicationProtectedDataWillBecomeUnavailable` and
`applicationProtectedDataDidBecomeAvailable` to close and re-open the database
around lock/unlock transitions. For most apps Level 2 (the default class) is the
right choice.

### 9.4 Android File-Based Encryption

Android 7.0+ uses File-Based Encryption. Files in `Context.getFilesDir()` land
in CE (Credential-Encrypted) storage by default — inaccessible until the user
authenticates after a reboot. This satisfies Level 2.

For Level 3:

- Back the DEK cache with an `AndroidKeyStore` key with
  `setUserAuthenticationRequired(true)` and a short authentication validity
  window (or a per-use biometric challenge). `flutter_secure_storage` exposes
  this through its `AndroidOptions` configuration.
- Ensure the database directory is **not** created via
  `createDeviceProtectedStorageContext()` (DE storage is accessible before user
  auth and must not hold sensitive data).

**Trade-off:** Once the authentication window expires the DEK is inaccessible
until the user re-authenticates. Background operations that attempt to read or
write encrypted values will fail; the app is responsible for prompting
biometrics or a PIN before resuming.

### 9.5 Web Platform

`flutter_secure_storage` on web wraps `localStorage` with WebCrypto — it is
origin-scoped but not hardware-backed and is not suitable as a long-term DEK
store. Apps must **re-derive the DEK from the passphrase on each page load**.
Implications for the app developer:

- Prompt for the passphrase at session start; the Argon2id derivation takes
  1–3 seconds in a browser JS engine (see open question 3 for parameter
  tuning).
- Consider a session timeout: close the database and discard the in-memory DEK
  after a period of inactivity, requiring re-entry of the passphrase.
- Web provides Level 1 security only — local-at-rest protection relies entirely
  on the OS and browser sandbox.

### 9.6 Recovery Code UX Requirements

`EncryptionConfig.create()` returns a recovery code that KMDB generates but does
not store. App developers must:

1. Display the recovery code before the database is considered fully open — block
   the setup flow until the user explicitly acknowledges it.
2. Clearly communicate that losing both the passphrase and the recovery code
   makes data permanently unrecoverable.
3. Provide a path for users to view or reset the recovery code from app settings
   after initial setup.

KMDB does not enforce these requirements in code.

### 9.7 Passphrase Strength

KMDB does not validate or score passphrase strength. Argon2id at the recommended
parameters significantly raises the cost of brute-force attacks, but it does not
eliminate risk for very weak passphrases. Apps should display a passphrase
strength indicator (a zxcvbn-style estimate is sufficient) and consider enforcing
a minimum entropy threshold.

---

## 10. Sync Implications

Value-level encryption has minimal sync impact by design:

- **SSTables upload unchanged.** Files are structurally identical; value
  payloads are opaque ciphertext. Google Drive, iCloud, and future adapters
  need no changes.
- **Consolidation coordinator: untouched.** It operates on filenames, HLCs, key
  ordering, and the lease file — never value contents.
- **HWM files and `.consolidation-lease`: untouched** — contain no user data.
- **`$meta` namespace syncs the wrapped DEK.** A new device is prompted for
  the passphrase, unwraps the DEK from the `$meta` SSTable it receives, and can
  immediately decrypt all other SSTables.
- **System namespaces stay local and plaintext.** `$index:`, `$fts:`, `$vec:`,
  `$cache:` are excluded from sync (§12) and rebuilt locally; they are not
  encrypted in v1. Secondary indexes store indexed values inside their keys on
  local disk — this is a **documented local-only information leak** covered by
  OS disk encryption. The cloud confidentiality guarantee applies to synced
  document values and vault blobs only.

---

## 11. Open Questions

1. **Vault nonce determinism (priority: high).** Two devices encrypting the
   same plaintext blob produce different ciphertexts with random nonces, resulting
   in duplicate ciphertext blobs on the sync folder. Evaluate whether
   `HKDF(DEK, sha256_of_plaintext)` as a deterministic nonce is safe and
   desirable, or whether the minor space duplication is acceptable in v1.

2. **Cipher choice (low priority, easy to defer).** AES-256-GCM vs
   ChaCha20-Poly1305. AES-GCM recommended (Web Crypto acceleration); confirm
   `cryptography_flutter` AES-GCM throughput on iOS/Android is acceptable before
   finalising.

3. **Argon2id parameters for web (medium).** At m=64MB/t=3/p=1, Argon2id may
   take 1–3s in a browser JS engine. Determine acceptable web parameters, or
   whether a reduced-strength profile (m=16MB?) is needed with a clear UX
   disclosure. An alternative is to use a WebAssembly Argon2id implementation.

4. **`PlatformIdStore` interface alignment (medium).** The roadmap
   (`docs/roadmap/0_07.md`) pairs encryption with a `PlatformIdStore` abstraction
   backed by `$meta`. Determine whether the wrapped DEK and the device ID should
   share this secure-storage abstraction, and whether `PlatformIdStore` should be
   designed alongside this work or independently.

5. **Index confidentiality (design decision).** Secondary indexes store indexed
   field values in their keys on local disk. For deployments where local index
   confidentiality matters (not just cloud), this is an information leak. Options:
   (a) accept it and document it (recommended for v1); (b) encrypt index key
   payloads at the cost of range-scan capability. A clear design decision must be
   recorded in the plan.

6. **Encryption flag byte position (low priority).** Does the encryption flag
   extend the existing §5 flag byte (combining compression + encryption into a
   bitmask), or is it a second flag byte? A bitmask is more compact; a second
   byte is easier to evolve independently. Needs resolution before implementation.

7. **Passphrase strength guidance (UX).** KMDB is a library — downstream apps
   are responsible for the passphrase entry UX. The plan should define whether
   KMDB provides a `PasswordStrength` utility or leaves strength assessment
   entirely to the caller.

8. **In-place migration (deferred).** Encrypting an existing plaintext database
   requires rewriting all SSTable values via a full compaction pass. Deferred to
   a future proposal; v1 is set-at-creation only.

9. **Key rotation (deferred).** Full DEK rotation (re-encrypting all values
   during compaction) is out of scope for v1. Passphrase changes re-wrap the DEK
   cheaply (envelope encryption); the DEK itself does not change.

10. **`$meta` namespace bootstrapping.** The wrapped DEK is stored in `$meta`,
    but reading `$meta` requires opening the database. The bootstrap sequence
    (read un-encrypted `$meta` to get the wrapped DEK, then decrypt remaining
    values) must be defined precisely in the plan.

---

## 12. Future Work

- **In-place migration** — `kmdb encrypt` CLI command that re-encrypts all
  values in a compaction pass; see open question 8.
- **Key rotation** — rotate the DEK under compaction; all existing SSTables are
  re-encrypted during the next compaction cycle.
- **Index confidentiality** — encrypted secondary index keys using
  order-preserving or property-preserving encryption, or switching to a
  full-scan model for encrypted collections.
- **Multi-unlocker support** — allow multiple wrapped-DEK entries (e.g. device
  PIN + recovery code + hardware key) without changing the DEK.
- **Deterministic vault nonces** — `HKDF(DEK, sha256)` nonce to eliminate
  ciphertext duplication across devices for the same plaintext blob.
- **Metadata encryption** — encrypt vault `manifest.json` and `$meta` system
  keys if metadata confidentiality (key counts, timestamps) becomes a
  requirement.
- **Vault blob compression** — apply optional Zstd compression to vault blobs
  before encryption (compress-then-encrypt, consistent with the document value
  pipeline). Cloud vendor APIs do not compress file payloads in transit, so
  compressible blobs (plain text, JSON, SVG) are currently transferred and
  stored at full size. This is a pure addition to the vault ingest path and
  does not affect the encryption design.

---

## 13. References

- [§5 — Value Encoding](../spec/05_value_encoding.md)
- [§6 — Storage Engine](../spec/06_storage_engine.md)
- [§8 — SSTable Format](../spec/08_sstable.md)
- [§11 — KvStore Interface](../spec/11_kv_store.md)
- [§12 — Sync Protocol](../spec/12_sync.md)
- [§24 — Vault](../spec/24_vault.md)
- [Roadmap 0.07](../roadmap/0_07.md)
- [AnyType data security](https://doc.anytype.io/anytype-docs/advanced/data-and-security/how-we-keep-your-data-safe)
- [SQLCipher design](https://www.zetetic.net/sqlcipher/design/)
- [`package:cryptography`](https://pub.dev/packages/cryptography)
- [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage)
