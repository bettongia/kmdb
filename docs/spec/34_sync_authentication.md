# Sync Authentication

## Overview

Everything in §12 (Sync Protocol) is written from the perspective of a
device reading a sync folder it implicitly trusts: a file found there is
assumed genuine simply because it is there. That assumption is sound
against a **passive** reader — the threat model §31 (Encryption) addresses
— but not against an **active** adversary who can *write* to the folder:
most realistically, a compromised cloud account (a phished password, a
stolen OAuth token, a third-party app with Drive scope). That attacker is
authenticated as the legitimate user, so neither full-disk encryption nor
the cloud provider's own at-rest encryption helps — the attacker is not
defeating either of those, it is simply using the account's own write
access. Without authentication, such an attacker can forge SSTables, vault
blobs, high-water marks, and the consolidation lease.

This section closes that gap: every artefact KMDB reads from the sync
folder is authenticated with a keyed MAC, such that a party who can write
the folder but does not hold the sync-set key cannot forge one. This is
**closes T1** in the terminology below — see "Threat Model" for T1's
precise definition and the two adversaries deliberately left open (T3, and
passive reading, which §31 already covers).

### Relationship to §31 (Encryption)

Sync authentication and encryption are **deliberately decoupled** —
neither requires the other:

- Authentication does not require encryption: an unencrypted database can
  enroll a remote for sync authentication and gets forgery/tampering
  protection with no confidentiality change.
- Encryption does not require authentication: an encrypted-but-unenrolled
  remote keeps §31's confidentiality guarantees unchanged: a passive reader
  still cannot read document values, but an active writer could still forge
  artefacts (accepted risk until the remote is enrolled).

The two use **independent keys** — the sync-set root key here is never
derived from the DEK, and vice versa. An earlier design considered deriving
the sync-set key from the DEK; it was rejected because it would force
encryption on as a prerequisite for authentication (trading a low-value
requirement — KMDB-level encryption is marginal for a user with full-disk
encryption and a reputable provider — for a high-value guarantee), and
because a DEK-derived key would need re-deriving the moment a malicious-peer
defense (T3, below) eventually lands.

## Threat Model

Three threat classes, only one of which this section closes:

| ID | Adversary | Holds the sync-set key? | Status |
| :--- | :--- | :--- | :--- |
| — | Passive reader of the sync folder | N/A (never writes) | §31's subject, not this section's |
| **T1** | Active: write access to the sync folder (compromised cloud account), no sync-set key | No | **Closed by this section** |
| **T3** | Malicious peer device, legitimately enrolled | Yes | **Out of scope** — see below |

**T1 — the active, unkeyed adversary.** An attacker with write access to
the sync folder but no sync-set key cannot produce a valid `SyncAuthEnvelope`
for any artefact class, because the MAC requires the key. Every artefact
this device reads is verified before use; a forged one is rejected (and,
for SSTables, quarantined — see "Q1: Quarantine Composition" below) rather
than silently accepted.

**T3 — the malicious peer — is explicitly out of scope.** A peer that has
been legitimately enrolled *holds* the sync-set key, so a shared-key MAC
structurally cannot distinguish its artefacts from a trustworthy peer's —
the MAC only proves "produced by *some* key-holder," not "produced by
*this specific, still-trustworthy* device." Per-device identity and
revocation is a fundamentally different problem from a shared secret and is
deferred to
[`docs/proposals/device_identity.md`](../proposals/device_identity.md).
This is the same reason a legitimate DEK-holder is out of scope for §31's
confidentiality guarantees — see that section's Threat Model for the
parallel framing.

## Envelope Format

Authenticity is a property of the **sync channel**, not the artefact's own
file format — SSTables (and vault blobs/manifests) are immutable and
locally identical across devices regardless of who wrote them. The
envelope is applied at upload time and stripped at download time; the
artefact's own bytes are never touched.

```
[magic "KSA" (3B)][version 0x01 (1B)][MAC (16B)][payload]
```

Self-describing, mirroring `EncryptionEnvelope`'s `[flag][payload]` framing
(§31) — the magic and version let the frame evolve unambiguously in a
future KMDB version. A missing or malformed header (too short, wrong magic,
or a version byte this build does not understand) and a MAC mismatch are
both reported identically, as `SyncAuthException`: to the verifier, "this
was never a valid envelope" and "this was a valid envelope with the wrong
key" are indistinguishable, and both mean the same thing — do not trust
this artefact.

### What the MAC covers

```
MAC = HMAC-SHA256(subKey, lenPrefixed(relativePath) ‖ payload)[0:16]
```

- **HMAC-SHA256, truncated to 128 bits** (the leading 16 bytes) — the same
  truncation `AesGcmEncryptionProvider.indexToken` uses (§31, Gap 2), for
  the same reason: 128-bit forgery resistance is far beyond any practical
  attack, and it halves per-artefact overhead relative to the full 256-bit
  output.
- **`relativePath` is bound into the MAC.** The path is the artefact's
  logical location, relative to the sync root — never a local filesystem
  path (which may differ across devices for the same logical remote, e.g. a
  NAS mounted at a different local path on each machine), and
  forward-slash-normalised for cross-platform stability. Binding the path
  means a genuine artefact cannot be **relocated** to a different remote
  path and still authenticate there — e.g. a real peer's `.hwm` file copied
  over another peer's path.
- **`lenPrefixed`** is a 4-byte big-endian length prefix followed by the
  UTF-8 path bytes — the same length-prefixing discipline §31's AAD binding
  uses and for the same reason: without it, two different `(path, payload)`
  pairs whose concatenation happens to coincide would produce the same MAC
  input.
- **Verify in constant time.** `SyncAuthenticator.verify` implementations
  compare the computed and carried MAC without branching on the position of
  the first mismatching byte.

## Per-Artefact-Class Sub-Keys

A single sync-set root key never signs directly. Six per-artefact-class
sub-keys are derived via HKDF-SHA256, mirroring
`AesGcmEncryptionProvider._indexTokenSubKey`'s pattern exactly
(`Hkdf(hmac: Hmac(Sha256()), outputLength: 32).deriveKey(secretKey:
rootKey, nonce: [], info: label)`), with a distinct `info` label per class:

| Class | `info` label | Covers |
| :--- | :--- | :--- |
| `sstable` | `kmdb-sync-auth-sstable` | Regular-flush and consolidation-output SSTables |
| `vaultBlob` | `kmdb-sync-auth-vault-blob` | Vault content blobs |
| `vaultManifest` | `kmdb-sync-auth-vault-manifest` | Vault object manifests |
| `vaultTombstone` | `kmdb-sync-auth-vault-tombstone` | Vault tombstone records |
| `hwm` | `kmdb-sync-auth-hwm` | Per-device high-water-mark files |
| `lease` | `kmdb-sync-auth-lease` | The consolidation coordination lease |

Domain separation via distinct `info` labels means a MAC valid for one
class can never be replayed as another, even though all six derive from the
same root key — a captured, genuine SSTable envelope cannot be re-used to
forge a `.consolidation-lease` file. `vaultTombstone` is its own class
rather than folding under `vaultManifest`: a forged or suppressed
tombstone is a deletion-triggering artefact that drives vault garbage
collection, so it earns domain separation from the manifest.

## `SyncAuthenticator`

```dart
abstract interface class SyncAuthenticator {
  Future<Uint8List> mac(SyncArtifactClass artifactClass, Uint8List message);
  Future<bool> verify(SyncArtifactClass artifactClass, Uint8List message, Uint8List mac);
}
```

**Deliberately not get-key-shaped** — there is no method that returns the
raw key material. A get-key-shaped interface would foreclose backends where
the key can never leave its secure boundary: a non-extractable WebCrypto
`CryptoKey` (see "Web Platform" below), a StrongBox-backed Android key, or a
Secure Enclave key on iOS/macOS. All of those can compute or verify a MAC
without ever exposing the underlying bytes to Dart-visible memory; none of
them can hand back a `Uint8List` key. `message` is the fully-constructed
`lenPrefixed(relativePath) ‖ payload` bytes — implementations treat it as
opaque and do not need to know its internal structure.

### `DefaultSyncAuthenticator` (native)

The pure-Dart implementation, backed by a raw 32-byte root key held in
Dart-visible memory — appropriate for native hosts (the CLI, desktop,
mobile), where there is no equivalent of a browser's script-readable heap
to defend against. Sub-keys are derived lazily and memoized per class, so
concurrent first callers for the same class await one in-flight derivation
rather than each deriving it independently.

### Web Platform (Q4)

`DefaultSyncAuthenticator` is not used on web: a browser tab's script heap
is a uniquely hostile environment for long-lived key material (any XSS
vulnerability, or a malicious/compromised extension with content-script
access, can read arbitrary JavaScript-visible memory). `WebSyncAuthenticator`
instead imports the root key into the browser's Web Crypto subsystem as a
**non-extractable** `CryptoKey` — once imported, the raw bytes can never be
read back out by any script, including KMDB's own. Per-class sub-keys are
derived on demand via `SubtleCrypto.deriveKey` (algorithm `HKDF`, the same
`info` labels as the native implementation), producing further
non-extractable `CryptoKey`s usable only for HMAC-SHA256 `sign`/`verify`.

**Import-only, by design, for now.** Because a non-extractable key can
never be exported, a device that *imports* a key this way can never print
a pairing code for a second device — only a device holding the raw key
bytes can do that. This makes web an **import-only** platform for sync
authentication today: `WebSyncAuthenticator.importKey` is the only
construction path. A future `generateKey` factory — **not implemented in
this release** — would accept an `extractable` policy parameter (default
`false`, matching this constraint); a "show pairing code" UI would then be
gated on `WebSyncAuthenticator.isExtractable` being `true`, which is
structurally impossible for any key created via `importKey` today. This is
a deliberate, documented forward-compat seam, not an oversight — the
maintainer's stated intent is for "start on web, later originate a sync
set" to be reachable without a rewrite. The DB-export-then-re-import route
remains the fallback for a web-originated database that later wants to
enroll a remote.

A non-extractable `CryptoKey` is still structured-cloneable, so the
imported base key is **persisted across sessions in IndexedDB**
(`WebSyncAuthenticator.persist`/`.loadPersisted`) — the browser stores the
opaque key handle, never the underlying bytes, and hands back a live,
usable `CryptoKey` on a later page load.

## The `SyncAuthenticatingAdapter` Decorator

A single core `SyncStorageAdapter` decorator applies the envelope
transparently, precedent-matching `QuotaAwareAdapter`/`GatedSyncAdapter`'s
decorator pattern:

```dart
final adapter = SyncAuthenticatingAdapter(innerAdapter, authenticator);
```

| Method | Behaviour |
| :--- | :--- |
| `upload` | Prepends the envelope (`SyncAuthEnvelope.wrap`) before delegating. |
| `download` | Strips and verifies (`SyncAuthEnvelope.unwrap`) after delegating; throws `SyncAuthException` on a bad or missing MAC — distinct from a `null` return, which still means "file removed between list and download." |
| `compareAndSwap` | Envelopes `newBytes` before delegating — this is how the consolidation lease gets authenticated. |
| `getEtag` | Delegates unchanged — the stored object is the *enveloped* bytes, which is exactly what CAS compares. |
| `list` | Delegates **unchanged** — filenames are never enveloped, only file *contents*. This is what keeps `SstableInfo.parse` on a remote listing unaffected by sync authentication. |

**Artefact classification is by path shape**, since every path the
decorator is ever asked to process is constructed internally by
`SyncEngine`/`ConsolidationCoordinator`/`HighwaterMark` as a forward-slash-only
logical path: `*.sst` → `sstable`, `*.hwm` → `hwm`,
`*.consolidation-lease` → `lease`. The three vault artefact classes are
never classified here — vault sync uses raw `dart:io` File I/O and never
reaches this decorator (see §24's "Sync artefact authentication" section).

### Why one decorator covers every sync call site

`SyncEngine`, `ConsolidationCoordinator`, and `HighwaterMark` all reach the
sync folder **exclusively** through the single `SyncStorageAdapter`
instance they are constructed with. Wrapping that one instance once, at the
adapter-wiring point (`kmdb_cli`'s `adapterFor`, or any host's equivalent
construction site), therefore covers every one of their internal call
sites automatically — `SyncEngine.push`/`pull`/`_fullResync`;
`ConsolidationCoordinator`'s input download, consolidated-output upload,
and lease download/CAS; `HighwaterMark.load`/`save`. No change is needed
inside any of those classes to *apply* the envelope — only to *react* (see
the rejection-policy table below) to the `SyncAuthException` the decorator
throws.

### Per-site rejection policy

Detection is uniform (the decorator always throws `SyncAuthException` on a
bad/missing MAC); **disposition is per call site**, because the safe
response to "this artefact failed authentication" depends on what that
artefact controls:

| Site | On `SyncAuthException` |
| :--- | :--- |
| `SyncEngine.pull` (SSTable download) | Quarantine `unauthenticated`, `continue`, **no HWM advance** — see "Q1: Quarantine Composition" below |
| `SyncEngine._fullResync` (SSTable download) | Skip + quarantine `unauthenticated` — safe here because `_fullResync` has already reset the local HWM to `Hlc(0, 0)` in the same call, so there is no peer HWM this record could poison |
| `ConsolidationCoordinator.consolidate` (input download) | Skip that one input, like the existing `CorruptedSstableException` branch — the surviving legitimate inputs still get consolidated |
| `HighwaterMark.load` of this device's **own** HWM | Propagate — a tampered own file must not be silently ignored |
| Peer HWM load in `_checkAndHandleEviction` | Skip that one peer's contribution, not fatal to the whole re-admission check |
| Lease download / CAS (`ConsolidationCoordinator.acquireLease`) | Propagate — abort this consolidation round rather than act on a forged lease |
| Consolidated-output upload | N/A — the envelope is applied automatically on upload, there is nothing to reject |

## Q1: Quarantine Composition

The one place sync authentication changes §12's own quarantine logic (not
merely wraps it): `SyncEngine.pull`'s existing five `QuarantineReason`
values (`corruptedSstable`, `invalidFormat`, `structuralBoundsViolation`,
`storageError`, `outOfMemory`) all share one safety property — the
filename-derived `maxHlc` is trustworthy, because it names a real peer's
genuinely-corrupt-or-hostile file. Advancing the peer HWM past that
`maxHlc` is therefore safe: it is exactly what makes the rejection
*permanent* rather than a wasted re-download on every subsequent pull.

**A MAC-failed file breaks that assumption.** Its filename — and therefore
its claimed `maxHlc` — is attacker-controlled: an adversary with mere write
access to the sync folder (T1) can name any real peer's device ID and any
`maxHlc` it likes, with no sync-set key required to choose those two
values. If `pull()` trusted that `maxHlc` the way it trusts the other five
reasons' the way it advances the HWM for them, a single forged file could
permanently suppress every subsequent genuine SSTable from the named peer:
the peer HWM would already be at or above every real file's `maxHlc`, so
`pull()`'s existing `info.maxHlc <= peerHwm` skip check would silently drop
them all, forever. This is a denial-of-sync **availability** attack — the
precise thing this section exists to close — reachable through the naive
composition of "verify, then quarantine like everything else."

**The fix:** `SyncEngine.pull` verifies the MAC **before any HWM
decision**. On `SyncAuthException`, the file is quarantined under a sixth
`QuarantineReason.unauthenticated`, `continue`s to the next file, and — the
load-bearing difference from the other five reasons — **the peer HWM is
never advanced for it**. Concretely: the quarantine record and its
`continue` happen strictly before the loop's per-peer `maxHlc` fold, so an
`unauthenticated` file's `maxHlc` never reaches the map the post-loop HWM
save reads from.

**Without an HWM advance, the quarantine log itself becomes the re-fetch
guard.** For the other five reasons, the HWM advance is what prevents
re-downloading and re-rejecting the same file on every subsequent pull; an
`unauthenticated` file has no such advance. `pull()` therefore loads the
full set of already-`unauthenticated`-quarantined filenames once, at the
top of the call (`KvStore.quarantinedFilenames()`), and skips any listed
filename **before** attempting to download it again — closing the
would-be infinite re-download loop without ever trusting the forged
`maxHlc`.

`quarantinedFilenames()` is **deliberately scoped to
`QuarantineReason.unauthenticated` only**, not every reason. A blanket
"skip every previously-quarantined filename" pre-download check would
defeat the *other* five reasons' own crash-safety property: a crash between
the durable quarantine-log write and the HWM save (§12's "Crash ordering")
must let a *subsequent, healthy* pull legitimately re-download and
re-attempt the same file, precisely because the HWM was never actually
advanced in that crash scenario. Only `unauthenticated` has no HWM advance
at all under any circumstance, so it is the one reason whose re-fetch
guard must live in the log instead.

## Enrollment

### Key lifecycle

A `SyncSetKey` (a 256-bit root key from `Random.secure()`, paired with an
opaque sync-set identifier) is minted **per remote**, not per database: a
database syncing to two remotes (e.g. Google Drive and a NAS) holds two
independent keys, each protecting that one remote's folder contents. The
key is minted at `remote add` time, not at database `init` time — minting
at `init` would create keys for databases that never sync, and (see
"Why not a database-identity-at-init design" below) creates a
convergence hazard the remote-add-time design avoids entirely.

**The key is re-provisionable, so it needs no passphrase or recovery
code** — this is the asymmetry that makes auto-generation at `remote add`
defensible. Losing the DEK (§31) is catastrophic: the data is gone
forever, which is why encryption ships a 16-word recovery code. Losing the
sync-set key costs nothing: simply re-enroll every device (`remote pair`)
against a fresh key and resume syncing.

### Why not a database-identity-at-init design

An earlier candidate design considered minting a single identity at
database `init` time and relying on it converging across devices via
`$meta` (the same namespace `DeviceId` persists in). This does not work:
`$meta` syncs (`isLocalOnly(r'$meta')` is `false`), so two devices that
each independently `init` before ever syncing would each mint their own
identity, and the two would LWW-collide unpredictably on first pull —
there is no ordering guarantee that makes either device's value "the"
converged one. Minting at `remote add` and delivering the key **with** the
pairing code sidesteps the problem entirely: there is no reliance on
`$meta` convergence, because every device that will share the key receives
it via an explicit, out-of-band step.

### Pairing code

```
KSA1-JBSWY-3DPEB-LW64T-MMQ...
```

`PairingCode.encode`/`.decode` carry a `SyncSetKey` (root key + sync-set
identifier) as `KSA1-` followed by RFC 4648 base32 (uppercase, no padding),
grouped into 5-character blocks for readability, with a 2-byte checksum
(the leading bytes of `SHA-256(payload)`) appended before encoding. The
checksum exists purely to catch transcription errors — a fat-fingered
character — not to add cryptographic strength; a re-provisionable secret
whose loss costs nothing does not need PAKE-grade protection for its
out-of-band transfer.

### CLI surface

```
kmdb <db> remote add <name> --type <type> ...   # mints a fresh key automatically
kmdb <db> remote pair show <name>               # prints the pairing code
kmdb <db> remote pair import <name> <code>      # installs a shared key
```

`remote add` mints a key for **every** remote type uniformly — this is
what makes a single-device `remote add` "just work" with no separate
enrollment step; pairing is only needed when a *second* device joins the
same remote. `remote pair import` requires the remote to already be
configured on the importing device (its own `remote add`, with its own
connection details — path, Drive folder/credentials) — the pairing code
carries only the shared key, never connection details, so the two steps
are independent. See §33 for the storage-layer detail
(`SecretStore` key naming, mint/load/import/delete lifecycle).

### R-4: unenrolled remote

A remote present in `config.json` with no corresponding `SyncSetKey` (e.g.
hand-edited, or restored from a config backup without the accompanying
secret) is a valid, if incomplete, state: `KmdbDatabase.open()` never
touches `SecretStore` and always succeeds, whether or not any remote is
configured or enrolled. Only `push`/`pull`/`sync` — via `adapterFor`
resolving `loadSyncAuthKey` to `null` — raise `SyncAuthException`, naming
the remote and pointing at `remote pair`, rather than crashing or silently
syncing unauthenticated.

### R-5: pre-existing (pre-sync-auth) remotes

There is no in-place upgrade for a remote that already has un-enveloped
artefacts in it. `SyncAuthEnvelope.unwrap` on a legacy, un-enveloped file
throws the same `SyncAuthException` as a genuinely forged one — a missing
envelope header is indistinguishable from a bad MAC, by design (see
"Envelope Format" above) — with a message pointing the user at
`remote pair` to re-provision. The recommended migration is to wipe the
sync root and re-push from one device once every device that syncs to it
has enrolled the new key; there is no automatic detection or conversion of
legacy artefacts in place.

### `providesAtomicCas = false` adapters

No special interaction: an adapter that cannot provide atomic
`compareAndSwap` already causes `ConsolidationCoordinator` to skip
consolidation entirely (§12), so the lease is never written or read on
that path. The envelope applies uniformly to SSTables, HWM files, and
vault artefacts regardless of CAS capability; lease authentication is
simply inert when consolidation itself never runs.

## No Tolerated-Fallback Mode

There is no "accept unauthenticated artefacts for now" configuration
switch anywhere in this design. Such a switch would be a downgrade attack:
an adversary who can influence configuration (or a well-meaning but
mistaken default) could disable the exact protection this section exists
to provide. Every enrolled remote authenticates every artefact,
unconditionally.

## API Reference

```dart
// Core interface (mac/verify, not get-key shaped).
abstract interface class SyncAuthenticator {
  Future<Uint8List> mac(SyncArtifactClass artifactClass, Uint8List message);
  Future<bool> verify(SyncArtifactClass artifactClass, Uint8List message, Uint8List mac);
}

// Native default.
final authenticator = DefaultSyncAuthenticator(rootKeyBytes); // 32 bytes

// Web (non-extractable WebCrypto CryptoKey, import-only).
final authenticator = await WebSyncAuthenticator.importKey(rootKeyBytes);
await authenticator.persist(keyId); // survives across page loads
final reloaded = await WebSyncAuthenticator.loadPersisted(keyId);

// The six artefact classes.
enum SyncArtifactClass {
  sstable, vaultBlob, vaultManifest, vaultTombstone, hwm, lease,
}

// The transport envelope.
final wrapped = await SyncAuthEnvelope.wrap(
  payload, authenticator,
  artifactClass: SyncArtifactClass.sstable,
  relativePath: 'sstables/a1b2c3d4-0-1.sst',
);
final payload = await SyncAuthEnvelope.unwrap(
  wrapped, authenticator,
  artifactClass: SyncArtifactClass.sstable,
  relativePath: 'sstables/a1b2c3d4-0-1.sst',
); // throws SyncAuthException on a bad/missing MAC

// The core SyncStorageAdapter decorator (Q2) — wrap once, at the
// adapter-wiring point.
final authenticatedAdapter = SyncAuthenticatingAdapter(innerAdapter, authenticator);

// Enrollment.
final key = SyncSetKey.generate();          // 256-bit root key + sync-set id
final code = await PairingCode.encode(key); // 'KSA1-...'
final decoded = await PairingCode.decode(code);
```

## Cross-References

- §12 (Sync Protocol) — the sync cycle, quarantine reporting, and the HWM
  mechanism this section's Q1 composition modifies.
- §24 (Vault) — the six manual threading sites and the two-envelope
  ordering in `hydrateVaultBlob`.
- §31 (Encryption) — the confidentiality (passive-reader) threat model this
  section is deliberately independent of; see that section's Threat Model
  for the T1/T3 cross-reference.
- §33 (`kmdb_cli` Credential Store) — the `SecretStore` seam the sync-set
  root key is persisted through, and the mint/load/import/delete
  lifecycle's CLI-side detail.
- [`docs/proposals/device_identity.md`](../proposals/device_identity.md) —
  the deferred per-device-identity design that would close T3.
