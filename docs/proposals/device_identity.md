# Technical Proposal: Per-device identity and the malicious-peer threat (T3)

## 1. Overview

The [0.10.01 hardening track](../roadmap/0_10_01.md) closes **T1** — an
untrusted cloud provider, or a compromised cloud account, that can read *and
write* the sync folder — by authenticating every sync artefact under a shared
sync-authentication key.

That deliberately leaves **T3** open: a **compromised peer device** already
holds the shared key, so a shared-key MAC cannot distinguish it from a
legitimate one. Closing T3 requires **per-device asymmetric identity**, an
enrollment model, and revocation.

This proposal captures that design so the deferral is a recorded decision with a
path forward, rather than an omission.

> **Status.** Pre-planning exploration, deliberately deferred out of `0.1.0`.
> §7 lists what must be decided before it becomes a plan.

## 2. What T3 actually buys — and what it does not

This section leads because it is the part most likely to be over-sold.

**A compromised peer already holds the DEK and full plaintext of every
document.** Per-device identity therefore delivers **no confidentiality benefit
whatsoever** against that peer. What it delivers is narrower:

| Property | Gained under T3 defence? |
| :--- | :--- |
| Confidentiality of existing documents | ❌ The peer already has the DEK |
| Preventing the peer writing *its own* bad data | ❌ It is a legitimate device |
| Preventing it **forging data attributed to another device** | ✅ |
| Preventing the **S-6 lease-deletion attack** | ✅ Leases become device-signed |
| **Revoking** a lost or stolen device | ✅ The main practical win |
| **Attribution** — knowing which device authored what | ✅ |

The honest summary: T3 defence is about **blast radius and revocation**, not
confidentiality. That is a real benefit — "my phone was stolen, cut it out of
the sync set" is a normal user need — but it is not "protect my data from a
malicious peer," because that peer already has the data.

This is why T1 was prioritised. T1 defends against an attacker who has
**nothing** (a compromised cloud account) and is the more likely scenario; T3
defends against one who already has **everything**.

## 3. Sketch

### 3.1 Device keypairs

Each device generates an asymmetric keypair at first run, private key held in
`SecretStore` (see [betto_secret_store](betto_secret_store.md)). The public key
is the device's identity. Ed25519 is the obvious candidate — small keys, fast
signatures, available via `package:cryptography`, already a dependency.

### 3.2 Signed artefacts

Every artefact a device publishes is signed by that device rather than MAC'd
under a shared key: SSTables, vault blobs and manifests, high-water marks, and —
critically — the **consolidation lease**, which is the S-6 attack vector.

### 3.3 The device roster

The unsolved problem, and the reason this is deferred. Devices must agree on
which public keys are trusted. Options:

- **Signed roster in the sync folder** — a device list signed by a quorum, or by
  an enrolling device. Self-describing, but bootstrapping trust and handling
  concurrent enrollment is genuinely hard on a store with no atomic
  multi-writer primitive (only `compareAndSwap` on the lease path today).
- **Roster in `$meta`, synced as ordinary data** — reuses LWW-by-HLC, but
  conflict resolution on a *trust* structure is exactly where LWW is most
  dangerous: a stale device could resurrect a revoked peer.
- **Out-of-band** — each device configured manually. Safe, tedious, and
  probably unacceptable UX beyond two devices.

### 3.4 Enrollment

Syncthing's model is the closest prior art: a new device presents its public
key, an existing device approves it out-of-band (QR, short code), and the roster
updates. Note the 0.10.01 track already ships a **pairing-code flow** for the T1
sync-auth key — that UX surface is reusable, which is one reason T1's design was
chosen as a down payment rather than a detour.

### 3.5 Revocation

The hardest part, and where most designs quietly fail:

- A revoked device's **existing signed artefacts remain valid** unless revocation
  is retroactive — which means re-verifying or re-signing history.
- A revoked device still holds the **DEK**, so revocation does not protect
  already-synced data. Full protection means **DEK rotation and re-encryption**
  of everything — which is `encryption.md` §12's deferred "key rotation" item.
  **T3 revocation is therefore not truly complete without DEK rotation**, and
  the two should be designed together.
- Revocation must not be reversible by the revoked device itself, which
  constrains §3.3 sharply: a roster the revoked device can still write to is not
  a revocation mechanism.

## 4. Interaction with T1

The T1 design is intended to be a stepping stone, not throwaway work:

| T1 (0.10.01) | T3 (this proposal) |
| :--- | :--- |
| Shared symmetric key | Per-device keypairs |
| MAC | Signature |
| Pairing-code enrollment | Same UX, exchanging public keys |
| `SyncAuthenticator` interface | Same interface, different implementation |

Because `SyncAuthenticator` is defined as `mac()`/`verify()` rather than
get-key, a signature-based implementation slots in **without changing the
interface** — verification just consults the roster instead of a shared key.

## 5. Cost estimate

Substantially larger than T1. T1 is a key, an HKDF derivation, and a MAC on
existing artefacts. T3 adds: keypair lifecycle, a distributed trust roster with
no atomic multi-writer primitive, enrollment and revocation UX, retroactive
verification semantics, and an interaction with DEK rotation. It also has real
**failure modes of its own** — a user locked out of their own sync set by a
roster mishap is a worse outcome than the attack it prevents.

## 6. Recommendation

**Defer past `0.1.0`.** Ship T1 authentication, and state the T3 boundary
plainly in §31: *all devices holding the sync-auth key are fully trusted; a
compromised device can write arbitrary data to the sync set.*

Revisit when either is true:

1. **Device revocation becomes a real user need** — likely the first driver, as
   lost-phone scenarios arrive with mobile adoption.
2. **DEK rotation is implemented** (`encryption.md` §12), since revocation is
   incomplete without it and the two share a design.

## 7. Open questions

1. **Roster mechanism** (§3.3) — the blocking decision.
2. **Is revocation-without-DEK-rotation worth shipping?** It stops a revoked
   device writing *new* data but not reading existing data. Useful, or
   misleading?
3. **Retroactive verification** — do artefacts signed by a since-revoked device
   remain valid? "No" implies re-signing history.
4. **Quorum or single-approver enrollment?** Quorum is safer, but painful with
   two devices — the common case.
5. **Recovery** — if the only enrolled device is lost, how does a user re-enter
   their own sync set? This must not become a data-loss path.

## 8. References

- [release-readiness-review-2026-07-18](../reviews/release-readiness-review-2026-07-18.md)
  — findings E-1 (threat model) and S-6 (lease deletion)
- [plan_0_10_01_sync_trust_boundary](../plans/plan_0_10_01_sync_trust_boundary.md)
  — the T1 work this builds on
- [betto_secret_store](betto_secret_store.md) — private key storage
- [encryption proposal](encryption.md) §12 — key rotation, the revocation
  dependency
- [§12 — Sync Protocol](../spec/12_sync.md), [§31 — Encryption](../spec/31_encryption.md)
