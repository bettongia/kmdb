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

import 'package:kmdb/kmdb.dart';

/// Ratios governing how document keys are distributed across three pools.
///
/// The three pools serve distinct test purposes:
/// - **shared**: Keys distributed to all devices; writes deliberately collide
///   for LWW (Last-Write-Wins) conflict testing.
/// - **deviceLocal**: Keys owned by a single device; tests non-conflicting
///   write arrival on peers.
/// - **hot**: A small shared subset written at high frequency; exercises
///   clock-skew tolerance and rapid-succession scenarios.
///
/// The three ratios must sum to 100.
final class KeyPoolRatios {
  /// Creates [KeyPoolRatios] with the given percentages.
  ///
  /// [shared], [deviceLocal], and [hot] must be non-negative and must sum
  /// to exactly 100.
  const KeyPoolRatios({
    required this.shared,
    required this.deviceLocal,
    required this.hot,
  }) : assert(
         shared >= 0 && deviceLocal >= 0 && hot >= 0,
         'All ratios must be non-negative',
       ),
       assert(
         shared + deviceLocal + hot == 100,
         'Key pool ratios must sum to 100',
       );

  /// The default 50/40/10 key pool distribution.
  const KeyPoolRatios.defaults() : shared = 50, deviceLocal = 40, hot = 10;

  /// Percentage of keys in the shared pool (LWW collision targets).
  final int shared;

  /// Percentage of keys in the device-local pool (non-conflicting writes).
  final int deviceLocal;

  /// Percentage of keys in the hot pool (high-frequency writes).
  final int hot;
}

/// Distribution of document sizes across three tiers.
///
/// Size tiers determine how large the generated document bodies are:
/// - **small**: ~100 bytes encoded; short `body` string.
/// - **medium**: ~10 KB encoded; long `body` string.
/// - **large**: ~500 KB encoded; very long `body` string.
///
/// The three percentages must sum to 100.
final class DocSizeDistribution {
  /// Creates a [DocSizeDistribution] with the given percentages.
  ///
  /// [small], [medium], and [large] must be non-negative and must sum to 100.
  const DocSizeDistribution({
    required this.small,
    required this.medium,
    required this.large,
  }) : assert(
         small >= 0 && medium >= 0 && large >= 0,
         'All percentages must be non-negative',
       ),
       assert(
         small + medium + large == 100,
         'DocSizeDistribution percentages must sum to 100',
       );

  /// The default 60/30/10 document size distribution.
  const DocSizeDistribution.defaults() : small = 60, medium = 30, large = 10;

  /// Percentage of documents in the small tier (~100 B).
  final int small;

  /// Percentage of documents in the medium tier (~10 KB).
  final int medium;

  /// Percentage of documents in the large tier (~500 KB).
  final int large;
}

/// Velocity preset index, controlling the rate and concurrency of actions.
///
/// Presets are convenience shorthands that expand to specific
/// [actionsPerMinute], [simultaneousDevices], [syncIntervalSeconds], and
/// [syncAfterWrites] values when applied to a [HarnessConfig].
enum VelocityPreset {
  /// Preset 1 — 2 actions/min, 1 device, sync every 300 s or 20 writes.
  one,

  /// Preset 2 — 5 actions/min, 1–2 devices, sync every 120 s or 15 writes.
  two,

  /// Preset 3 — 10 actions/min, ⌊N/2⌋ devices, sync every 60 s or 10 writes.
  three,

  /// Preset 4 — 30 actions/min, N−1 devices, sync every 30 s or 5 writes.
  four,

  /// Preset 5 — 120 actions/min, all N devices (parallel isolates), sync every
  /// 10 s or 3 writes. Non-deterministic; flakiness detection not applicable.
  five,
}

/// Harness configuration for a single test run.
///
/// At least one of [syncIntervalSeconds] or [syncAfterWrites] must be set
/// (either directly or via [velocityPreset]).
///
/// ## Example — preset 1 configuration
///
/// ```dart
/// final config = HarnessConfig(
///   syncAdapter: MemorySyncAdapter(),
///   velocityPreset: VelocityPreset.one,
/// );
/// ```
///
/// ## Example — manual knobs (no preset)
///
/// ```dart
/// final config = HarnessConfig(
///   syncAdapter: MemorySyncAdapter(),
///   deviceCount: 2,
///   actionsPerMinute: 5,
///   simultaneousDevices: 2,
///   syncIntervalSeconds: 60,
///   syncAfterWrites: 10,
/// );
/// ```
final class HarnessConfig {
  /// Creates a [HarnessConfig].
  ///
  /// Either supply a [velocityPreset] (which expands to concrete values for
  /// [actionsPerMinute], [simultaneousDevices], [syncIntervalSeconds], and
  /// [syncAfterWrites]) or supply those values directly. Direct values override
  /// preset values. When [velocityPreset] is `null`, all knobs must be provided
  /// manually.
  ///
  /// Throws [ArgumentError] if neither a sync interval nor a sync-after-writes
  /// value can be resolved from the preset and overrides.
  HarnessConfig({
    required this.syncAdapter,
    this.deviceCount = 3,
    this.preSeededDeviceCount = 1,
    this.collectionCount = 10,
    this.duration = const Duration(minutes: 10),
    this.velocityPreset,
    int? actionsPerMinute,
    int? simultaneousDevices,
    int? syncIntervalSeconds,
    int? syncAfterWrites,
    this.prngseed,
    this.keyPoolRatios = const KeyPoolRatios.defaults(),
    this.docSizeDistribution = const DocSizeDistribution.defaults(),
  }) {
    // Expand the velocity preset first, then apply any direct overrides.
    final expanded = _expandPreset(velocityPreset, deviceCount);
    _actionsPerMinute =
        actionsPerMinute ?? expanded.actionsPerMinute ?? _defaultActionsPerMin;
    _simultaneousDevices =
        simultaneousDevices ??
        expanded.simultaneousDevices ??
        _defaultSimultaneous(deviceCount);
    _syncIntervalSeconds = syncIntervalSeconds ?? expanded.syncIntervalSeconds;
    _syncAfterWrites = syncAfterWrites ?? expanded.syncAfterWrites;

    // Validate that at least one sync trigger is configured.
    if (_syncIntervalSeconds == null && _syncAfterWrites == null) {
      throw ArgumentError(
        'At least one of syncIntervalSeconds or syncAfterWrites must be set. '
        'Supply a velocityPreset or set one of these values directly.',
      );
    }

    // Validate structural consistency.
    if (deviceCount < 1) {
      throw ArgumentError('deviceCount must be at least 1');
    }
    if (preSeededDeviceCount < 0 || preSeededDeviceCount > deviceCount) {
      throw ArgumentError(
        'preSeededDeviceCount must be between 0 and deviceCount ($deviceCount)',
      );
    }
    if (collectionCount < 1) {
      throw ArgumentError('collectionCount must be at least 1');
    }
    if (_actionsPerMinute < 1) {
      throw ArgumentError('actionsPerMinute must be at least 1');
    }
    if (_simultaneousDevices < 1 || _simultaneousDevices > deviceCount) {
      throw ArgumentError(
        'simultaneousDevices must be between 1 and deviceCount ($deviceCount)',
      );
    }
    final interval = _syncIntervalSeconds;
    if (interval != null && interval < 1) {
      throw ArgumentError('syncIntervalSeconds must be at least 1');
    }
    final afterWrites = _syncAfterWrites;
    if (afterWrites != null && afterWrites < 1) {
      throw ArgumentError('syncAfterWrites must be at least 1');
    }
  }

  /// The remote sync storage adapter used by all devices in the harness.
  ///
  /// All device instances share a single adapter reference (single-isolate
  /// design). Use [MemorySyncAdapter] for in-process tests.
  final SyncStorageAdapter syncAdapter;

  /// Total number of simulated devices. Defaults to 3.
  final int deviceCount;

  /// Number of devices that are pre-seeded with data before the run starts.
  ///
  /// Pre-seeded devices report their initial state to the
  /// [ReconciliationAgent] before the run loop begins, establishing a correct
  /// baseline for expected-state computation.
  final int preSeededDeviceCount;

  /// Number of collections created on each device. Defaults to 10.
  final int collectionCount;

  /// Total duration of the test run. Defaults to 10 minutes.
  final Duration duration;

  /// The velocity preset to expand. When `null`, all knobs must be supplied
  /// directly.
  ///
  /// Preset values are overridden by any directly-supplied knobs.
  final VelocityPreset? velocityPreset;

  /// Optional fixed PRNG seed for deterministic replay.
  ///
  /// When `null`, the seed is derived from the system clock at start time
  /// (fuzz mode). The seed used is always recorded in the [HarnessReport].
  final int? prngseed;

  /// Key pool ratios. Defaults to 50/40/10 (shared/device-local/hot).
  final KeyPoolRatios keyPoolRatios;

  /// Document size distribution. Defaults to 60/30/10 (small/medium/large).
  final DocSizeDistribution docSizeDistribution;

  // Resolved values (preset + overrides).
  late final int _actionsPerMinute;
  late final int _simultaneousDevices;
  late final int? _syncIntervalSeconds;
  late final int? _syncAfterWrites;

  /// Actions generated per minute per active device.
  int get actionsPerMinute => _actionsPerMinute;

  /// Maximum number of devices active concurrently during the run loop.
  int get simultaneousDevices => _simultaneousDevices;

  /// Seconds between time-driven sync triggers. `null` if not set.
  int? get syncIntervalSeconds => _syncIntervalSeconds;

  /// Number of writes that trigger a sync. `null` if not set.
  int? get syncAfterWrites => _syncAfterWrites;

  // ── Internal defaults ────────────────────────────────────────────────────

  static const int _defaultActionsPerMin = 10;
  static int _defaultSimultaneous(int deviceCount) =>
      (deviceCount / 2).floor().clamp(1, deviceCount);
}

// ── Preset expansion ─────────────────────────────────────────────────────────

/// Resolved velocity values from a preset.
final class _PresetValues {
  const _PresetValues({
    this.actionsPerMinute,
    this.simultaneousDevices,
    this.syncIntervalSeconds,
    this.syncAfterWrites,
  });

  final int? actionsPerMinute;
  final int? simultaneousDevices;
  final int? syncIntervalSeconds;
  final int? syncAfterWrites;
}

/// Expands a [VelocityPreset] into concrete knob values.
///
/// Returns empty [_PresetValues] when [preset] is `null`.
/// [deviceCount] is used to compute the device-count-dependent values for
/// presets 3 and 4.
_PresetValues _expandPreset(VelocityPreset? preset, int deviceCount) {
  if (preset == null) return const _PresetValues();
  switch (preset) {
    case VelocityPreset.one:
      return const _PresetValues(
        actionsPerMinute: 2,
        simultaneousDevices: 1,
        syncIntervalSeconds: 300,
        syncAfterWrites: 20,
      );
    case VelocityPreset.two:
      return const _PresetValues(
        actionsPerMinute: 5,
        simultaneousDevices: 2,
        syncIntervalSeconds: 120,
        syncAfterWrites: 15,
      );
    case VelocityPreset.three:
      return _PresetValues(
        actionsPerMinute: 10,
        simultaneousDevices: (deviceCount / 2).floor().clamp(1, deviceCount),
        syncIntervalSeconds: 60,
        syncAfterWrites: 10,
      );
    case VelocityPreset.four:
      return _PresetValues(
        actionsPerMinute: 30,
        simultaneousDevices: (deviceCount - 1).clamp(1, deviceCount),
        syncIntervalSeconds: 30,
        syncAfterWrites: 5,
      );
    case VelocityPreset.five:
      return _PresetValues(
        actionsPerMinute: 120,
        simultaneousDevices: deviceCount,
        syncIntervalSeconds: 10,
        syncAfterWrites: 3,
      );
  }
}
