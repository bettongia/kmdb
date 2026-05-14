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

import '../engine/util/hlc.dart';

/// Exception thrown when an incoming [Hlc] timestamp is so far ahead of the
/// local wall clock that it would corrupt the HLC ordering.
///
/// This guards against a device with a severely misconfigured clock (e.g. a
/// clock set years in the future) poisoning the timestamps in a shared
/// database. The default tolerance is 60 seconds (configurable via
/// [HlcClock.maxClockSkew]).
final class ClockSkewException implements Exception {
  const ClockSkewException({
    required this.received,
    required this.wallClockMs,
    required this.maxSkewMs,
  });

  /// The incoming timestamp that triggered the guard.
  final Hlc received;

  /// The local wall-clock time at the moment of the check, in milliseconds.
  final int wallClockMs;

  /// The configured maximum allowable skew, in milliseconds.
  final int maxSkewMs;

  @override
  String toString() =>
      'ClockSkewException: received ${received.toHex()} is '
      '${received.physicalMs - wallClockMs}ms ahead of local wall clock '
      '(max allowed: ${maxSkewMs}ms)';
}

/// Per-database Hybrid Logical Clock.
///
/// [HlcClock] maintains the current [Hlc] value for a single database
/// instance. It is not a process-wide singleton — each [KvStore] instance
/// owns one clock, ensuring that separate databases do not share state.
///
/// ## Usage
///
/// ```dart
/// final clock = HlcClock();
///
/// // Before writing a WAL record:
/// final ts = clock.now();
///
/// // When ingesting a remote SSTable or replaying a WAL on recovery:
/// clock.update(remoteHlc);
/// ```
///
/// ## Thread safety
///
/// All operations run synchronously on the calling isolate. The LSM engine
/// uses no background isolates (§18), so no locking is required.
final class HlcClock {
  /// Creates an [HlcClock].
  ///
  /// [wallClock] is injectable for testing (default: [DateTime.now]).
  /// [maxClockSkew] defaults to 60 seconds as specified in §4 (KvStoreConfig).
  HlcClock({
    int Function()? wallClock,
    Duration maxClockSkew = const Duration(seconds: 60),
  }) : _wallClock = wallClock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _maxSkewMs = maxClockSkew.inMilliseconds,
       // Start at (0, 0) so that the first now() call always advances to the
       // wall clock time. Recovery code is responsible for calling
       // update(storedHwm) after open() to fast-forward past the stored HWM.
       _current = const Hlc(0, 0);

  final int Function() _wallClock;
  final int _maxSkewMs;
  Hlc _current;

  /// Returns the current [Hlc] value without advancing it.
  Hlc get current => _current;

  /// Advances the clock by one tick for a local event and returns the new [Hlc].
  ///
  /// The new timestamp is always strictly greater than both the previous [Hlc]
  /// and the current wall-clock time, ensuring monotonicity.
  Hlc now() {
    final wallMs = _wallClock() & 0xFFFFFFFFFFFF;
    final prevPhysical = _current.physicalMs;
    final prevLogical = _current.logical;

    if (wallMs > prevPhysical) {
      // Wall clock has advanced: reset logical counter.
      _current = Hlc(wallMs, 0);
    } else {
      // Same millisecond or clock regression: increment logical counter.
      // If the logical counter would overflow 16 bits, wait until the wall
      // clock advances (in practice this requires >65535 events/ms, which
      // KMDB's synchronous write path cannot produce).
      final newLogical = prevLogical + 1;
      if (newLogical > 0xFFFF) {
        // Spin until wall clock advances. This should never be reached
        // under normal operation.
        final advanced = _waitForClockAdvance(prevPhysical);
        _current = Hlc(advanced, 0);
      } else {
        _current = Hlc(prevPhysical, newLogical);
      }
    }
    return _current;
  }

  /// Updates the clock when receiving a remote [Hlc] (WAL replay or SSTable
  /// ingestion), and returns the new local [Hlc].
  ///
  /// Ensures the local clock is at least as recent as the remote event,
  /// preserving causality. Throws [ClockSkewException] if [received] is more
  /// than [maxClockSkew] ahead of the local wall clock.
  Hlc update(Hlc received) {
    final wallMs = _wallClock() & 0xFFFFFFFFFFFF;

    // Guard against a device with a clock set far in the future corrupting
    // the HLC ordering for all other devices.
    if (received.physicalMs > wallMs + _maxSkewMs) {
      throw ClockSkewException(
        received: received,
        wallClockMs: wallMs,
        maxSkewMs: _maxSkewMs,
      );
    }

    final prevPhysical = _current.physicalMs;
    final prevLogical = _current.logical;
    final remPhysical = received.physicalMs;
    final remLogical = received.logical;

    final int newPhysical;
    final int newLogical;

    if (wallMs > prevPhysical && wallMs > remPhysical) {
      // Wall clock is newest: advance to it.
      newPhysical = wallMs;
      newLogical = 0;
    } else if (remPhysical > prevPhysical) {
      // Remote is newest: adopt remote physical, increment its logical.
      newPhysical = remPhysical;
      newLogical = remLogical + 1;
    } else if (prevPhysical > remPhysical) {
      // Local is newest: keep local physical, increment local logical.
      newPhysical = prevPhysical;
      newLogical = prevLogical + 1;
    } else {
      // Physical times are equal: take max logical + 1.
      newPhysical = prevPhysical;
      newLogical = (prevLogical > remLogical ? prevLogical : remLogical) + 1;
    }

    _current = Hlc(newPhysical & 0xFFFFFFFFFFFF, newLogical & 0xFFFF);
    return _current;
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  /// Spins synchronously until the wall clock advances past [physical].
  ///
  /// Only called when the logical counter would overflow (>65535 events/ms),
  /// which cannot occur under KMDB's synchronous write model.
  int _waitForClockAdvance(int physical) {
    int wall;
    do {
      wall = _wallClock() & 0xFFFFFFFFFFFF;
    } while (wall <= physical);
    return wall;
  }
}
