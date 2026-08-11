// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// @docImport 'encryption_config.dart';
/// @docImport 'kek_source.dart';
/// @docImport 'package:kmdb/src/query/kmdb_database.dart';
/// @docImport 'package:kmdb/src/secret/secret_store.dart';
library;

/// Governs how long a biometric unlock ([KEKSource.biometric]) remains valid
/// before [KmdbDatabase.open] refuses it and requires the passphrase (WI-5,
/// closing SC-1).
///
/// This exists as a **data-loss control**, not (primarily) a security
/// hardening measure: a user who never re-types their passphrase and then
/// hits a biometric invalidation (new fingerprint enrolled, OS reinstall,
/// device migration) has effectively lost the database — nothing else proves
/// they still know the passphrase. Forcing periodic passphrase re-entry keeps
/// that knowledge fresh. It also blunts (but does not solve — see §31's
/// limitations) the coerced-unlock case: *"I'll unlock my phone, but not give
/// you the app passphrase"* no longer silently succeeds once the interval has
/// lapsed.
///
/// This is a named, closed (`sealed`) set of deployment shapes rather than a
/// boolean, because "require re-auth" is not a single on/off switch —
/// `interval`, `alwaysRequirePassphrase`, and `headlessSession` have
/// materially different operational meanings:
///
/// - [ReauthPolicy.interval] (the default, 14 days) — the normal
///   mobile/desktop case. Biometric unlock is permitted as long as the
///   passphrase was used at least once within the interval.
/// - [ReauthPolicy.alwaysRequirePassphrase] — bluntly disables the biometric
///   shortcut entirely; every open requires the passphrase. Covers the
///   coercion case for users who want it unconditionally.
/// - [ReauthPolicy.headlessSession] — the explicit, documented opt-out for
///   server/worker deployments (see §31 and the CLI session agent plan): no
///   periodic timer, no re-prompt. The process's single unlock at startup is
///   the entire session; restarting the process is the only "re-auth" event.
///   This is the honest weakening of "enforcement lives in the library" for a
///   deployment shape that has no user present to prompt.
sealed class ReauthPolicy {
  const ReauthPolicy();

  /// Permits biometric unlock only while the passphrase was used within
  /// [interval]. This is the default policy, with a 14-day [interval].
  const factory ReauthPolicy.interval(Duration interval) =
      _IntervalReauthPolicy;

  /// Never permits biometric unlock — every [KmdbDatabase.open] call with a
  /// [KEKSource.biometric] config is refused, forcing the passphrase.
  const factory ReauthPolicy.alwaysRequirePassphrase() =
      _AlwaysRequirePassphraseReauthPolicy;

  /// Suppresses the re-authentication check entirely — the explicit opt-out
  /// for headless/server deployments (see the class doc comment).
  ///
  /// ## Headless unlock pattern (WI-5 Phase 4)
  ///
  /// A headless deployment (worker/server process, no user present to prompt)
  /// unlocks **once at process start** and holds the [KmdbDatabase] open for
  /// the process lifetime; "re-authentication" is simply restarting the
  /// process. There is no CLI-session-agent-style persistent unlocked state
  /// here — that is a separate subsystem (see the CLI session agent plan).
  /// Two shapes, both library-side hooks with no new API beyond what already
  /// exists:
  ///
  /// 1. **Plain passphrase, read non-interactively.** The common case — no
  ///    [KEKSource.biometric] involved at all, so [ReauthPolicy] is moot
  ///    (the interval only ever gates the biometric path). The host reads the
  ///    passphrase from wherever its deployment platform injects secrets
  ///    (systemd's `$CREDENTIALS_DIRECTORY`, Docker's `/run/secrets`, a
  ///    Kubernetes secret volume mount) and passes it straight through:
  ///
  ///    ```dart
  ///    final credDir = Platform.environment['CREDENTIALS_DIRECTORY'] ??
  ///        '/run/secrets';
  ///    final passphrase =
  ///        await File(p.join(credDir, 'kmdb-passphrase')).readAsString();
  ///    final db = await KmdbDatabase.open(
  ///      path: dbPath,
  ///      adapter: adapter,
  ///      encryptionConfig: EncryptionConfig(passphrase: passphrase.trim()),
  ///    );
  ///    ```
  ///
  /// 2. **A machine-bound `BiometricKekProvider`, with the check suppressed.**
  ///    `BiometricKekProvider` is not literally biometric-specific — it is
  ///    "any local authenticator that releases a KEK" (see its doc comment).
  ///    A server that wants to skip re-deriving the Argon2id KEK on every
  ///    restart can implement a provider that reads a machine-bound key from
  ///    the same kind of mounted secret directory (or a KMS/HSM), and pair it
  ///    with [ReauthPolicy.headlessSession] so the (meaningless, for a
  ///    process with no user) interval check never fires:
  ///
  ///    ```dart
  ///    final db = await KmdbDatabase.open(
  ///      path: dbPath,
  ///      adapter: adapter,
  ///      encryptionConfig: EncryptionConfig.biometric(
  ///        myMachineKeyProvider, // reads from $CREDENTIALS_DIRECTORY, a KMS, etc.
  ///        reauthPolicy: const ReauthPolicy.headlessSession(),
  ///      ),
  ///      secretStore: mySecretStore, // durable across restarts — see SecretStore
  ///    );
  ///    ```
  ///
  ///    [secretStore] itself can be a directory-backed implementation rooted
  ///    at a persistent volume so the biometric-style wrap survives container
  ///    restarts (`kmdb_cli`'s `DirectorySecretStore` is the reference
  ///    implementation of this shape, though it is CLI-scoped, not exported
  ///    from core).
  const factory ReauthPolicy.headlessSession() = _HeadlessSessionReauthPolicy;

  /// Returns whether a biometric unlock is currently permitted.
  ///
  /// [lastPassphraseUse] is the most recent time the passphrase (or recovery
  /// code) was used to unlock this database on this device, or `null` if it
  /// has never been recorded (a fresh [SecretStore], or a device that has
  /// only ever unlocked via biometric). [now] is the current time, injected
  /// so callers can test interval-lapse behaviour without a real 14-day wait.
  ///
  /// A `null` [lastPassphraseUse] is treated as **lapsed** — fail closed
  /// rather than silently permitting biometric unlock on a device that has
  /// never actually recorded passphrase use.
  bool permitsBiometric(DateTime? lastPassphraseUse, DateTime now);
}

/// [ReauthPolicy.interval] implementation.
final class _IntervalReauthPolicy extends ReauthPolicy {
  const _IntervalReauthPolicy(this.interval);

  /// The maximum time since the passphrase was last used before biometric
  /// unlock is refused.
  final Duration interval;

  @override
  bool permitsBiometric(DateTime? lastPassphraseUse, DateTime now) {
    if (lastPassphraseUse == null) {
      // Fail closed: no recorded passphrase use looks identical to "the
      // interval has already lapsed" from a data-loss-control standpoint.
      return false;
    }
    return now.difference(lastPassphraseUse) <= interval;
  }
}

/// [ReauthPolicy.alwaysRequirePassphrase] implementation.
final class _AlwaysRequirePassphraseReauthPolicy extends ReauthPolicy {
  const _AlwaysRequirePassphraseReauthPolicy();

  @override
  bool permitsBiometric(DateTime? lastPassphraseUse, DateTime now) => false;
}

/// [ReauthPolicy.headlessSession] implementation.
final class _HeadlessSessionReauthPolicy extends ReauthPolicy {
  const _HeadlessSessionReauthPolicy();

  @override
  bool permitsBiometric(DateTime? lastPassphraseUse, DateTime now) => true;
}
