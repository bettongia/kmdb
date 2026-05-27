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
}

/// Default policy: collapse every `(namespace, userKey)` group to the
/// highest-HLC entry, and drop a surviving delete tombstone iff the
/// compaction covers all levels and the tombstone's HLC is below the sync
/// horizon. Applied to all user namespaces and to KMDB system namespaces
/// that hold current-state only (`$meta`, `$cache`, `$index:`, `$fts:`,
/// `$vec:`, `$sync`, …).
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
}

/// Resolves a [ReclamationPolicy] for a namespace by longest-prefix match.
///
/// The default registry collapses every namespace except those whose names
/// start with a [retainAllPrefixes] entry. Out of the box the `$ver:`
/// prefix is registered so the policy hook is exercised end-to-end before
/// the document-versioning feature lands; that feature can supply its own
/// registry (with a richer keep-N policy) when it does.
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
      );

  /// Namespace prefixes that retain all versions by default. Currently
  /// `\$ver:` (document-versioning history).
  static const List<String> defaultRetainAllPrefixes = <String>[r'$ver:'];

  final List<String> _retainAllPrefixes;

  /// Returns the policy that applies to writes in [namespace].
  ReclamationPolicy resolve(String namespace) {
    for (final prefix in _retainAllPrefixes) {
      if (namespace.startsWith(prefix)) return const RetainAllVersionsPolicy();
    }
    return const CollapseToNewestPolicy();
  }
}
