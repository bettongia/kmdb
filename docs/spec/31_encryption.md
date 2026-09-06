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
    ↓  AesGcmEncryptionProvider.encrypt(aad: context.toAad())  (if encryption is active)
[0x01 nonce(12B) ciphertext tag(16B)]
    ↓  (or, without encryption)
[0x00 CompressionFlag CBOR payload]
SSTable slot value
```

`context` is a required `ValueContext` — see "Associated Data (AAD Binding)"
below.

## Associated Data (AAD Binding)

**Problem this closes (0.10.01 WI-3 / finding E-2).** Before this binding,
`AesGcmEncryptionProvider` encrypted with no associated data: a ciphertext
authenticated only *itself*, never *where it belonged*. An adversary who can
write SSTables (S-1 confirmed this is practical for a peer with sync-folder
access) could:

- **Relocate** a valid encrypted value from document A to document B — it
  decrypted cleanly and the GCM tag verified, because the tag never covered
  the key.
- **Transplant** values across namespaces or collections.

**The fix.** Every AES-GCM encrypt/decrypt call now takes a required `aad`
parameter (`EncryptionProvider.encrypt`/`decrypt`), computed by a `ValueContext`
that every `ValueCodec.encode`/`decode` and `EncryptionEnvelope.wrap`/`unwrap`
call site must supply:

```
AAD = domainByte(0x01) ‖ lenPrefixed(namespace) ‖ lenPrefixed(key)
```

Both `namespace` and `key` are UTF-8 encoded, each prefixed with its own
big-endian 4-byte length (not the 1-byte length-prefix style used elsewhere in
the engine — AAD keys are not all subject to that 255-byte cap, e.g. `extract/`
artifact paths). Length-prefixing — not bare concatenation — is essential:
without it, `("ab", "c")` and `("a", "bc")` would produce identical AAD bytes,
letting a value bound to one `(namespace, key)` pair authenticate under a
different, colliding pair. The leading `0x01` domain byte is cheap insurance so
a future AAD-composition change cannot be silently confused with this one.

For any value that is a real KvStore `(namespace, key)` entry — collection
documents, `$ver:` history entries, `$$fts:`/`$$vec:`/`$$index:` entries, vault
ref-count entries — the context is constructed directly:
`ValueContext(namespace, key)`. Because the write site and the read site
always address the same KvStore entry at the same coordinates, the AAD matches
automatically: neither side has to reconstruct anything, and there is no way
for the two to drift apart.

### Non-KvStore values

A handful of encrypted-at-rest values are **not** KvStore entries at all —
whole files written by a `StorageAdapter`, or a field inside such a file. For
these, `ValueContext` provides named constructors that single-source one
fixed, AAD-only namespace literal each (never a real KvStore namespace):

| Constructor | Key bound | Used for |
| :---------- | :-------- | :------- |
| `ValueContext.meta(name)` | symbolic name | `$meta` raw-by-name entries and `$$…state` store symbolic names (generation counters, dirty flag, tombstone GC floor, namespace registry, schema/index definitions) |
| `ValueContext.vaultBlob(sha256)` | SHA-256 address | Vault blob bytes (adapter files, not KvStore entries) — blobs are content-addressed/deduplicated, so no single document key owns one |
| `ValueContext.vaultExtract(path)` | file path | `extract/` artifact files (`text.txt`, `chunks_v1.json`, `vectors_{modelId}_sq8.bin`) — local-only and regenerable, bound anyway for uniformity |
| `ValueContext.vaultManifestName(sha256)` | SHA-256 address | The vault manifest's `originalName` field — **a distinct namespace literal from `vaultBlob`**, so the two ciphertexts for the same SHA-256 cannot be swapped |
| `ValueContext.vaultCorpus(ns, key)` | scan-cursor `(ns, key)` | The vault search corpus-sentinel entry — pure sugar over the base constructor, not a new literal (the corpus sentinel *is* a real KvStore entry) |

**Vault blobs get defense-in-depth, not a replacement.** The AAD binding
authenticates *before* decrypt (a relocated blob ciphertext fails GCM
authentication outright); the pre-existing post-decrypt content→address check
(`VaultStore.getBytes`, S-4) verifies content integrity independently, after
decryption succeeds. Both checks run; neither supersedes the other.

**Why the manifest name needs its own literal.** The vault manifest's
`originalName` field and the blob's bytes are two different encrypted values
that happen to share a SHA-256 address. If `vaultManifestName` reused
`vaultBlob`'s namespace literal, the two AADs would be byte-identical for the
same SHA-256, permitting an attacker to swap the two ciphertexts — an AAD
collision that would defeat the whole point of binding. A distinct literal
makes the two domains non-interchangeable no matter what SHA-256 they share.

### Scope: location, not freshness

The AAD binds **where** a value belongs (namespace + key), not **when** it was
written (HLC / version). This is a deliberate, resolved scope decision, not an
oversight:

- The authoritative write-HLC is assigned by the LSM engine at commit time,
  strictly *below* the query-layer encryption call — it is not available yet
  when the AAD would need it. Binding it is a layering impossibility, not a
  cost trade-off.
- A `$ver:` history entry's real storage namespace (`$ver:{ns}`) already
  differs from the live document's namespace (`{ns}`), so a version-history
  ciphertext transplanted into the live slot at the same key still fails
  authentication — no separate `recordType` field is needed.

Consequently, this binding **fixes relocation and cross-namespace
transplant** (a ciphertext moved to a different document key or a different
namespace/collection now fails GCM authentication) but does **not** detect
**rollback/replay** — re-placing an *older* ciphertext of the *same* document
back at the *same* key with a newer HLC authenticates just fine, because
namespace+key are unchanged. Rollback detection requires binding *freshness*,
which is only reachable at a layer that authenticates the writer and carries
monotonic device state — that is out of scope here and deferred to a future
sync-authentication work item. It does **not** protect against a peer that
legitimately holds the DEK (the threat model throughout this document is a
peer with sync-folder write access but not the DEK — see "Threat Model &
Confidentiality Boundaries" below); a legitimate DEK holder can always produce
validly-authenticating ciphertext for any `(namespace, key)` it chooses.

### Out of scope: the DEK-wrap envelope

The DEK wrap in `key_derivation.dart` (`wrapDek`/`unwrapDek`) uses `AesGcm`
directly and is **not** threaded through `ValueContext`/`aad`. The wrapped DEK
is keyed by the passphrase- or recovery-derived KEK, and it is not relocatable
in a way that makes a victim decrypt *authentic-looking* data — a wrong KEK
simply fails to unwrap. This is a deliberate exclusion, not an oversight.

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
`EncryptionEnvelope`/`ValueCodec`. Four-way discrimination (marker absence
alone is not sufficient — a brand-new database also has no marker until this
gate writes one):

1. **Looks fresh** (`CrashRecovery`'s `isNewDatabase`, or `$meta` scans as
   completely empty even if `CURRENT` exists — the widened check needed for
   `fsyncOnWrite: false` test configs where a crash can leave `CURRENT`
   durable but every `$meta` write lost) → write the marker
   (`kCurrentFormatVersion`, currently `2`) and proceed normally. This is the
   only path a brand-new database takes.
2. **Marker present and current** → proceed normally. This is the steady
   state for every database opened after this plan landed.
3. **Marker absent and the database is not empty** → the database predates
   the Encryption confidentiality reconciliation plan's `$meta` framing
   entirely (format version was never introduced). Throw
   `LegacyDatabaseFormatException` — a clean, explicit failure (not a silent
   misparse of a legacy value as encrypted garbage).
4. **Marker present but `< kCurrentFormatVersion`** (0.10.01 WI-3 / finding
   E-2) — the marker exists (e.g. `1`), but this build requires a newer
   format (`2`, the AAD-binding change above). Throw
   `LegacyDatabaseFormatException` with `foundVersion`/`currentVersion` set,
   producing a message distinct from case 3's marker-absent message. Before
   this branch existed, `KvStoreImpl.open()` only ever checked
   `formatVersion == null`, so a non-null-but-stale marker would have
   silently "fallen through" as accepted — every encrypted value in such a
   database would then fail GCM authentication the moment it was read with a
   non-empty AAD, indistinguishable from tampering, instead of failing
   loudly and explicitly at `open()`.

**There is no migration path for either legacy case, consistent with the
original Phase 12 encryption precedent (no in-place migration for encryption
either): a database created before the relevant plan landed must be
recreated.** Case 3 applies to every pre-Encryption-confidentiality-
reconciliation database, encrypted or not, since that format break is in the
general `$meta` framing, not specifically in encryption. Case 4 applies to
every database written between that plan and 0.10.01 WI-3 (format version
`1`), since the AAD-binding change is itself a breaking change to what
AES-GCM ciphertext looks like for the same plaintext. See
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

## Unlock Policy

**Closes SC-1** (2026-07-18 release-readiness review). Prior to 0.10.01 WI-5,
`KmdbDatabase.open()`'s unlock path checked an in-memory `DekCache` *before*
verifying credentials — if the cache was warm (the recommended mobile
configuration, via `FlutterSecureDekCache`), the cached DEK was returned
unconditionally, with the supplied passphrase never checked at all. Any
string — including a deliberately wrong one — opened the database as long as
the cache was warm. This silently defeated the coerced-unlock posture the
passphrase exists for ("I'll unlock my phone, but not give you the app
passphrase"). **The `DekCache` interface has been removed entirely**, not
patched: there is no code path left that can return a DEK without an
authenticated unwrap.

Every unlock — passphrase, recovery code, or biometric — is now an
**authenticated unwrap** of one of three wrapped copies of the DEK. A wrong
credential is always rejected, regardless of any prior successful unlock on
the same process or device.

### KEKSource

`EncryptionConfig` selects one of three `KEKSource` variants:

| Constructor                            | KEKSource                | Unwraps                                                       |
| :-------------------------------------- | :------------------------ | :-------------------------------------------------------------- |
| `EncryptionConfig(passphrase: ...)`     | `KEKSource.passphrase`    | `enc:blob.wdekP` via Argon2id                                   |
| `EncryptionConfig(recoveryCode: ...)`   | `KEKSource.recoveryCode`  | `enc:blob.wdekR` via HKDF                                       |
| `EncryptionConfig.biometric(provider)`  | `KEKSource.biometric`     | the per-device local biometric wrap (below), via a KEK from `provider.obtainKek()` |

`KmdbDatabase.open()`'s bootstrap (see _Bootstrap Sequence_ above) branches on
`kekSource` for State 5 (unlock): each branch is an independent authenticated
unwrap, and none can return a DEK without the unwrap succeeding.

### The Biometric Wrap — Per-Device Local State, Not `enc:blob`

The passphrase- and recovery-wrapped DEK copies (`wdekP`/`wdekR`) live in the
synced `enc:blob`, because their KEKs derive from user-held secrets that are
identical on every device. The **biometric KEK is device-bound** — a
platform-secured key (Secure Enclave / Keystore / Credential Manager) that
does not exist, and could not be meaningfully used, on any other device. A
third `wrappedDekBiometric` entry therefore lives in **per-device local
state**, never in `enc:blob`:

- Storage: a `SecretStore` (core interface — `packages/kmdb/lib/src/secret/
  secret_store.dart`; §33 documents `kmdb_cli`'s `DirectorySecretStore`
  implementation) supplied to `KmdbDatabase.open(secretStore:)`, defaulting
  to `InMemorySecretStore` — mirroring the historical default-to-in-memory
  pattern for encryption itself.
- Key: `dbScopedSecretKey(dbDir, 'dek.wrap.biometric')`.
- Alongside it, the same store holds `dbScopedSecretKey(dbDir,
  'passphrase.lastused')` — an ISO-8601 timestamp of the most recent
  successful passphrase or recovery-code unlock, used by _Re-authentication
  Policy_ below.

Putting either value in the synced `enc:blob` would (a) be useless on every
other device, (b) leak per-device biometric-enrolment state across the sync
set, and (c) reopen the exact `$meta`-LWW-resurrection hazard that the
0.10.01 WI-11/WI-13/WI-14 device-local-state moves (see gap 4's update notes
above, and `docs/spec/12_sync.md`'s "`$meta` vs `$$` classification rule")
spent that whole track closing: a peer's plain last-write-wins on a shared
field can move it *backwards* and resurrect stale state.

### Enrolment and Lock

```dart
// Enrol biometric unlock from an already-unlocked session:
await db.enableBiometricUnlock(myBiometricKekProvider);

// Disable it (a subsequent biometric open is refused; passphrase required):
await db.disableBiometricUnlock();

// Discard the in-memory DEK — the instance is unusable until a fresh open():
db.lock();
```

`enableBiometricUnlock(BiometricKekProvider)` requires the database to be
currently unlocked (an `AesGcmEncryptionProvider`, not `null` and not
`lock()`ed): it calls `provider.obtainKek()`, wraps the live DEK under the
returned KEK, and writes the wrap to `SecretStore`. `disableBiometricUnlock()`
deletes it — a no-op if biometric unlock was never enrolled.

`BiometricKekProvider.obtainKek()` must be **idempotent get-or-create per
db-scoped identity**: it creates the underlying platform-secured KEK on first
use (enrolment) and returns the *same* KEK on every subsequent call (unlock).
If it generated a fresh KEK on every call, enrolment and unlock would derive
different keys and `unwrapDek` would fail on every biometric open.
Enrolment-invalidation (e.g. a new fingerprint enrolled under
`accessControlFlags: biometryCurrentSet`) destroying the underlying platform
item is what gives "biometric auto-disables, passphrase required to
reconfigure" for free — no explicit invalidation handling is needed in a
provider implementation.

`lock()` discards the DEK in place — `EncryptionProvider.lock()` zeroes the
DEK bytes and gates further `encrypt`/`decrypt`/`indexToken` calls behind
`EncryptionErrorCode.databaseLocked`. There is no in-place unlock — the
caller must discard the instance and call `KmdbDatabase.open()` again for a
fresh, authenticated unwrap. **Releasing a locked instance:** call
`close(flush: false)`, not the default `flush: true` — a flush that triggers
compaction reads the `$meta` namespace listing, which is encrypted the same
as any other value, and that read throws `databaseLocked` on a locked
provider. No durability is lost: anything written before `lock()` is already
WAL-fsynced and replays on the next `open()` regardless of whether it was
flushed to an SSTable.

### Re-authentication Policy (`ReauthPolicy`)

Biometric unlock is a **data-loss control**, not primarily a hardening
measure: a user who never re-enters their passphrase and then hits a
biometric invalidation (new fingerprint, OS reinstall, device migration) has
effectively lost the database — nothing else proves they still know the
passphrase. `ReauthPolicy` forces periodic passphrase re-entry to keep that
knowledge fresh, and secondarily blunts (does not solve — see _Limitations_
below) the coerced-unlock case.

| Variant                                              | Behaviour                                                                                                                                                                                     |
| :----------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ReauthPolicy.interval(Duration)` (default: 14 days)  | Biometric unlock is permitted only while the passphrase/recovery-code was used within `interval`. A missing timestamp (never recorded) is treated as **lapsed** — fail closed, never silently permitted. |
| `ReauthPolicy.alwaysRequirePassphrase()`              | Biometric unlock is never permitted — the coercion case, handled bluntly.                                                                                                                    |
| `ReauthPolicy.headlessSession()`                      | Suppresses the check entirely — the explicit, documented opt-out for headless/server deployments (session = process lifetime; no timer, no periodic prompt; restarting the process is the only "re-auth" event). |

Enforced inside `KmdbDatabase.open()`'s `KEKSource.biometric` branch: an
absent wrap **or** a policy-refused timestamp both throw
`EncryptionError.biometricUnavailable` (fail-closed) — never a silent
fall-through to another unlock path. `EncryptionConfig.reauthPolicy` carries
the policy; it has no effect on passphrase/recovery-code configs (the
interval only ever gates the biometric shortcut).

### Platform Support

See §19's "Platform feature matrix" for the summary row. `kmdb_flutter`'s
`FlutterBiometricKekProvider` is the reference `BiometricKekProvider`
implementation:

| Platform        | Biometric gating | Mechanism                                                                                                                                                                    |
| :--------------- | :----------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| iOS / macOS      | ✓                  | `flutter_secure_storage` `accessControlFlags: [AccessControlFlag.biometryCurrentSet]`, `KeychainAccessibility.first_unlock_this_device` (never synced to iCloud Keychain)     |
| Android          | ✓                  | `AndroidOptions.biometric(enforceBiometrics: true, biometricType: AndroidBiometricType.strongBiometricOnly)`                                                                |
| Windows / Linux  | ✗                  | `flutter_secure_storage` has no biometric-gating option on either platform — the KEK is stored securely (DPAPI / platform keyring) but reading it does **not** prompt for authentication; gated only by OS login. The passphrase path is recommended here. |
| Web              | ✗ (deferred)       | No `BiometricKekProvider` implementation ships for web — a WebAuthn-PRF-backed KEK is a documented follow-up (see the WI-5 plan's non-goals), not yet built.                |

Server/headless deployments do not need real biometric hardware at all:
`BiometricKekProvider` is not literally biometric-specific — it is "any local
authenticator that releases a KEK". A server can implement a provider backed
by a KMS/HSM or a mounted-secret file, paired with
`ReauthPolicy.headlessSession()`. See `ReauthPolicy.headlessSession`'s doc
comment for the full pattern, including non-interactive passphrase injection
from `$CREDENTIALS_DIRECTORY`/`/run/secrets`/Kubernetes secret mounts. The
CLI session agent (a separate subsystem, deferred to v0.2.0 — see
`docs/plans/plan_0_20_cli_session_agent.md`) is the interactive-CLI
analogue; it is not part of this section.

### Limitations

Honest boundaries of what the unlock policy does and does not protect
against — read alongside "Threat Model & Confidentiality Boundaries" above,
which this section does not replace:

- **Coercion is blunted, not solved.** `ReauthPolicy.alwaysRequirePassphrase()`
  and the default 14-day interval make a *stale* biometric unlock refuse a
  coerced device-unlock attempt, but they do nothing once the interval is
  fresh: a device unlocked by its owner within the last 14 days and then
  coerced (e.g. "unlock your phone" under duress) still yields the DEK via
  biometric, because the attacker is presenting the same biometric factor the
  legitimate owner would. This is a fundamental limit of any
  convenience-vs-security trade-off with a *recently used* fast path, not a
  defect specific to this design — see the originating proposal
  (`docs/proposals/unlock_policy.md`) §9 for the considered alternatives.
- **A fully-compromised local OS defeats everything, as it already did before
  this work.** The DEK is held in plaintext in process memory for the
  lifetime of an open database — an adversary who can read the running KMDB
  process's memory, or who controls the OS the biometric prompt itself runs
  on, has already won regardless of the unlock policy (this restates the
  existing "Threat Model" section's stated non-goal above; the unlock policy
  changes *how* the DEK is obtained, not what protects it once obtained).
- **A rooted/jailbroken device weakens the platform guarantees this design
  relies on.** `accessControlFlags: biometryCurrentSet` and Android's
  `setUserAuthenticationRequired` are OS-enforced access-control policies —
  their integrity assumes an intact, unmodified OS/Secure-Enclave/Keystore
  boundary. Root/jailbreak access can, depending on the specific exploit,
  extract Keystore-protected key material or bypass the biometric gate
  entirely; KMDB has no independent defense against this once the platform's
  own security boundary is broken. This is a platform-security limitation
  inherited, not introduced, by this design.
- **`SecretStore` durability is host-chosen, and a lost store means a lost
  biometric shortcut, not lost data.** If the biometric wrap or the re-auth
  timestamp is lost (e.g. an in-memory store across a process restart, or a
  host-provided store that is itself cleared), biometric unlock simply
  becomes unavailable (`EncryptionErrorCode.biometricUnavailable`,
  fail-closed) and the passphrase or recovery code is required — this is a
  UX regression, never a confidentiality or data-loss failure, since the DEK
  itself is unaffected and the passphrase/recovery-wrapped copies in
  `enc:blob` are untouched.

## Vault Encryption

`VaultStore` wraps every blob through `EncryptionEnvelope` before writing it to
disk. The SHA-256 content address and CRC32C checksum are always computed over
the **plaintext** bytes, preserving the deduplication guarantee. The stored blob
is **self-describing** via a leading `EncryptionFlag` byte — the format is owned
by §24 (see §24 _Encryption_), reproduced here for reference:

```
sha256 = SHA-256(plaintext)   // content address, always over plaintext
stored = EncryptionFlag.aesGcm(0x01) || nonce(12B) || AES-256-GCM(dek, plaintext) || tag(16B)   [encrypted]
stored = EncryptionFlag.none(0x00)  || plaintext                                                 [unencrypted]
```

The wrap is **unconditional** — a blob written on an unencrypted database still
carries the one-byte `EncryptionFlag.none` prefix. Whether a blob is ciphertext
is therefore determined by its own leading flag byte, not by any external
record.

The `manifest.json` for each blob carries an `encrypted: true` field when
encryption is active (absent otherwise), but it is **descriptive only**.
`VaultStore.getBytes()` decides whether to decrypt by reading the
`EncryptionFlag` byte **on the blob itself** via `EncryptionEnvelope.unwrap` — it
never consults `manifest.json`'s `encrypted` field. This closes S-4 (2026-07-18
release-readiness review): for a blob synced from a peer the manifest flag is
attacker-controlled, so gating decryption on it let a substituted plaintext blob
be served with GCM authentication silently disabled. After unwrapping,
`getBytes()` verifies the plaintext against its claimed content address and
throws `VaultContentMismatchException` on a mismatch. If the blob is
`EncryptionFlag.aesGcm`-flagged but no `EncryptionProvider` is configured,
`EncryptionEnvelope.unwrap` throws a `StateError`.

KVLT archive export (`VaultStore.exportKvlt`) decrypts blobs to plaintext before
packing them. KVLT import re-encrypts blobs if the destination database has
encryption active.

## Provider Threading

`EncryptionProvider?` is threaded as a named optional parameter through all
`ValueCodec.encode` / `ValueCodec.decode` call sites. A `ValueContext` — see
"Associated Data (AAD Binding)" above — is threaded alongside it as a
**required** parameter (required even when `encryption` is `null`, so the
compiler enumerates every call site rather than silently permitting an
omitted context the moment encryption is enabled):

```dart
final bytes = await ValueCodec.encode(
  doc,
  context: ValueContext(namespace, key),
  encryption: _db.encryption,
);
final doc = await ValueCodec.decode(
  bytes,
  context: ValueContext(namespace, key),
  encryption: _db.encryption,
);
```

All call sites in `KmdbCollection`, `IndexManager`, `VersionManager`, and
`VaultRefInterceptor` receive the provider from `KmdbDatabase.encryption`, and
construct `ValueContext` from the real `(namespace, key)` (or a named
constructor for the non-KvStore value classes) already in scope at each site.

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
device ID, namespace registry, generation counters) is encrypted end to end
except the two documented exemptions — `enc:blob` and the `formatVersion` marker
(both raw so bootstrap can read them before the DEK exists; see _enc:blob
Structure_ above).
Index/FTS/Vec *state* was moved out of `$meta` into the local-only
`$$indexstate`/`$$ftsstate`/`$$vecstate` namespaces by WI-11 (see the
[attribute registry](03a_attribute_registry.md)); it remains
`EncryptionEnvelope`-wrapped there. The vault-search writers
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
| `biometricUnavailable`            | `KEKSource.biometric` supplied, but no wrap is enrolled for this database on this device, or `ReauthPolicy` has refused it (fail-closed) — see _Unlock Policy_ |
| `databaseLocked`                  | An `encrypt`/`decrypt`/`indexToken` call was made after `KmdbDatabase.lock()` discarded the DEK — see _Unlock Policy_ |

## API Reference

### `EncryptionConfig`

```dart
// Unlock with passphrase (State 5):
EncryptionConfig(passphrase: 'my-secure-passphrase')

// Unlock with recovery code (State 5):
EncryptionConfig(recoveryCode: 'able acid aged ...')

// Unlock with a biometric-gated KEK (State 5 — see "Unlock Policy" above;
// requires prior enrolment via KmdbDatabase.enableBiometricUnlock):
EncryptionConfig.biometric(
  myBiometricKekProvider,
  reauthPolicy: const ReauthPolicy.interval(Duration(days: 14)), // default
)

// Provision (State 4 — use the result to show the recovery code):
final result = await EncryptionConfig.createResult(passphrase: '...');
final db = await KmdbDatabase.open(..., encryptionConfig: result.config);
// Show result.recoveryCode to the user (one-time event).
```

### `KmdbDatabase.open()` — encryption parameters

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/db',
  adapter: adapter,
  encryptionConfig: EncryptionConfig(passphrase: 'passphrase'),
  secretStore: mySecretStore, // optional — see "Unlock Policy" above; defaults to InMemorySecretStore
  now: () => DateTime.now(),  // optional — injectable clock for ReauthPolicy.interval tests
);
```

`encryptionConfig` is `null` for plaintext databases. `secretStore` and `now`
are consulted only by the `KEKSource.biometric` branch (the per-device
biometric wrap and the `ReauthPolicy` interval check, respectively) — they
have no effect on passphrase/recovery-code unlock or on plaintext databases.

### `KmdbDatabase.lock()` / `enableBiometricUnlock()` / `disableBiometricUnlock()`

```dart
db.lock();                                          // discard the DEK — see "Enrolment and Lock" above
await db.enableBiometricUnlock(myBiometricKekProvider);
await db.disableBiometricUnlock();
```

### `EncryptionProvider` / `AesGcmEncryptionProvider`

```dart
final dek = await KeyDerivation.generateDek(); // 32 random bytes
final provider = AesGcmEncryptionProvider(dek);

final aad = const ValueContext('tasks', docKey).toAad();
final ciphertext = await provider.encrypt(plaintext, aad: aad);
final recovered  = await provider.decrypt(ciphertext, aad: aad);
```

`aad` is required on both `encrypt` and `decrypt` (0.10.01 WI-3) — see
"Associated Data (AAD Binding)" above. `ValueCodec`/`EncryptionEnvelope`
callers never call `encrypt`/`decrypt` directly; they pass a `ValueContext`
and the codec computes `aad` internally via `context.toAad()`.

## Platform Notes

- Encryption is supported on all platforms (native and web).
- Argon2id is pure-Dart (`package:cryptography`) — no native build hook
  required. On web, it runs in the same isolate and can take several seconds per
  derivation. Applications should show a loading indicator and perform
  derivation off the main isolate when possible.
- There is no DEK session cache on any platform (see _Unlock Policy_ above) —
  every open is an authenticated unwrap. The `kmdb_flutter` add-on package
  provides:
  - `FlutterBiometricKekProvider` — the native `BiometricKekProvider`
    implementation backed by `flutter_secure_storage`; see _Platform
    Support_ above for the per-platform biometric-gating matrix.
  - `KmdbFlutter.initialize()` — registers `cryptography_flutter` for
    hardware-accelerated AES-GCM on iOS (Secure Enclave) and Android (Keystore).

### Flutter Integration

Flutter apps should use the `kmdb_flutter` add-on package to enable both
biometric unlock and hardware-accelerated cryptography. Add it to your
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
    encryptionConfig: EncryptionConfig(passphrase: 'my-secure-passphrase'),
  );

  // Optionally enrol biometric unlock so the user is only prompted for their
  // passphrase once per device (subject to ReauthPolicy — see above), not on
  // every app launch:
  await db.enableBiometricUnlock(FlutterBiometricKekProvider(dbDir: '/path/to/db'));

  runApp(MyApp(db: db));
}
```

On a later launch, unlock with the enrolled biometric instead:

```dart
final db = await KmdbDatabase.open(
  path: '/path/to/db',
  adapter: adapter,
  encryptionConfig: EncryptionConfig.biometric(
    FlutterBiometricKekProvider(dbDir: '/path/to/db'),
  ),
  secretStore: mySecretStore, // must be the SAME store instance/backing used at enrolment
);
```

#### Web

Web has no `BiometricKekProvider` implementation (see _Platform Support_
above — deferred, WebAuthn-PRF follow-up). Flutter web apps should use the
passphrase path and re-derive the DEK from the passphrase on each page load —
there is no DEK persisted in browser storage regardless (the project's
position, unchanged from prior versions: DEKs are never persisted in browser
storage). See RC-16 in `docs/spec/28_release_checklist.md` for the web
Argon2id timing verification.

#### `KmdbFlutter.initialize()` idempotency

`initialize()` is safe to call more than once (e.g. across hot-reloads or in
tests) — a static guard ensures `FlutterCryptography.enable()` is called at most
once per process. As of `cryptography_flutter` 2.3.4 Flutter auto-registers the
plugin, so `initialize()` is technically optional; calling it explicitly remains
the recommended pattern to document intent and ensure activation before
`runApp()`.

## Threat Model & Confidentiality Boundaries

### Threat Model

**This section is a confidentiality (passive-adversary) threat model only.**
Prior to 0.10.01 WI-4, this was the *only* adversary KMDB's sync design
considered at all — the sync folder was implicitly trusted: anything found
there was assumed genuine simply because it was in the sync folder. That
implicit trust is now closed by a **separate, orthogonal layer** — sync
authentication (§34) — which this section does not describe and does not
depend on. The two layers protect against different, independent
adversaries and are deliberately decoupled (sync authentication does not
require encryption to be enabled, and vice versa):

1. **The cloud storage provider** (and anyone with access to the synced files)
   **reading** data — a **passive** adversary. KMDB syncs whole SSTable
   files — the provider receives the complete on-disk representation of every
   flushed and consolidated SSTable. The encryption scheme in this section
   ensures that a passive reader cannot read document values from those files
   without the DEK.
2. **Physical access to a device** by an adversary who does **not** know the
   passphrase (e.g. a lost or stolen phone). Because the DEK is wrapped under a
   passphrase-derived (Argon2id) KEK and never persisted in plaintext, an
   attacker who cannot supply the passphrase or recovery code cannot decrypt
   document values from the on-disk database. **This claim was false prior to
   0.10.01 WI-5** (SC-1, 2026-07-18 release-readiness review): a warm session
   DEK cache returned the DEK without ever checking the supplied passphrase,
   so *any* string opened the database whenever the cache was warm — the
   normal state on a recommended mobile configuration. The `DekCache`
   interface has been removed entirely; see _Unlock Policy_ above for the
   current wrapped-copy model and its still-honest limitations (biometric
   unlock is a *bounded* convenience shortcut, not an exception to this
   claim).

Encryption is **not** designed to:

- Conceal **metadata** — file sizes, timing, device identities, document
  existence, indexed values, or search vocabulary. Several structural surfaces
  remain plaintext by design or by current limitation (enumerated below).
- Resist a **fully-compromised local OS** or a process that can read the running
  KMDB process's memory. The DEK is held in plaintext in process memory for the
  lifetime of an open database; an adversary with that level of access has
  already won.
- **Authenticate the provenance of synced artefacts.** A passive reader (1)
  above is explicitly *not* assumed to write anything back. The realistic
  escalation of that adversary — **a compromised cloud account** (a phished
  password, a stolen OAuth token, a third-party app with Drive scope) — is an
  **active** adversary: it can write to the sync folder while authenticated
  as the legitimate user, and neither this section's confidentiality
  guarantees nor full-disk/at-rest encryption on the provider's side helps
  against it, because the attacker is not defeating either of those — it is
  simply using the account's own write access. This active-but-unkeyed
  adversary is called **T1** in §34, and closing it (SSTable, vault, HWM, and
  consolidation-lease authentication via a HMAC keyed by an independent
  sync-set key) is that section's entire subject, not this one's.
  - **T1 is explicitly out of scope for this section** and was never claimed
    to be in scope — see the note above. §34's Threat Model section states
    this plainly for its own layer, so a reader who arrives at either
    section first sees a consistent, cross-referenced boundary.
  - **A malicious *peer* device that legitimately holds both the DEK and (if
    sync authentication is enabled) the sync-set key — "T3" in §34's
    terminology — is out of scope for *both* layers.** A shared-key MAC
    cannot distinguish a malicious key-holder from a legitimate one, and
    neither can a shared DEK: any device that has been legitimately enrolled
    can always produce ciphertext/envelopes that authenticate and decrypt
    correctly for content it chooses to write. This is a fundamentally
    different problem (per-device identity and revocation, not a shared
    secret) and is deferred to
    [`docs/proposals/device_identity.md`](../proposals/device_identity.md).

The remainder of this section honestly enumerates what is and is not protected
**against the passive-provider and lost-device adversaries above** — none of
the bullets below should be read as an authenticity claim; see §34 for that
axis.

### Protected (encrypted)

When encryption is active, the following are encrypted at rest and in cloud
sync:

- **Document values** — encrypted via `ValueCodec.encode(encryption:)` before
  they enter the storage engine (see _Encoding Pipeline with Encryption_).
- **System namespace values that pass through `ValueCodec`** — the _values_
  stored under `$$index:`, `$ver:`, `$vault:` ref-count entries, and `$$cache:`
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
- **`$meta` operational metadata** — the namespace registry, schema/
  version-retention policy, and the format-version marker are encrypted via
  `EncryptionEnvelope` (Gap 3), the two documented exemptions being `enc:blob`
  and the `formatVersion` marker (both stored raw so bootstrap can read them
  before the DEK exists — see _enc:blob Structure_). (Device ID is **not** on
  this list — 0.10.01 WI-12 removed it from `$meta` entirely; see the
  attribute registry's [`device_id` entry](03a_attribute_registry.md#device_id).
  It is stored unencrypted in the local, never-synced `DEVICE_ID` file
  instead, so this paragraph's "genuine cloud-provider protection" claim does
  not apply to it.) Because `$meta` rides synced SSTables, this is genuine
  cloud-provider protection. (The dirty-open flag is **not** on this list
  either — 0.10.01 WI-14 moved it to the local-only `$$dirtystate` namespace,
  still `EncryptionEnvelope`-wrapped when a provider is configured, but now
  for local-disk-theft protection rather than cloud-provider protection, the
  same reclassification WI-11 applied to the tombstone-GC floor and
  index/FTS/Vec state above. Generation counters are **not** on this list
  either — 0.10.01 WI-13 moved `gen:{ns}` to the local-only `$$genstate`
  namespace for the identical reason: still `EncryptionEnvelope`-wrapped, but
  now local-disk-theft protection only, since `$$genstate` never uploads —
  see the attribute registry's [`gen:{ns}` entry](03a_attribute_registry.md#genns).)
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

> **Note on confidentiality vs. authenticity.** Every bullet above is a
> confidentiality claim (the value is unreadable without the DEK). Separately,
> **every AES-GCM encrypted value above is also bound to *where* it is
> stored** (its real `(namespace, key)`, or a fixed non-KvStore identifier —
> see "Associated Data (AAD Binding)" above, 0.10.01 WI-3). This is an
> authenticity property, not a confidentiality one: it does not hide content,
> it prevents a valid ciphertext from being relocated or transplanted to a
> different location and still decrypting successfully.

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
> Encryption Coverage_ list above). The namespace registry remains in `$meta`
> as described here; generation counters have since moved too — see the
> WI-13 update below.
>
> **Update (0.10.01 WI-12).** Device ID has since been removed from `$meta`
> entirely (SC-5), not moved to a `$$` namespace — the local, never-synced
> `DEVICE_ID` file was already its sole authoritative store, so there was no
> cross-device value needing a device-local home behind `$$`. It is stored
> unencrypted (plaintext), since the file itself never leaves the local
> device. See the attribute registry's
> [`device_id` entry](03a_attribute_registry.md#device_id).
>
> **Update (0.10.01 WI-14).** The dirty-open flag has since moved out of
> `$meta` into the local-only `$$dirtystate` namespace, for the same
> device-local-fact-in-a-synced-namespace reason as the WI-11 move above (a
> peer's clean-close `clearDirty` tombstone could otherwise win LWW over this
> device's own crash marker and erase it before it is ever read — see the
> attribute registry's [`dirty` row](03a_attribute_registry.md)).
> `EncryptionEnvelope` wrapping was preserved across the move.
>
> **Update (0.10.01 WI-13).** Generation counters (`gen:{ns}`) have since
> moved out of `$meta` into the local-only `$$genstate` namespace — the last
> of the six device-local facts this section originally listed as living in
> `$meta`. Unlike the moves above, this one was not purely mechanical: the
> counter was read *cross-device* for cache invalidation, so a compensating
> ingest-side bump/emit was needed (`LsmEngine.ingestAt0` scans each ingested
> SSTable for its distinct namespaces and bumps/emits for exactly that set —
> see the attribute registry's [`gen:{ns}` entry](03a_attribute_registry.md#genns)).
> `EncryptionEnvelope` wrapping was preserved across the move. No `$meta`
> entry originally listed in this paragraph as an undocumented-encryption gap
> remains in `$meta` today.

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
database-level encryption, the file and its containing profile directory are
now permission-hardened (POSIX: `chmod 700`/`600`, hard-refuse on read if
either has drifted looser — the OpenSSH/`gcloud` model) via the core
`SecretStore` interface and `kmdb_cli`'s `DirectorySecretStore`. This closes
the "plaintext, no protection at all" gap the file's contents (a live OAuth
token) had before; see §33 for the full design, including why
directory-permission hardening was chosen over OS-native keychain integration
(deferred, see `docs/roadmap/9_99.md`).

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
