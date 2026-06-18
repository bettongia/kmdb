// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// The consistency model a cloud backend exposes to its clients.
///
/// Used by [CloudProfile] to describe how quickly a write committed by one
/// device becomes visible to other devices that share the same backend.
sealed class ConsistencyModel {
  const ConsistencyModel._();

  /// Strong consistency: every completed write is immediately visible on the
  /// next read, regardless of which client or device issues the read.
  ///
  /// This is the model that [SharedBackendAdapter] implements and the one
  /// assumed by the existing harness when a single [MemorySyncAdapter] is
  /// shared.
  const factory ConsistencyModel.strong() = StrongConsistency;

  /// Eventual consistency with a bounded maximum propagation delay.
  ///
  /// A write committed at time T becomes visible to a given observer at some
  /// time T + δ, where `0 ≤ δ ≤ maxPropagationDelayMs`. Within that window,
  /// the observer may see a stale view. After the window, the write is
  /// guaranteed visible.
  ///
  /// [maxPropagationDelayMs] is the upper bound in milliseconds.
  /// [jitterMs] is the maximum random component added to each individual
  /// write's propagation delay (for more realistic simulation). When `0`,
  /// every write becomes visible at exactly [maxPropagationDelayMs].
  const factory ConsistencyModel.eventual({
    required int maxPropagationDelayMs,
    int jitterMs,
  }) = EventualConsistency;
}

/// Strong-consistency variant.
final class StrongConsistency extends ConsistencyModel {
  /// Creates a [StrongConsistency] model.
  const StrongConsistency() : super._();
}

/// Eventual-consistency variant with configurable delay and jitter.
final class EventualConsistency extends ConsistencyModel {
  /// Creates an [EventualConsistency] model.
  const EventualConsistency({
    required this.maxPropagationDelayMs,
    this.jitterMs = 0,
  }) : super._();

  /// Maximum propagation delay in milliseconds.
  ///
  /// A write committed at sequence S is guaranteed visible to all observers
  /// once the backend's simulated clock has advanced by this many milliseconds
  /// since S was committed.
  final int maxPropagationDelayMs;

  /// Random jitter in milliseconds added to each write's individual delay.
  ///
  /// Simulates realistic variation in per-write propagation time. The actual
  /// delay for a given write is sampled uniformly in
  /// `[0, maxPropagationDelayMs + jitterMs]`.
  final int jitterMs;
}

/// Extension getters for [ConsistencyModel] variants.
extension ConsistencyModelX on ConsistencyModel {
  /// Whether this is a strong-consistency model.
  bool get isStrong => this is StrongConsistency;

  /// Whether this is an eventual-consistency model.
  bool get isEventual => this is EventualConsistency;

  /// The max propagation delay in milliseconds (0 for strong consistency).
  int get maxPropagationDelayMs => switch (this) {
    StrongConsistency() => 0,
    EventualConsistency(maxPropagationDelayMs: final d) => d,
  };

  /// The jitter in milliseconds (0 for strong consistency).
  int get jitterMs => switch (this) {
    StrongConsistency() => 0,
    EventualConsistency(jitterMs: final j) => j,
  };
}

/// Quota parameters for a cloud backend.
///
/// **Descriptive only (D6).** This type parameterises the simulator's
/// rate-limit behaviour (429/503 responses) but does NOT introduce or require
/// a `kmdb`-side `QuotaAwareAdapter`. The harness `QuotaAwareAdapter`
/// (`safeOperationThreshold`) is a separate concern and is left untouched.
///
/// Provider packages supply concrete [QuotaProfile] instances as part of their
/// [CloudProfile] to control how the behavioural simulator emits rate-limit
/// responses.
final class QuotaProfile {
  /// Creates a [QuotaProfile].
  ///
  /// [maxOpsPerMinute] is the maximum number of sync operations (upload,
  /// download, list, CAS) the simulated backend allows per minute before
  /// returning a 429/503-equivalent error.
  ///
  /// [maxUploadBytesPerDay] is the daily upload-byte cap. `null` means
  /// unlimited.
  const QuotaProfile({
    required this.maxOpsPerMinute,
    this.maxUploadBytesPerDay,
  });

  /// A quota profile with no limits (simulator never injects 429/503).
  const QuotaProfile.unlimited()
    : maxOpsPerMinute = null,
      maxUploadBytesPerDay = null;

  /// Maximum operations per minute. `null` means unlimited.
  final int? maxOpsPerMinute;

  /// Maximum upload bytes per simulated day. `null` means unlimited.
  final int? maxUploadBytesPerDay;
}

/// Describes the observable behaviour of a cloud backend.
///
/// Each cloud provider ships a concrete [CloudProfile] instance alongside its
/// adapter and behavioural simulator. The harness consumes the profile to:
///
/// - configure the [CloudSemanticsAdapter] decorator (consistency,
///   duplicate-name rules, CAS atomicity);
/// - parameterise the reconciliation oracle's visibility model (via
///   [consistency]);
/// - drive the simulator's 429/503 injection (via [quota]).
///
/// ## CAS-atomicity rule
///
/// There is exactly one source of truth at runtime: the front-end's
/// `providesAtomicCas` getter. [atomicConditionalCreate] is the *declared*
/// value the simulator/decorator is built to honour; [CloudSemanticsAdapter]
/// sets `providesAtomicCas => profile.atomicConditionalCreate`. The conformance
/// suite (`runSyncAdapterConformance(expectAtomicCas: profile.atomicConditionalCreate)`)
/// ensures the two cannot drift.
///
/// ## Two built-in profiles
///
/// - [CloudProfile.strong()] — strongly consistent, atomic CAS, no duplicate
///   names, no quota. Equivalent to the existing single-[MemorySyncAdapter]
///   harness behaviour.
/// - [CloudProfile.eventual(maxPropagationDelayMs: N)] — eventually consistent,
///   non-atomic CAS (safe default for unknown providers), no duplicate names,
///   no quota. Use this for testing delayed-visibility scenarios.
///
/// Provider-specific profiles (e.g. a Drive profile with
/// `allowsDuplicateNames: true`) ship in their own packages.
final class CloudProfile {
  /// Creates a [CloudProfile].
  const CloudProfile({
    required this.consistency,
    required this.atomicConditionalCreate,
    this.allowsDuplicateNames = false,
    this.quota = const QuotaProfile.unlimited(),
  });

  /// A strongly-consistent profile (current harness baseline behaviour).
  ///
  /// - Strong consistency: all writes immediately visible.
  /// - Atomic CAS: exactly one winner under concurrent create-if-absent.
  /// - No duplicate names.
  /// - No quota limits.
  const CloudProfile.strong()
    : consistency = const StrongConsistency(),
      atomicConditionalCreate = true,
      allowsDuplicateNames = false,
      quota = const QuotaProfile.unlimited();

  /// An eventually-consistent profile with a bounded propagation delay.
  ///
  /// - Eventual consistency: writes become visible within
  ///   [maxPropagationDelayMs] milliseconds (plus optional [jitterMs]).
  /// - Non-atomic CAS: multiple concurrent create-if-absent callers may win
  ///   (safe default; [ConsolidationCoordinator] is gated on this).
  /// - No duplicate names.
  /// - No quota limits.
  CloudProfile.eventual({required int maxPropagationDelayMs, int jitterMs = 0})
    : consistency = EventualConsistency(
        maxPropagationDelayMs: maxPropagationDelayMs,
        jitterMs: jitterMs,
      ),
      atomicConditionalCreate = false,
      allowsDuplicateNames = false,
      quota = const QuotaProfile.unlimited();

  /// The consistency model of this backend.
  ///
  /// Drives the [CloudSemanticsAdapter]'s propagation simulation and the
  /// reconciliation oracle's visibility model.
  final ConsistencyModel consistency;

  /// Whether `compareAndSwap` is truly atomic on this backend.
  ///
  /// When `true`, the backend guarantees that for any given `(path, ifMatchEtag)`
  /// precondition, at most one concurrent caller observes success. When `false`,
  /// the [ConsolidationCoordinator] skips consolidation (per H5) to avoid
  /// split-lease data loss.
  ///
  /// [CloudSemanticsAdapter.providesAtomicCas] is set to this value. The
  /// conformance suite verifies the two cannot drift.
  final bool atomicConditionalCreate;

  /// Whether the backend permits multiple files with the same name in the same
  /// directory (e.g. Google Drive).
  ///
  /// When `true`, the simulator allows duplicate-name creation. The harness
  /// scenario tests that KMDB handles this correctly (e.g. by listing by
  /// unique ID, not name, when the adapter detects duplicates).
  ///
  /// `false` for all standard providers. `true` only for Drive-like systems.
  final bool allowsDuplicateNames;

  /// Quota parameters for the simulated backend (descriptive only, per D6).
  ///
  /// Parameterises the simulator's 429/503 injection. Does NOT affect the
  /// harness's `QuotaAwareAdapter` check.
  final QuotaProfile quota;
}
