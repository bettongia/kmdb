# Technical Proposal: Unlock policy — biometric, session, and periodic re-authentication

## 1. Overview

KMDB currently caches the **raw DEK** and, on a cache hit, opens the database
without checking anything the caller supplied. This proposal replaces that with
a **wrapped-copy** model borrowed from 1Password: the DEK gains additional
wrapped entries — biometric on mobile and desktop, WebAuthn PRF on web — so that
**every open unwraps via some path, and every path authenticates**.

It also adds two things KMDB has no answer for today: a **session/agent model**
for the CLI, and a **periodic passphrase re-authentication policy** that is on by
default.

> **Status.** Pre-planning exploration. Motivated by finding **SC-1** in the
> [2026-07-18 release-readiness review](../reviews/release-readiness-review-2026-07-18.md)
> (W1 spec conformance). §9 lists what must be decided before this becomes a plan.

## 2. The problem

### 2.1 SC-1 — a warm cache skips verification entirely

`kmdb_database.dart` reads the cache and returns a provider:

```dart
final cachedDek = await encryptionConfig!.dekCache.read(dbId);
if (cachedDek != null) {
  return encryptionConfig.buildProvider(cachedDek);   // passphrase never checked
}
// tryUnwrapWithPassphrase() only runs after a cache MISS
```

**A deliberately wrong passphrase opens an encrypted database whenever the cache
is warm.** This is the *recommended* mobile configuration — §31 tells Flutter
hosts to inject `FlutterSecureDekCache` precisely so the prompt happens once.

**§31's own stated remedy does not fix it.** The spec says the cached DEK is
confirmed "by AES-GCM decryption of `enc:blob` … to confirm the cached key is
correct". That confirms the *DEK* is valid; the passphrase never enters the
cache-hit path at all. Implementing it verbatim would catch a stale DEK and
still let a wrong passphrase through.

The underlying constraint: **you cannot both skip Argon2id and verify a
passphrase.** The cache exists to skip the KDF; verifying the passphrase
requires running it. A warm cache bypasses the passphrase *by construction*.

That is a design gap, not a coding error — which is why this is a proposal
rather than a bug fix, and why **it must not be resolved by editing §31 to
describe what the code does.**

### 2.2 The threat model this actually affects

The attacker needs physical access to an **unlocked** device and interacts
through the app UI. Without root, jailbreak, or forensic tooling they cannot
read the keychain item directly — so the passphrase gate is the *only* barrier,
and SC-1 removes it.

The canonical case is **coerced or compelled unlock**: *"I'll unlock my phone,
but I won't give you the app passphrase."* That posture is exactly what an
app-level passphrase exists to support, and SC-1 silently defeats it.

### 2.3 Two platform gaps nothing currently addresses

| Platform | Today | Consequence |
| :--- | :--- | :--- |
| **CLI** | **No `DekCache` at all** — no reference anywhere in `kmdb_cli` | Full Argon2id (~200ms) on *every* command that opens an encrypted database. Tolerable in the REPL; painful for scripting |
| **Web** | `InMemoryDekCache` only, which dies with the page | §31 states Argon2id on web takes **"several seconds per derivation"** — on every page load. Borderline unusable |

Neither is solved by biometrics.

## 3. Prior art: 1Password

The [1Password biometric model][bio] is the shape to copy, and one detail is
decisive:

> 1Password keeps **two encrypted copies of the Master Key** — one encrypted with
> the account password, one with an "Authenticated Key" derived via the Android
> Keystore. The Authenticated Key is **never stored on the device**; it is
> generated fresh on each biometric authentication.

**They do not cache the master key behind a biometric gate. They wrap it a second
time.** That is structurally different from a cache, and it is why the SC-1 bug
class cannot exist in their design.

Three further details worth taking:

- **Enrolment invalidation.** Adding a fingerprint or face invalidates the
  Keystore key; biometric unlock auto-disables and the password is required to
  reconfigure. This is `biometryCurrentSet` semantics and it defeats the
  "attacker enrols their own finger" case.
- **Periodic re-entry is framed as a memory aid** — it "helps users remember it."
  See §4.3; this matters *more* for KMDB than for 1Password.
- **Unlock method and auto-lock are orthogonal settings.** *How* you unlock
  (biometric vs passphrase) is configured separately from *when* it locks (idle
  timeout, device sleep, app exit, user switch).

[bio]: https://support.1password.com/android-biometric-unlock-security/

## 4. Design

### 4.1 A third wrapped DEK, not a cache

§31's `enc:blob` already holds multiple wrapped copies. This adds a third:

```
wrappedDekPassphrase   ← Argon2id KEK from the passphrase        (exists)
wrappedDekRecovery     ← HKDF KEK from the recovery code         (exists)
wrappedDekBiometric    ← KEK held non-extractably in Secure Enclave /
                         Keystore / Credential Manager, released only
                         after biometric authentication          (NEW)
```

This is a natural fourth entry in an existing structure rather than a parallel
mechanism, and it **makes SC-1 structurally impossible**: there is no path that
returns a DEK without authenticating something.

It also echoes the [betto_secret_store](betto_secret_store.md) conclusion —
prefer platform keys that can be *used* but not *extracted*.

`DekCache` as a raw-DEK store is **removed**, not fixed.

### 4.2 Platform matrix

| Platform | Biometric / authenticator | KEK storage |
| :--- | :--- | :--- |
| iOS / Android (Flutter) | Face ID, Touch ID, BiometricPrompt | Keychain / Keystore. `flutter_secure_storage` ≥10.3 already exposes `accessControlFlags` (`biometryCurrentSet`) — **no new dependency** |
| macOS (Flutter) | Touch ID, Apple Watch | Keychain |
| Windows (Flutter) | Windows Hello | Credential Manager |
| Linux (Flutter) | Rare in practice | Secret Service; passphrase path in practice |
| **CLI** | None | **Session agent — see §4.4** |
| **Web** | **WebAuthn PRF** — see §4.5 | Non-extractable `CryptoKey` |
| **Server** (headless) | **None — no human present** | **Operator-injected at start — see §4.6** |

### 4.3 Periodic passphrase re-authentication — **on by default**

**Decision: on by default, with a configurable interval.**

1Password frames periodic re-entry as a memory aid. **For KMDB it is a
data-loss control**, and that is a stronger justification:

§31 states the recovery code is shown **once and never stored**. So a user who
enables biometrics, never types their passphrase for six months, forgets it,
misplaces the recovery code, and then hits a biometric invalidation (OS update,
re-enrolment) has **permanently lost their database**. 1Password has account
recovery; KMDB has nothing.

Default-on also answers the adoption problem directly: a security control users
must opt into is one they enable *after* the event that needed it.

- Default interval: **14 days** (see §9 Q4).
- Host apps may lengthen or shorten it, and may set "always require passphrase".
- **Enforcement lives in the library.** If KMDB merely *recommends* re-prompting,
  integrators will not. `KmdbDatabase.open()` must refuse the biometric path once
  the interval has lapsed.

> ⚠️ **The "passphrase last used" timestamp must be local-only.** `$meta`
> **syncs** (`isLocalOnly(r'$meta')` is `false`), so a device untouched for a
> month would inherit another device's recent timestamp under LWW and silently
> skip its re-authentication. This is the same collision that sank the
> database-identity proposal in the sync-authentication plan. Store it per-device
> outside synced state.

### 4.4 CLI — a session agent

**Decision: session/agent model**, following `ssh-agent`, `gpg-agent`, and
`op signin`.

Unlock once; subsequent commands reuse a short-lived session until it expires.
This is the only option that makes scripting against an encrypted database
practical.

It is also the highest-risk component in this proposal, because it creates a new
place a DEK lives. Requirements:

- The DEK should live in **agent process memory**, not on disk. A cache file
  would reuse the existing permission-hardened directory but is a materially
  weaker posture.
- The socket or handle must be owner-only, reusing the credential store's
  permission model.
- Sessions must expire, and `kmdb ... lock` must end one immediately.
- The agent must never outlive the user session.

### 4.5 Web — WebAuthn PRF

**Decision: WebAuthn PRF** as the web analogue of the Secure Enclave path.

The PRF extension derives a symmetric secret from a passkey authentication,
gated on a platform authenticator (Touch ID, Windows Hello, Android). That
secret becomes the KEK for `wrappedDekBiometric` — structurally identical to
mobile, which keeps one model across platforms.

- Fallback where PRF is unavailable: a non-extractable `CryptoKey` in IndexedDB
  protects the key material from exfiltration but provides **no user gate** —
  any script in the origin can use it. This must be documented as the weaker
  tier, not presented as equivalent.
- PRF support needs verifying against current browsers before this is planned
  (§9 Q3).

### 4.6 Server — the headless case, and why the default policy must not apply

The [kmdb_server proposal](kmdb_server.md) describes a self-hosted, headless,
optionally multi-tenant deployment. It is a fourth shape, and the naive reading
of §4.3 would **break it**:

- **Biometrics are meaningless.** There is no human at the keyboard.
- **Periodic passphrase re-entry is actively harmful.** A server that locks
  itself after 14 days and waits for someone to come and type a passphrase is
  not a server. Multi-tenant makes it worse: §5.4 of that proposal notes every
  tenant's DEK is resident simultaneously, so the policy would demand a human
  re-authenticate *N* databases on a schedule.

**The resolution is that a server's session is its process lifetime.** Unlock
once at worker start; re-authenticate on restart. No timer, no periodic prompt.

That is the same shape as the CLI agent (§4.4) — a long-lived process holding a
DEK in memory, unlocked once, ending when the process ends. Worth stating
explicitly, because it means **one mechanism covers both**: the "headless
session" case, distinguished from the interactive case by having no user to
re-prompt.

It also maps cleanly onto that proposal's isolation model. §6.2 recommends
process- or container-per-tenant with DEKs confined to worker processes and the
router holding none. One worker = one tenant = one DEK = one session.

#### This partially answers `kmdb_server` §10 Q2

That proposal lists as open: *"how an existing encrypted database gets unlocked
after the server restarts — operator-supplied at start (env/keyring),
client-supplied-on-connect and cached for the session, or does it simply stay
locked until a client authenticates?"*

Under this design the answer is the **existing passphrase path with the
passphrase injected non-interactively** — no new wrapped entry is needed. And
the injection mechanism already exists in a sibling proposal:
[betto_secret_store](betto_secret_store.md)'s directory backend with a
configurable root covers systemd `$CREDENTIALS_DIRECTORY` (TPM-backed at rest),
Podman `/run/secrets`, and Kubernetes mounts with one implementation.

So the three proposals compose rather than compete: `betto_secret_store` supplies
the secret, this proposal defines when it is required, and `kmdb_server` consumes
both.

> **The policy must therefore be suppressible, and that weakens §4.3's
> "enforcement lives in the library" claim** — a headless host will disable it,
> and any host *can* claim to be headless. The honest framing: the library
> enforces the policy by default and requires an explicit, documented opt-out
> naming the deployment shape. That stops accidental omission, not deliberate
> circumvention. Given the host app is trusted anyway (§6), this is the right
> trade — but it should be stated rather than implied.

### 4.7 Auto-lock is a separate axis

Per 1Password, *how* you unlock and *when* it locks are orthogonal.

- **KMDB provides** `KmdbDatabase.lock()` — discard the in-memory DEK and require
  a fresh unwrap.
- **The host app decides when to call it**: idle timeout, app background, device
  screen lock, app exit.
- The library must not attempt to observe OS lifecycle events itself; that is
  squarely a host concern and differs per platform.

### 4.8 Library / app split

1Password is an app; KMDB is a library, so this boundary needs stating.

| Concern | Owner |
| :--- | :--- |
| `wrappedDekBiometric` in `enc:blob` | **KMDB core** |
| Re-authentication policy + **enforcement** | **KMDB core** |
| `lock()` | **KMDB core** |
| Biometric prompt, auto-lock timers, settings UI | **Host app** |
| Platform KEK implementations | `kmdb_flutter` (mobile/desktop), web bridge |
| Session agent | `kmdb_cli` |

## 5. What this closes

| Finding | Effect |
| :--- | :--- |
| **SC-1** | Structurally eliminated — no path returns a DEK unauthenticated |
| **SC-1a** (missing `enc:blob` confirmation) | Moot; the cache it applied to is gone |
| CLI Argon2id per command | Solved by the session agent |
| Web multi-second Argon2id per page load | Solved by PRF-wrapped DEK |
| Passphrase forgotten → data loss | Mitigated by default-on periodic re-entry |

## 6. What this does *not* protect against

Stated plainly, because the asymmetry matters and the honest answer is not
flattering to biometrics:

- **Coercion.** Someone can hold a phone to your face or press your finger. A
  passphrase in your head cannot be taken that way, and several jurisdictions
  treat compelled biometrics differently from compelled passphrase disclosure.
  **For the compelled-unlock case, biometrics are weaker than a passphrase.**
  This is why "always require passphrase" must remain available, and why
  §7 proposes a per-operation escalation.
- **A compromised host app.** Enforcement is in the library, but a modified
  build can call whatever it likes. This defends against attackers using the
  app, not against attackers who replace it.
- **Root / jailbreak / forensic extraction.** Out of scope, and already out of
  scope in §31's threat model.

## 7. Optional: per-operation escalation

Because neither factor dominates, the strongest posture is layered rather than
chosen: biometric for routine open, **passphrase required for operations that
exfiltrate or destroy** — `vault export`, `dump`, disabling encryption,
changing the passphrase.

Routine use stays frictionless; the dangerous paths keep a knowledge factor,
which is exactly the case coercion attacks. Recorded as optional because it
expands the API surface; see §9 Q5.

## 8. Spec impact

- **§31** — replace the DEK Cache section with the wrapped-copy model; add the
  policy, the platform matrix, and §6's honest limitations. **Must not be
  reconciled by describing the current code.**
- **§19 (platform)** — the platform matrix.
- **§33 (CLI credential store)** — the session agent.
- **§28** — release-checklist entries: biometric enrolment invalidation, coerced
  re-auth behaviour, and agent expiry cannot be CI-tested.

## 9. Open questions

1. **Where does the session agent's DEK live**, and what is its lifetime bound —
   idle timeout, absolute expiry, or both? (§4.4)
2. **Does the agent need to support multiple databases** concurrently, and if so
   how are they namespaced? The credential store's database-identity discussion
   is relevant prior art.
3. **Verify WebAuthn PRF support** across current browsers, and decide whether
   the non-extractable-`CryptoKey` fallback ships in v1 or is deferred. (§4.5)
4. **Confirm the 14-day default interval.** 1Password's default is worth
   checking; the right answer may differ for a database from a password manager.
5. **Is per-operation escalation (§7) in scope**, or a follow-up?
6. **Is MDM/enterprise policy override in scope?** 1Password supports it. Likely
   out of scope for a library, but worth an explicit decision.
7. **Migration:** none required — KMDB is unreleased, so `DekCache` can simply be
   removed. Confirm this matches the standing no-migration position.

## 10. References

- [release-readiness-review-2026-07-18](../reviews/release-readiness-review-2026-07-18.md)
  — finding SC-1
- [1Password biometric unlock security][bio]
- [1Password unlock and auto-lock](https://support.1password.com/unlock-auto-lock/)
- [1Password security architecture](https://support.1password.com/1password-security/)
- [betto_secret_store](betto_secret_store.md) — use-not-extract platform keys
- [device_identity](device_identity.md) — the other deferred security design
- [§31 — Encryption](../spec/31_encryption.md), [§19 — Platform](../spec/19_platform.md),
  [§33 — CLI Credential Store](../spec/33_cli_credential_store.md)
