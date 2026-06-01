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

import 'package:kmdb/src/engine/compaction/merge_iterator.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/engine/util/key_codec.dart';
import 'package:kmdb/src/versioning/version_config.dart';
import 'package:kmdb/src/versioning/version_entry.dart' show VersionEntry;
import 'package:kmdb/src/versioning/version_retention_policy.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _kMsPerDay = 24 * 60 * 60 * 1000;

/// Builds a [MergeEntry] for a put-version at [hlcMs].
///
/// The value contains a minimal [VersionEntry] payload with `isDelete: false`.
MergeEntry _putEntry(int hlcMs, {int logical = 0}) {
  final hlc = Hlc(hlcMs, logical);
  // Use a fixed UUIDv7 key — the exact value doesn't matter for policy tests.
  const hex = '01930000000070008000000000000001';
  final key = KeyCodec.encodeInternalKey(
    r'$ver:tasks',
    KeyCodec.keyToBytes(hex),
    hlc,
    RecordType.put,
  );
  // Encode a minimal VersionEntry so _isDeleteVersion can decode it correctly.
  final value = VersionEntry(
    hlc: const Hlc(0, 0),
    encodedValue: null, // minimally valid put-version
    isDelete: false,
  ).encode();
  return MergeEntry(key, value, source: 0);
}

/// Builds a [MergeEntry] for a delete-version at [hlcMs].
///
/// In the real system `$ver:` entries are ALWAYS stored with [RecordType.put] —
/// the delete flag lives in the [VersionEntry] payload (see
/// [VersionRetentionPolicy._isDeleteVersion]). This helper matches that
/// behaviour: the internal key uses [RecordType.put] and the value contains a
/// [VersionEntry] with `isDelete: true`.
MergeEntry _deleteEntry(int hlcMs, {int logical = 0}) {
  final hlc = Hlc(hlcMs, logical);
  const hex = '01930000000070008000000000000001';
  final key = KeyCodec.encodeInternalKey(
    r'$ver:tasks',
    KeyCodec.keyToBytes(hex),
    hlc,
    RecordType.put, // delete-versions are stored as put in the $ver: namespace
  );
  final value = VersionEntry(
    hlc: const Hlc(0, 0),
    encodedValue: null,
    isDelete: true,
  ).encode();
  return MergeEntry(key, value, source: 0);
}

// Sorted ascending HLC (oldest first), as the compaction merge produces.
List<MergeEntry> _entriesAt(List<int> msList, {bool lastIsDelete = false}) {
  final entries = <MergeEntry>[];
  for (var i = 0; i < msList.length; i++) {
    final isLast = i == msList.length - 1;
    if (isLast && lastIsDelete) {
      entries.add(_deleteEntry(msList[i]));
    } else {
      entries.add(_putEntry(msList[i]));
    }
  }
  return entries;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('VersionRetentionPolicy.filterGroup', () {
    // ── Keep-N boundary ───────────────────────────────────────────────────────

    test('keep-N retains exactly maxVersions entries (count boundary)', () {
      const policy = VersionRetentionPolicy(VersionConfig(maxVersions: 3));
      // 5 versions; only 3 should be kept (newest 3).
      final now = 5000 * _kMsPerDay;
      final entries = _entriesAt([100, 200, 300, 400, 500]);
      final kept = policy.filterGroup(entries, nowMs: now);
      // Kept entries are sorted ascending; the newest 3 are at ms 300, 400, 500.
      expect(kept.length, equals(3));
      final keptMs = kept.map((e) => KeyCodec.decodeHlc(e.key).physicalMs);
      expect(keptMs, containsAll([300, 400, 500]));
    });

    test('keep-N always retains the newest entry (rank 1)', () {
      // Even with maxVersions: 1, the newest entry is always kept.
      const policy = VersionRetentionPolicy(VersionConfig(maxVersions: 1));
      final now = 5000 * _kMsPerDay;
      final entries = _entriesAt([100, 200, 300]);
      final kept = policy.filterGroup(entries, nowMs: now);
      expect(kept.length, equals(1));
      expect(KeyCodec.decodeHlc(kept.single.key).physicalMs, equals(300));
    });

    test('fewer entries than maxVersions: all retained', () {
      const policy = VersionRetentionPolicy(VersionConfig(maxVersions: 10));
      final now = 5000 * _kMsPerDay;
      final entries = _entriesAt([100, 200, 300]);
      final kept = policy.filterGroup(entries, nowMs: now);
      expect(kept.length, equals(3));
    });

    test('empty entries: returns empty', () {
      const policy = VersionRetentionPolicy(VersionConfig.defaults);
      final kept = policy.filterGroup([], nowMs: 1000);
      expect(kept, isEmpty);
    });

    // ── RetentionDays boundary ────────────────────────────────────────────────

    test('retentionDays window retains recent entries', () {
      // retentionDays: 30 → entries within 30 days of nowMs are kept.
      const policy = VersionRetentionPolicy(
        VersionConfig(maxVersions: null, retentionDays: 30),
      );
      final now = 100 * _kMsPerDay;
      // Entries at 60, 80, 90 days ago relative to now: 40, 20, 10 days old.
      final entries = _entriesAt([
        (now - 60 * _kMsPerDay).clamp(0, 9007199254740991),
        (now - 20 * _kMsPerDay).clamp(0, 9007199254740991),
        (now - 10 * _kMsPerDay).clamp(0, 9007199254740991),
      ]);
      final kept = policy.filterGroup(entries, nowMs: now);
      // Entry 60 days old is outside 30-day window; but newest entry is always
      // kept. So entries at 20 and 10 days old are kept (within window),
      // plus the newest (10 days) as rank 1.
      // Entry at 60 days: age=60 days > 30 days, rank=3 (not rank 1) → dropped.
      // Entry at 20 days: age=20 days <= 30 days → kept.
      // Entry at 10 days: age=10 days <= 30 days, rank=1 → kept.
      expect(kept.length, equals(2));
    });

    test('null retentionDays + null maxVersions: all retained', () {
      const policy = VersionRetentionPolicy(
        VersionConfig(maxVersions: null, retentionDays: null),
      );
      final now = 100 * _kMsPerDay;
      final entries = _entriesAt([100, 200, 300, 400]);
      expect(policy.filterGroup(entries, nowMs: now).length, equals(4));
    });

    // ── Combined keep-N + retentionDays ───────────────────────────────────────

    test('either condition retains entry (keep-N OR window)', () {
      // maxVersions: 2, retentionDays: 10
      const policy = VersionRetentionPolicy(
        VersionConfig(maxVersions: 2, retentionDays: 10),
      );
      final now = 100 * _kMsPerDay;
      // 5 versions: 95, 91, 85, 50, 1 days ago (sorted ascending by ms).
      final entries = _entriesAt([
        (now - 95 * _kMsPerDay).clamp(0, 9007199254740991),
        (now - 91 * _kMsPerDay).clamp(0, 9007199254740991),
        (now - 85 * _kMsPerDay).clamp(0, 9007199254740991),
        (now - 50 * _kMsPerDay).clamp(0, 9007199254740991),
        (now - 1 * _kMsPerDay).clamp(0, 9007199254740991),
      ]);
      final kept = policy.filterGroup(entries, nowMs: now);
      // Rank 1 (1 day ago): always kept.
      // Rank 2 (50 days ago): within maxVersions=2 → kept.
      // Rank 3 (85 days ago): rank=3 > maxVersions=2, age=85 > 10 → dropped.
      // Rank 4 (91 days ago): dropped.
      // Rank 5 (95 days ago): dropped.
      expect(kept.length, equals(2));
    });

    // ── Post-delete full purge ────────────────────────────────────────────────

    test('delete-version older than retentionDays triggers full purge', () {
      const policy = VersionRetentionPolicy(
        VersionConfig(maxVersions: 4, retentionDays: 30),
      );
      final now = 100 * _kMsPerDay;
      // Delete-version is 31 days old — past grace window.
      final deleteMs = now - 31 * _kMsPerDay;
      final entries = _entriesAt([
        (now - 50 * _kMsPerDay).clamp(0, 9007199254740991),
        (now - 40 * _kMsPerDay).clamp(0, 9007199254740991),
        deleteMs.clamp(0, 9007199254740991),
      ], lastIsDelete: true);
      final kept = policy.filterGroup(entries, nowMs: now);
      expect(kept, isEmpty, reason: 'post-delete grace expired → full purge');
    });

    test('delete-version within retentionDays keeps the chain', () {
      const policy = VersionRetentionPolicy(
        VersionConfig(maxVersions: 2, retentionDays: 30),
      );
      final now = 100 * _kMsPerDay;
      // Delete-version is only 10 days old — within grace window.
      final deleteMs = now - 10 * _kMsPerDay;
      final entries = _entriesAt([
        (now - 50 * _kMsPerDay).clamp(0, 9007199254740991),
        (now - 20 * _kMsPerDay).clamp(0, 9007199254740991),
        deleteMs.clamp(0, 9007199254740991),
      ], lastIsDelete: true);
      final kept = policy.filterGroup(entries, nowMs: now);
      // Delete-version within grace → apply keep-N rules.
      // Rank 1 (delete, 10 days ago): always kept.
      // Rank 2 (put, 20 days ago): within window → kept.
      // Rank 3 (put, 50 days ago): rank=3 > maxVersions=2, age=50 > 30 → dropped.
      expect(kept.length, equals(2));
    });

    test('disabled config: filterGroup drops all entries', () {
      const policy = VersionRetentionPolicy(VersionConfig.disabled);
      final now = 100 * _kMsPerDay;
      final entries = _entriesAt([100, 200, 300]);
      expect(policy.filterGroup(entries, nowMs: now), isEmpty);
    });

    // ── collapseVersions and dropTombstone ────────────────────────────────────

    test('collapseVersions is false', () {
      const policy = VersionRetentionPolicy(VersionConfig.defaults);
      expect(policy.collapseVersions, isFalse);
    });

    test('dropTombstone always returns false', () {
      const policy = VersionRetentionPolicy(VersionConfig.defaults);
      expect(
        policy.dropTombstone(
          allLevels: true,
          tombstoneHlc: const Hlc(1, 0),
          horizon: const Hlc(999999, 0),
        ),
        isFalse,
      );
    });
  });
}
