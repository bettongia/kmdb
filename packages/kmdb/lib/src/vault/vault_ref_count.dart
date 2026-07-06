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

import '../encoding/value_codec.dart';
import '../encryption/encryption_provider.dart';
import '../engine/kvstore/kv_store.dart';
import 'vault_recovery.dart' show kVaultNamespace, kVaultRefCountSentinelKey;

/// The outcome of reading a `$vault:{sha256}` reference count from the KV store.
///
/// This sealed hierarchy deliberately separates the three cases a reader must
/// distinguish, so that every caller makes its deletion decision explicitly:
///
/// - [RefCountAbsent] — no `$vault` entry exists. By the reference-count
///   protocol (see [VaultRefInterceptor]), a count that reaches zero deletes the
///   entry entirely, so *absence means genuinely zero references*. Safe to GC.
/// - [RefCountValue] — the entry decoded to a concrete, non-negative integer.
///   `0` means zero references (safe to GC); `> 0` means referenced (retain).
/// - [RefCountUndecodable] — the entry is present but its bytes could not be
///   decoded into a `refCount` integer (corruption, truncation, an
///   unrecognised encoding from a future/older codec, …). The object **must be
///   treated as referenced and retained** — never deleted on uncertainty.
///
/// The old hand-rolled decoders collapsed [RefCountUndecodable] into "`0`
/// references" and then deleted the blob, which destroyed user data on any
/// unexpected byte pattern (review finding H3). Keeping the three cases distinct
/// makes the fail-safe default impossible to overlook at the call site.
sealed class RefCountReadResult {
  /// Const base constructor for the sealed hierarchy.
  const RefCountReadResult();
}

/// No `$vault` entry exists for the hash — genuinely zero references.
///
/// The reference-count protocol deletes the entry when the count drops to zero,
/// so absence is an authoritative "no references" signal, not an error.
final class RefCountAbsent extends RefCountReadResult {
  /// Creates a [RefCountAbsent] result.
  const RefCountAbsent();
}

/// The `$vault` entry decoded to a concrete, non-negative reference [count].
final class RefCountValue extends RefCountReadResult {
  /// Creates a [RefCountValue] holding the decoded [count].
  const RefCountValue(this.count);

  /// The decoded reference count (always `>= 0`).
  final int count;
}

/// The `$vault` entry is present but could not be decoded into a `refCount`
/// integer.
///
/// Callers must treat this as "referenced" — the object is retained, never
/// deleted, because the code cannot prove it is unreferenced.
final class RefCountUndecodable extends RefCountReadResult {
  /// Creates a [RefCountUndecodable] result.
  const RefCountUndecodable();
}

/// Fail-safe reader for vault reference counts stored under `$vault:{sha256}`.
///
/// Reference counts are written by [VaultRefInterceptor] as
/// `ValueCodec.encode({'refCount': N})`. This helper is the single,
/// authoritative reader of that format: it uses the real [ValueCodec.decode]
/// (the same codec that wrote the bytes) rather than a hand-rolled partial CBOR
/// parser, and it returns a [RefCountReadResult] that forces each caller to
/// handle the undecodable case explicitly.
///
/// ## Storage shape: namespace-per-blob, not key-per-blob
///
/// The entry lives at `(namespace: '$kVaultNamespace:{sha256}', key:
/// [kVaultRefCountSentinelKey])`, **not** `(namespace: kVaultNamespace, key:
/// sha256)`. A 64-character SHA-256 hex digest cannot be a KV *key* — every
/// key passes through `KeyCodec.keyToBytes`, which requires exactly 32
/// UUIDv7-structured hex characters — so the hash lives in the namespace
/// instead, which has no such constraint. See [kVaultRefCountSentinelKey]'s
/// doc comment for the full rationale.
///
/// ## The fail-safe contract
///
/// A vault object may only be deleted on a **positive determination of zero
/// references**:
///
/// - [RefCountAbsent] → zero references (deletion permitted).
/// - [RefCountValue] with `count == 0` → zero references (deletion permitted).
/// - [RefCountValue] with `count > 0` → referenced (retain).
/// - [RefCountUndecodable] → unknown → **referenced; retain.**
///
/// This is the seam the document-versioning work (`$ver:` ref counting) must
/// reuse rather than re-introducing a fourth decoder.
final class VaultRefCount {
  const VaultRefCount._();

  /// Reads the reference count for [sha256] from the `$vault` namespace of
  /// [kvStore].
  ///
  /// [encryption] must match the provider used when the ref count was written.
  /// When the database is encrypted, `$vault` refcounts are also encrypted
  /// (Q4/Q6 decision: encrypt every `ValueCodec` call site uniformly).
  ///
  /// Returns:
  /// - [RefCountAbsent] when no entry exists (`null` bytes).
  /// - [RefCountValue] when the entry decodes to a map with an integer
  ///   `refCount`. Negative stored values are clamped to `0` defensively.
  /// - [RefCountUndecodable] on any decode failure, or when the decoded map is
  ///   missing `refCount` or holds a non-integer value.
  ///
  /// This method never throws for malformed stored bytes — a decode failure is
  /// reported as [RefCountUndecodable] so callers can apply the fail-safe
  /// (retain) policy uniformly.
  static Future<RefCountReadResult> read(
    KvStore kvStore,
    String sha256, {
    EncryptionProvider? encryption,
  }) async {
    final bytes = await kvStore.get(
      '$kVaultNamespace:$sha256',
      kVaultRefCountSentinelKey,
    );
    if (bytes == null) return const RefCountAbsent();

    final Map<String, dynamic> decoded;
    try {
      decoded = await ValueCodec.decode(bytes, encryption: encryption);
    } catch (_) {
      // Corrupt, truncated, or an encoding this build cannot read. We cannot
      // prove the object is unreferenced, so report undecodable and let the
      // caller retain it.
      return const RefCountUndecodable();
    }

    final count = decoded['refCount'];
    if (count is! int) return const RefCountUndecodable();

    // A negative count is nonsensical for a reference count; clamp to zero
    // rather than propagating a corrupt negative value.
    return RefCountValue(count < 0 ? 0 : count);
  }
}
