# Technical Proposal: `betto_secret_store`

## 1. Overview

A shared Bettongia package providing **named secret storage** behind one
interface, with two families of backend:

- **Platform keychains** — Windows Credential Manager, freedesktop Secret
  Service, Apple Keychain — for interactive desktop and mobile use.
- **Directory-based storage** — the OpenSSH/`gcloud` model of a
  permission-hardened directory — for headless servers, containers, and
  config-managed deployments.

The directory backend is **not a degraded fallback**. For a server it is the
*correct* backend, and for several deployment idioms it is the only one that
works at all.

> **Status.** Pre-planning exploration. KMDB's
> [0.10.01 hardening track](../roadmap/0_10_01.md) ships a KMDB-local
> implementation of this interface first; this proposal is the path to
> extracting it once the shape has proven itself. §7 lists the decisions needed
> before it becomes a plan.

## 2. Motivation

Three drivers converged:

1. **KMDB needs a second credential type.** `plan_0_09_cli_keychain_credentials`
   established directory-permission hardening for OAuth tokens. The
   [sync trust boundary plan](../plans/plan_0_10_01_sync_trust_boundary.md) adds
   a **sync-authentication key** — the root of sync trust, and more critical
   than an API token. The proportionality argument that deferred native keychain
   support ("three backends for one credential type on a CLI tool") is weaker
   with two credentials, one of which decides whether data can be tampered with.
2. **The review found a real gap.** Finding **C-1** showed the Windows story
   relies on profile-ACL inheritance, but the credential path is a user-supplied
   `dbDir` — so the inheritance is *assumed*, not guaranteed. Owning the path
   fixes it; a shared package makes that fix reusable.
3. **KMDB targets more than desktop.** The CLI is desktop-only but the library
   is not. Mobile has keychains and no filesystem story; web has neither.

## 3. Prior art within Bettongia

`DekCache` (`packages/kmdb/lib/src/encryption/dek_cache.dart`) already
establishes the pattern this package should generalise: a **pure-Dart seam in
core**, an in-memory default, and platform-backed implementations supplied by
outer packages (`FlutterSecureDekCache` in `kmdb_flutter`, via
`flutter_secure_storage`). Its doc comment states the architecture explicitly.

The `betto_onnxrt` / `betto_onnxrt_ios` and `betto_pdfium` / `betto_pdfium_ios`
pairs establish the second relevant pattern: a pure-Dart core package with an
optional Flutter companion where a platform needs one.

## 4. Platform matrix

| Platform | Mechanism | Pure Dart? |
| :--- | :--- | :--- |
| **Windows** | `package:win32` → `advapi32` `CredWrite`/`CredRead`/`CredDelete` | ✅ FFI to an always-present system DLL; no build hook |
| **Linux (desktop)** | `package:dbus` → freedesktop Secret Service | ✅ Protocol-level; works with GNOME Keyring, KWallet, KeePassXC |
| **macOS / iOS** | FFI to Security.framework (`SecItemAdd`/`SecItemCopyMatching`) | ✅ *if written* — no wrapper exists on pub.dev, but it is the same shape as the win32 approach. **This is the package's main new engineering.** |
| **Android** | Keystore (Java API) | ❌ Needs JNI or a platform channel → optional Flutter companion, or route via `flutter_secure_storage` |
| **Any (headless/server)** | Permission-hardened directory | ✅ Already implemented in `kmdb_cli` |
| **Web** | No secure storage primitive exists | ❌ See §6 |

## 5. The directory backend is a first-class citizen

The [kmdb_server proposal](kmdb_server.md) makes this concrete. Its target
deployment — a NAS, Pi, or VPS, with container-per-tenant isolation under
Podman (§6.2) — cannot use a keychain:

- **Headless Linux has no Secret Service.** It needs a D-Bus *session* bus;
  GNOME Keyring needs a login session. A systemd service has neither.
- **Containers have none at all**, and providing one would breach the very
  isolation boundary the server design depends on.
- **Config management is file-shaped.** Ansible, systemd `LoadCredential=`,
  Podman/Docker secrets, and Kubernetes secret mounts all deliver secrets as
  *files in a directory*. A keychain is hostile to that workflow, and to
  backup/restore.

**A directory backend with a configurable root covers all of these with one
implementation:**

| Root | Deployment |
| :--- | :--- |
| `~/.config/kmdb` / `%APPDATA%\kmdb` | Interactive CLI |
| `$CREDENTIALS_DIRECTORY` | systemd `LoadCredential=` — TPM-backed encryption at rest, free |
| `/run/secrets` | Podman / Docker secrets |
| Operator-chosen | Kubernetes mounts, bespoke provisioning |

Four deployment stories for the price of one backend.

## 6. Web is different in kind

Browsers have no secret storage: `localStorage` and IndexedDB are readable by
any script in the origin. This package should **not** pretend otherwise.

There is, however, a genuine primitive for the *use* case: **WebCrypto
non-extractable `CryptoKey`s**. A key can be stored in IndexedDB, used to
HMAC, and never read back — script cannot exfiltrate the material. It does not
stop XSS *using* the key, but it stops extraction, which is the more valuable
half.

That does not fit a byte-oriented `read`/`write` interface, which motivates §7.1.

## 7. Interface shape

### 7.1 Recommendation: keep it byte-oriented

```dart
abstract interface class SecretStore {
  Future<Uint8List?> read(String name);
  Future<void> write(String name, Uint8List secret);
  Future<void> delete(String name);
  Future<List<String>> list();
}
```

The tempting alternative is a `sign`/`verify` interface, so implementations
backed by non-extractable keys can participate. **Recommended against**, for a
reason worth recording: Credential Manager, Secret Service, and Security
Framework all permit readback — they are secret *storage*, not key *isolation*.
Only WebCrypto non-extractable keys, Android StrongBox, and Secure Enclave
cannot. Forcing every backend to implement `mac()`/`verify()` burdens the common
case to serve the exception.

**Instead, the consuming application owns the crypto-capability interface.**
KMDB defines `SyncAuthenticator` with `mac()`/`verify()`; its default
implementation reads a key from a `SecretStore`, and its **web** implementation
bypasses `SecretStore` entirely and talks to WebCrypto. The awkward platform is
confined to one implementation in the consumer rather than distorting the shared
interface.

### 7.2 Backend selection

Explicit and overridable, never magic. A server operator must be able to force
the directory backend even on a host that happens to have a keychain — and a
sensible default order (platform keychain if available, else directory) should
be exactly that: a default.

### 7.3 Permission model (directory backend)

Carry over `DirectoryCredentialStore`'s model unchanged; it was reviewed and
found sound (review **C-3**):

- Directory `chmod 700` **before** the file is written — closing the window where
  a world-readable file exists by path, since `dart:io` has no create-at-mode
  primitive.
- File `chmod 600` after; on chmod failure the secret is **deleted** rather than
  left at loose permissions.
- Read-side **hard refusal** on loose permissions, naming the exact `chmod` fix
  (the OpenSSH precedent).
- Windows: profile-ACL inheritance — now *guaranteed* rather than assumed,
  because the package owns the path (closes **C-1**).

## 8. Naming

`betto_secret_store` over `betto_keychain`: the package's defining feature is
that it is **not** only a keychain, and "keychain" would mislead server
operators into thinking it is desktop-only.

## 9. Open questions

1. **Is the macOS/iOS Security.framework FFI binding in scope for v1**, or does
   v1 ship Windows + Linux + directory, with Apple platforms on the directory
   backend until the binding exists?
2. **Android**: an optional `betto_secret_store_flutter` companion (following
   the `betto_onnxrt_ios` pattern), or leave Android to consumers that already
   depend on `flutter_secure_storage` (as `kmdb_flutter` does)?
3. **Extraction timing.** KMDB ships its own implementation first. Extract once
   a second Bettongia package needs it, or proactively?
4. **Secret metadata.** Does the interface need creation timestamps or labels
   (useful for `kmdb credentials prune`), or is name→bytes enough?
5. **Rotation.** Should the interface model rotation, or is delete-then-write
   sufficient?

## 10. References

- [plan_0_09_cli_keychain_credentials](../plans/completed/plan_0_09_cli_keychain_credentials.md)
  — the original survey and the pivot to directory permissions
- [plan_0_10_01_sync_trust_boundary](../plans/plan_0_10_01_sync_trust_boundary.md)
  — the consumer that motivates this
- [kmdb_server proposal](kmdb_server.md) — the server deployment constraints
- [release-readiness-review-2026-07-18](../reviews/release-readiness-review-2026-07-18.md)
  — findings C-1 and C-3
- [§33 — CLI Credential Store](../spec/33_cli_credential_store.md)
