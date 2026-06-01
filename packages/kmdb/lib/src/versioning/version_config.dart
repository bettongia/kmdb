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

/// Per-collection document versioning configuration.
///
/// Controls how many historical write entries are retained in the
/// `$ver:{namespace}` system namespace and how long they survive. Stored in
/// the collection's `$meta` entry so it propagates via normal sync and is
/// consistent across all devices.
///
/// ## Retention semantics
///
/// Both [maxVersions] and [retentionDays] are independent, optional knobs.
/// At compaction time a version entry is **retained** if *either* condition
/// is satisfied — i.e. the policy keeps whichever is more permissive.
///
/// - **Keep-N floor ([maxVersions]):** always retain the N most recent
///   versions (ranked by HLC descending). Rank 1 is always the newest entry,
///   which is never trimmed regardless of [retentionDays].
/// - **Retention window ([retentionDays]):** keep entries written within
///   this many calendar days of the compaction wall clock.
///
/// The keep-N floor only applies to **live documents**. Once a document is
/// deleted (its newest `$ver:` entry is a delete-version), the floor is
/// lifted: the whole `$ver:` chain — every put-version *and* the
/// delete-version — is purged once the delete-version ages past
/// [retentionDays]. This ensures deleted documents drain to zero residue
/// without unbounded storage growth. See §26 for the full reclamation table.
///
/// ## Disabling versioning
///
/// Setting [maxVersions] to `0` with no [retentionDays] disables versioning
/// entirely for the collection. No `$ver:` entries are written on writes.
/// Useful for high-churn collections (e.g. telemetry) where history is
/// irrelevant.
///
/// ## Defaults
///
/// The default [maxVersions] is `4` and the default [retentionDays] is `90`.
/// These are designed to be useful out of the box for a personal multi-device
/// database without causing unbounded storage growth.
///
/// ## Example
///
/// ```dart
/// // Keep the 10 most recent versions and/or versions from the last 30 days.
/// final config = VersionConfig(maxVersions: 10, retentionDays: 30);
///
/// // Disable versioning for a high-churn collection.
/// final disabled = VersionConfig.disabled;
///
/// // Unlimited versions (retention window only).
/// final windowOnly = VersionConfig(maxVersions: null, retentionDays: 180);
/// ```
final class VersionConfig {
  /// Creates a [VersionConfig].
  ///
  /// Both [maxVersions] and [retentionDays] default to `null` (no constraint).
  /// Use [VersionConfig.defaults] for the recommended production defaults
  /// (`maxVersions: 4, retentionDays: 90`).
  ///
  /// Pass [maxVersions] = `0` and omit [retentionDays] to disable versioning.
  /// Pass [maxVersions] = `null` for window-only mode (no count ceiling).
  /// Pass [retentionDays] = `null` for count-only mode (no time window).
  const VersionConfig({this.maxVersions, this.retentionDays});

  /// The default versioning configuration: keep 4 versions, 90-day window.
  ///
  /// This is the recommended production default. A version entry is retained
  /// when its rank (by HLC descending) is ≤ 4, OR it was written within the
  /// last 90 days — whichever is more permissive.
  static const VersionConfig defaults = VersionConfig(
    maxVersions: 4,
    retentionDays: 90,
  );

  /// A configuration that disables versioning entirely.
  ///
  /// No `$ver:` entries are written when this config is active. Equivalent to
  /// `VersionConfig(maxVersions: 0)`.
  static const VersionConfig disabled = VersionConfig(maxVersions: 0);

  /// Maximum number of versions to retain, counted from the newest.
  ///
  /// `null` means unlimited (retain all; retention window still applies).
  /// `0` disables versioning entirely when combined with no [retentionDays].
  ///
  /// The keep-N floor applies only to live documents. For deleted documents
  /// the floor is lifted so the chain fully purges after the post-delete grace.
  final int? maxVersions;

  /// Retain versions written within this many calendar days of the compaction
  /// wall clock. `null` means no time limit (keep-N only).
  final int? retentionDays;

  /// Whether versioning is entirely disabled for the collection.
  ///
  /// Returns `true` only when [maxVersions] is `0` and [retentionDays] is
  /// `null`. In this state no `$ver:` entries are written.
  bool get isDisabled => maxVersions == 0 && retentionDays == null;

  // ── Serialisation ───────────────────────────────────────────────────────────

  /// Encodes this config to a [Map] for storage via [ValueCodec].
  Map<String, dynamic> toMap() => {
    if (maxVersions != null) 'maxVersions': maxVersions,
    if (retentionDays != null) 'retentionDays': retentionDays,
  };

  /// Decodes a [VersionConfig] from a [Map].
  ///
  /// Fields absent from [map] are restored as `null` (no constraint). This
  /// preserves the distinction between an explicitly-set value and "not set":
  /// serialising `disabled` (which has `retentionDays: null`) and decoding it
  /// back must yield `retentionDays: null`, not the defaults value `90`.
  ///
  /// Extra keys are ignored for forward compatibility with newer KMDB builds.
  static VersionConfig fromMap(Map<String, dynamic> map) {
    // Use containsKey rather than ?? so that a deliberately-absent field
    // decodes back to null, not to a non-null default.
    return VersionConfig(
      maxVersions: map.containsKey('maxVersions')
          ? map['maxVersions'] as int?
          : null,
      retentionDays: map.containsKey('retentionDays')
          ? map['retentionDays'] as int?
          : null,
    );
  }

  @override
  String toString() =>
      'VersionConfig(maxVersions: $maxVersions, '
      'retentionDays: $retentionDays)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VersionConfig &&
          maxVersions == other.maxVersions &&
          retentionDays == other.retentionDays;

  @override
  int get hashCode => Object.hash(maxVersions, retentionDays);
}
