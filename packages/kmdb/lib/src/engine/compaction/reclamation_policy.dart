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

/// Per-namespace-class reclamation policy applied by compaction's streaming
/// transform.
///
/// PR1 of H4 (`plan_compaction_reclamation.md`) introduces **version
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
/// PR2 of H4 (`plan_tombstone_gc.md`) will extend this interface with a
/// tombstone-drop predicate gated by `allLevels` coverage and a sync
/// horizon. PR1 only collapses superseded *non-tombstone* versions; every
/// surviving tombstone is retained verbatim.
abstract interface class ReclamationPolicy {
  /// Whether compaction may collapse multiple versions of a single
  /// `(namespace, userKey)` group down to the highest-HLC entry.
  ///
  /// Returns `true` for current-state namespaces (the vast majority) and
  /// `false` for history-bearing namespaces such as `$ver:`.
  bool get collapseVersions;
}

/// Default policy: collapse every `(namespace, userKey)` group to the
/// highest-HLC entry. Applied to all user namespaces and to KMDB system
/// namespaces that hold current-state only (`$meta`, `$cache`, `$index:`,
/// `$fts:`, `$vec:`, `$sync`, …).
final class CollapseToNewestPolicy implements ReclamationPolicy {
  /// Creates the default collapse-to-newest policy.
  const CollapseToNewestPolicy();

  @override
  bool get collapseVersions => true;
}

/// Retain every version of every key. Used for history-bearing namespace
/// classes — notably the future `$ver:` document-versioning namespaces,
/// which supply their own keep-N / retention rules at compaction time once
/// that plan lands and replaces this placeholder.
final class RetainAllVersionsPolicy implements ReclamationPolicy {
  /// Creates the retain-all-versions policy.
  const RetainAllVersionsPolicy();

  @override
  bool get collapseVersions => false;
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
