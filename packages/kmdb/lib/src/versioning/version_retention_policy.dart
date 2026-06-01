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

import '../engine/compaction/merge_iterator.dart' show MergeEntry;
import '../engine/compaction/reclamation_policy.dart';
import '../engine/util/hlc.dart';
import '../engine/util/key_codec.dart' show KeyCodec;
import 'version_config.dart';
import 'version_entry.dart' show VersionEntry;

/// Compaction-time retention policy for `$ver:{collection}` namespaces.
///
/// Implements the keep-N / retentionDays trim rules specified in §26:
///
/// - `collapseVersions = false` — multiple versions of the same doc key are
///   never collapsed (each HLC-differentiated entry is preserved by default,
///   subject only to [filterGroup]).
/// - `dropTombstone` returns `false` — version tombstones (delete-version
///   entries) are not subject to H4 tombstone GC.
/// - [filterGroup] applies the keep-N floor and retentionDays window trim:
///   - For **live documents** (newest entry is a put-version): keep entries
///     satisfying `rank <= maxVersions || (nowMs - hlcMs) <= retentionDays × 86_400_000`.
///     The newest entry is always rank 1 and is never dropped.
///   - For **deleted documents** (newest entry is a delete-version): if the
///     delete-version's age exceeds `retentionDays`, return an empty list
///     (full post-delete purge). Otherwise apply the live-document rules.
///
/// ## Keep-N floor for live documents
///
/// The keep-N floor is a **minimum** guarantee: even if a version entry is
/// older than `retentionDays`, it is retained while `rank <= maxVersions`.
/// This prevents silent discard of any version that is still "in the window"
/// by count (e.g. the 4th version of a document last written 6 months ago).
///
/// ## Post-delete full purge
///
/// Once a document is deleted (`isNewestDelete = true` and the delete-version
/// is older than `retentionDays`), the keep-N floor is lifted. The whole
/// `$ver:` chain — every put-version *and* the delete-version — is dropped in
/// a single compaction pass, ensuring deleted documents drain to zero residue.
///
/// ## Clock injection
///
/// [nowMs] is passed from the caller ([LsmEngine._compactAll]) at
/// job-construction time (`DateTime.now().millisecondsSinceEpoch`). This
/// method never calls `DateTime.now()` internally, matching the RQ6 clock-
/// injection pattern so tests can supply a fixed clock.
final class VersionRetentionPolicy implements ReclamationPolicy {
  /// Creates a [VersionRetentionPolicy] for [config].
  const VersionRetentionPolicy(this.config);

  /// The [VersionConfig] governing trim behaviour for this namespace.
  final VersionConfig config;

  // ── ReclamationPolicy ────────────────────────────────────────────────────

  @override
  bool get collapseVersions => false;

  @override
  bool dropTombstone({
    required bool allLevels,
    required Hlc tombstoneHlc,
    required Hlc horizon,
  }) => false; // Version tombstones are history entries, not main-namespace tombstones.

  @override
  List<MergeEntry> filterGroup(List<MergeEntry> entries, {required int nowMs}) {
    if (entries.isEmpty) return entries;

    final maxVersions = config.maxVersions;
    final retentionDays = config.retentionDays;

    // If versioning is fully disabled (maxVersions: 0, no retentionDays),
    // drop everything. This handles the edge case where a collection was
    // previously enabled, had entries written, and was later disabled.
    if (config.isDisabled) return const [];

    // Entries arrive sorted HLC ascending (oldest first) from the merge
    // iterator. Find the newest entry (last in list).
    final newestEntry = entries.last;
    // Detect delete-versions by decoding the VersionEntry payload. Unlike
    // main-namespace entries, $ver: entries are ALWAYS stored as RecordType.put
    // regardless of whether they represent a put-version or a delete-version;
    // the actual delete flag lives in the VersionEntry.isDelete field. We
    // therefore cannot rely on the record type in the internal key here.
    final newestIsDelete = _isDeleteVersion(newestEntry);
    final newestHlc = KeyCodec.decodeHlc(newestEntry.key);
    final newestAgeMs = nowMs - newestHlc.physicalMs;

    // ── Post-delete full purge ────────────────────────────────────────────────
    //
    // If the newest entry is a delete-version and its age exceeds retentionDays,
    // drop the entire chain. The keep-N floor does not apply to deleted docs.
    if (newestIsDelete && retentionDays != null) {
      final retentionMs = retentionDays * _kMsPerDay;
      if (newestAgeMs > retentionMs) {
        // Entire chain is eligible for purge (post-delete grace expired).
        return const [];
      }
    }
    // If oldest entry is a delete-version with no retentionDays, retain all
    // (no time-window trimming defined, and keep-N floor still applies).

    // ── Live-document or within-grace-period trim ─────────────────────────────
    //
    // Sort entries by HLC descending (newest first) for rank assignment.
    // We work on a copy to avoid mutating the input list.
    final sorted = entries.toList()
      ..sort(
        (a, b) =>
            KeyCodec.decodeHlc(b.key).compareTo(KeyCodec.decodeHlc(a.key)),
      );

    final retentionMs = retentionDays != null
        ? retentionDays * _kMsPerDay
        : null;

    // Whether there are any active constraints (count or window).
    // When neither is set, all entries are retained (no-op policy).
    // Assign to non-nullable locals so the null-check is visible to the
    // type checker and avoids redundant `!` operators in the loop.
    final hasCountConstraint = maxVersions != null;
    final hasWindowConstraint = retentionMs != null;
    final effectiveMaxVersions =
        maxVersions ?? 0; // only used when hasCountConstraint
    final effectiveRetentionMs =
        retentionMs ?? 0; // only used when hasWindowConstraint

    final retained = <MergeEntry>[];
    for (var rank = 1; rank <= sorted.length; rank++) {
      final entry = sorted[rank - 1];
      final hlc = KeyCodec.decodeHlc(entry.key);
      final ageMs = nowMs - hlc.physicalMs;

      // The newest entry (rank 1) is ALWAYS retained (it is the current state).
      final isNewest = rank == 1;

      if (isNewest) {
        retained.add(entry);
        continue;
      }

      // If no constraints are active, retain everything.
      if (!hasCountConstraint && !hasWindowConstraint) {
        retained.add(entry);
        continue;
      }

      // Rule: retain if EITHER active condition holds.
      //
      // - withinCount: count constraint is active AND this rank is within it.
      //   null maxVersions means "no count ceiling" → count condition inactive.
      // - withinWindow: window constraint is active AND age is within window.
      //   null retentionDays means "no window" → window condition inactive.
      //
      // Having both set means "keep if rank ≤ N OR age ≤ D" (more permissive).
      // Having only one set means "keep if that one condition is met".
      final withinCount = hasCountConstraint && rank <= effectiveMaxVersions;
      final withinWindow = hasWindowConstraint && ageMs <= effectiveRetentionMs;

      if (withinCount || withinWindow) {
        retained.add(entry);
      }
    }

    // Re-sort ascending (oldest first) to match the compaction's expected order.
    retained.sort(
      (a, b) => KeyCodec.decodeHlc(a.key).compareTo(KeyCodec.decodeHlc(b.key)),
    );

    return retained;
  }

  /// Returns `true` if [entry] is a delete-version.
  ///
  /// `$ver:` entries are ALWAYS stored with [RecordType.put] in the internal
  /// key — including delete-versions. The actual delete flag lives inside the
  /// [VersionEntry] payload. This helper decodes the payload and checks
  /// [VersionEntry.isDelete]. Returns `false` on any decode failure (fail-safe:
  /// treat as a live version so it is not incorrectly purged).
  static bool _isDeleteVersion(MergeEntry entry) {
    if (entry.value.isEmpty) return false;
    try {
      final ve = VersionEntry.decode(entry.value);
      return ve.isDelete;
    } catch (_) {
      // Defensive: malformed entry is treated as a put-version (not deleted).
      return false;
    }
  }

  /// Milliseconds per day (used for retentionDays → ms conversion).
  static const int _kMsPerDay = 24 * 60 * 60 * 1000;
}
