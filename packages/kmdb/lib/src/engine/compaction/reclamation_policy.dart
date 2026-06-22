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

import '../util/hlc.dart';
import 'merge_iterator.dart' show MergeEntry;

/// Per-namespace-class reclamation policy applied by compaction's streaming
/// transform.
///
/// PR1 of H4 (`plan_compaction_reclamation.md`) introduced **version
/// collapse**: when compaction streams the merged input entries, each
/// `(namespace, userKey)` group is collapsed to its highest-HLC entry —
/// safe at any compaction level because the read path re-merges all levels
/// and Last-Write-Wins on HLC.
///
/// A namespace whose [collapseVersions] is `false` is exempt from collapse
/// and passes every version through unchanged. This is reserved for
/// history-bearing namespace classes — currently the future `$ver:`
/// document-versioning namespaces, which supply their own keep-N /
/// retention predicate at compaction time once that feature lands.
///
/// PR2 of H4 (`plan_tombstone_gc.md`) extends this interface with the
/// [dropTombstone] predicate, gated by `allLevels` coverage and a sync
/// horizon. The two safety conditions a tombstone must satisfy before
/// compaction may drop it:
///
/// 1. **`allLevels` coverage:** the compaction must cover every level that
///    could hold an older version of the key. KMDB levels do *not* imply
///    recency (sync ingest places old-HLC data into L0), so partial
///    compactions (`_compactL0ToL1`, `_compactL1ToL2`) must never drop
///    tombstones. Only the single-file `_compactAll` path can.
/// 2. **Past the sync horizon:** every device must have already observed
///    the delete. The horizon is `min(currentHlc)` across all `.hwm` files
///    on a synced database, and `now - tombstoneGraceDuration` on a
///    local-only database. The grace window protects the local → synced
///    transition: a previously-local DB that has GC'd tombstones can
///    resurrect deleted data on first sync if a peer still holds an older
///    copy, so the horizon must always be a real point in the past — never
///    "now".
abstract interface class ReclamationPolicy {
  /// Whether compaction may collapse multiple versions of a single
  /// `(namespace, userKey)` group down to the highest-HLC entry.
  ///
  /// Returns `true` for current-state namespaces (the vast majority) and
  /// `false` for history-bearing namespaces such as `$ver:`.
  bool get collapseVersions;

  /// Whether compaction may drop a group's surviving delete tombstone.
  ///
  /// Consulted only when [collapseVersions] is `true` and the latest entry
  /// of the group is a tombstone. Implementations must return `true` only
  /// when **both** safety conditions hold: [allLevels] is `true` (the
  /// compaction covers every level that could hold an older version) and
  /// [tombstoneHlc] is strictly below [horizon] (every device has observed
  /// the delete). See the class doc for the safety analysis.
  bool dropTombstone({
    required bool allLevels,
    required Hlc tombstoneHlc,
    required Hlc horizon,
  });

  /// Called with the full version list for one `(namespace, userKey)` group,
  /// sorted HLC ascending (oldest first), when [collapseVersions] is `false`.
  ///
  /// Returns the entries to retain (a subset of [entries], in the same
  /// ascending-HLC order). The compaction job appends the dropped entries'
  /// raw value bytes to [CompactionJob.droppedVersionValues] so the engine
  /// can release vault ref counts after committing.
  ///
  /// [nowMs] is the wall-clock time at job-construction time
  /// (`DateTime.now().millisecondsSinceEpoch`), injected by [LsmEngine]
  /// rather than read inside this method — this matches the RQ6 clock-
  /// injection pattern so tests can supply a fixed clock.
  ///
  /// ## Default implementations
  ///
  /// [CollapseToNewestPolicy] and [RetainAllVersionsPolicy] both return
  /// [entries] unchanged — all versions are retained. This is
  /// backward-compatible.
  ///
  /// ## Override
  ///
  /// [VersionRetentionPolicy] overrides this to apply the keep-N /
  /// retentionDays trim rules for `$ver:` namespaces.
  List<MergeEntry> filterGroup(List<MergeEntry> entries, {required int nowMs});
}

/// Default policy: collapse every `(namespace, userKey)` group to the
/// highest-HLC entry, and drop a surviving delete tombstone iff the
/// compaction covers all levels and the tombstone's HLC is below the sync
/// horizon. Applied to all user namespaces and to KMDB system namespaces
/// that hold current-state only (`$meta`, `$cache`, `$$index:`, `$$fts:`,
/// `$$vec:`, `$sync`, …).
final class CollapseToNewestPolicy implements ReclamationPolicy {
  /// Creates the default collapse-to-newest policy.
  const CollapseToNewestPolicy();

  @override
  bool get collapseVersions => true;

  @override
  bool dropTombstone({
    required bool allLevels,
    required Hlc tombstoneHlc,
    required Hlc horizon,
  }) {
    if (!allLevels) return false;
    return tombstoneHlc.compareTo(horizon) < 0;
  }

  /// Not called for `collapseVersions=true` namespaces — returns entries
  /// unchanged for completeness.
  @override
  List<MergeEntry> filterGroup(
    List<MergeEntry> entries, {
    required int nowMs,
  }) => entries;
}

/// Collapse policy for local-only (`$$`-prefixed) namespaces.
///
/// Like [CollapseToNewestPolicy] in all respects except [dropTombstone]:
/// because local-only namespaces contain device-local derived data (FTS
/// indexes, vector indexes, secondary indexes) that is never synced, the
/// *sync horizon* check is meaningless. A `$$`-namespace tombstone may be
/// dropped in a full all-levels compaction without waiting for any peer
/// to acknowledge the delete.
///
/// The `allLevels` safety gate is **not** relaxed — dropping a local-only
/// tombstone in a partial compaction would resurrect a deleted key from an
/// un-compacted lower level, which is a correctness violation. Only full
/// all-levels compactions (`_compactAll`) may drop these tombstones.
///
/// Tombstones dropped under this policy are elided from the output SSTable
/// but are **not** counted in `CompactionJob.tombstonesDropped` — that
/// counter drives the GC-floor advance in `$meta`, which is relevant only
/// for syncable namespaces. Local-only drops do not advance the floor.
final class LocalOnlyCollapsePolicy implements ReclamationPolicy {
  /// Creates the local-only collapse policy.
  const LocalOnlyCollapsePolicy();

  @override
  bool get collapseVersions => true;

  @override
  bool dropTombstone({
    required bool allLevels,
    required Hlc tombstoneHlc,
    required Hlc horizon,
  }) {
    // For local-only namespaces the horizon check is irrelevant — no peer
    // device will ever see these entries. The only safety gate is allLevels:
    // partial compactions must never drop tombstones regardless of namespace.
    return allLevels;
  }

  /// Not called for `collapseVersions=true` namespaces — returns entries
  /// unchanged for completeness.
  @override
  List<MergeEntry> filterGroup(
    List<MergeEntry> entries, {
    required int nowMs,
  }) => entries;
}

/// Retain every version of every key. Used for history-bearing namespace
/// classes — notably the future `$ver:` document-versioning namespaces,
/// which supply their own keep-N / retention rules at compaction time once
/// that plan lands and replaces this placeholder. Tombstones are never
/// dropped under this policy.
final class RetainAllVersionsPolicy implements ReclamationPolicy {
  /// Creates the retain-all-versions policy.
  const RetainAllVersionsPolicy();

  @override
  bool get collapseVersions => false;

  @override
  bool dropTombstone({
    required bool allLevels,
    required Hlc tombstoneHlc,
    required Hlc horizon,
  }) => false;

  /// Returns all entries unchanged — [RetainAllVersionsPolicy] does not trim
  /// any versions. This is the backward-compatible default for `$ver:`
  /// namespaces that do not have an explicit [VersionRetentionPolicy].
  @override
  List<MergeEntry> filterGroup(
    List<MergeEntry> entries, {
    required int nowMs,
  }) => entries;
}

/// Resolves a [ReclamationPolicy] for a namespace by longest-prefix match.
///
/// The default registry collapses every namespace except those whose names
/// start with a [retainAllPrefixes] entry. Out of the box the `$ver:`
/// prefix is registered so the policy hook is exercised end-to-end before
/// the document-versioning feature lands; that feature can supply its own
/// registry (with a richer keep-N policy) when it does.
///
/// When versioning is configured, the registry maps each `$ver:{collection}`
/// namespace to a [VersionRetentionPolicy] via [_versionPolicies]. Other
/// `$ver:` prefixes fall through to [RetainAllVersionsPolicy].
///
/// ## Usage
///
/// ```dart
/// final registry = ReclamationPolicyRegistry();
/// registry.resolve('users').collapseVersions; // true (default)
/// registry.resolve('\$ver:users').collapseVersions; // false (retain)
/// ```
final class ReclamationPolicyRegistry {
  /// Creates a registry. [retainAllPrefixes] overrides the built-in
  /// `\$ver:` default — pass an empty iterable for "collapse everything",
  /// or extend the defaults to retain additional history-bearing classes.
  ReclamationPolicyRegistry({Iterable<String>? retainAllPrefixes})
    : _retainAllPrefixes = List<String>.unmodifiable(
        retainAllPrefixes ?? defaultRetainAllPrefixes,
      ),
      _versionPolicies = const {};

  /// Creates a registry with per-namespace version policies.
  ///
  /// [versionPolicies] maps exact `$ver:{collection}` namespace names to
  /// their [ReclamationPolicy] (typically a `VersionRetentionPolicy`). Other
  /// `$ver:` prefixes fall through to [RetainAllVersionsPolicy].
  ///
  /// This constructor is called by [KmdbDatabase] at open time after reading
  /// per-collection [VersionConfig] entries from `$meta`.
  ReclamationPolicyRegistry.withVersionPolicies(
    Map<String, ReclamationPolicy> versionPolicies,
  ) : _retainAllPrefixes = List<String>.unmodifiable(defaultRetainAllPrefixes),
      _versionPolicies = Map<String, ReclamationPolicy>.unmodifiable(
        versionPolicies,
      );

  /// Namespace prefixes that retain all versions by default. Currently
  /// `\$ver:` (document-versioning history).
  static const List<String> defaultRetainAllPrefixes = <String>[r'$ver:'];

  final List<String> _retainAllPrefixes;

  /// Per-namespace version retention policies, keyed by exact namespace name.
  /// Set via [ReclamationPolicyRegistry.withVersionPolicies].
  final Map<String, ReclamationPolicy> _versionPolicies;

  /// Returns the policy that applies to writes in [namespace].
  ///
  /// Resolution order:
  /// 1. Exact match in [_versionPolicies] (per-namespace version policies,
  ///    set when versioning is configured).
  /// 2. Local-only namespaces (`$$`-prefix) → [LocalOnlyCollapsePolicy].
  ///    Horizon check is skipped; allLevels gate is retained.
  /// 3. Prefix match in [_retainAllPrefixes] → [RetainAllVersionsPolicy].
  /// 4. Default → [CollapseToNewestPolicy].
  ReclamationPolicy resolve(String namespace) {
    // 1. Exact match for versioned namespaces.
    final exact = _versionPolicies[namespace];
    if (exact != null) return exact;
    // 2. Local-only namespaces skip the sync-horizon tombstone check because
    //    their data never reaches other devices.
    if (namespace.startsWith(r'$$')) return const LocalOnlyCollapsePolicy();
    // 3. Prefix match.
    for (final prefix in _retainAllPrefixes) {
      if (namespace.startsWith(prefix)) return const RetainAllVersionsPolicy();
    }
    // 4. Default.
    return const CollapseToNewestPolicy();
  }
}
