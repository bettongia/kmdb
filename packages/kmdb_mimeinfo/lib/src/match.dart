// Copyright 2026 The KMDB Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';

import 'package:collection/collection.dart';

import 'registry_base.dart' show RegistryEntry;

class MatchList {
  final List<MatchResult> _globMatches;
  final List<MatchResult> _magicMatches;
  final List<MatchResult> _rootXmlMatches;

  late final List<MatchResult> _merged;

  MatchList({
    List<MatchResult>? globMatches,
    List<MatchResult>? magicMatches,
    List<MatchResult>? rootXmlMatches,
  }) : _rootXmlMatches = List.from(rootXmlMatches ?? []),
       _magicMatches = List.from(magicMatches ?? []),
       _globMatches = List.from(globMatches ?? []) {
    _merged = _merge();
  }

  bool get isEmpty => _merged.isEmpty;

  Iterable<MatchResult> get globMatches => List.unmodifiable(_globMatches);

  Iterable<MatchResult> get magicMatches => List.unmodifiable(_magicMatches);

  Iterable<MatchResult> get rootXmlMatches =>
      List.unmodifiable(_rootXmlMatches);

  /// Candidate Media Types in descending priority order
  Iterable<String> get candidates => [
    ..._globMatches,
    ..._magicMatches,
    ..._rootXmlMatches,
  ].sortedBy((m) => m.priority).reversed.map((e) => e.mediaType).toSet();

  Iterable<MatchResult> get combined => [
    ..._globMatches,
    ..._magicMatches,
    ..._rootXmlMatches,
  ].sortedBy((m) => m.priority).reversed.toSet();

  /// Merge multiple result lists, deduplicating while preserving the priority
  /// order within each list and the precedence order of the lists themselves.
  List<MatchResult> _merge() {
    final rootResults = List<MatchResult>.from(_rootXmlMatches)..sort();
    final magicResults = List<MatchResult>.from(_magicMatches)..sort();
    var globResults = List<MatchResult>.from(_globMatches)..sort();

    // 1. Root XML matches are the most definitive — return immediately.
    if (rootResults.isNotEmpty) return rootResults;

    // 2. Glob-only mode: magic was not run, or ran but found nothing.
    //    Without content inspection we cannot confirm specific subtypes, so
    //    when a parent type and a child type both match by glob, keep the
    //    parent (the more conservative, confirmable identification).
    if (magicResults.isEmpty) {
      if (globResults.isEmpty) return const [];
      final keepSet = globResults.map((r) => r.mediaType).toSet();
      for (final result in globResults) {
        for (final other in globResults) {
          if (other.mediaType == result.mediaType) continue;
          if (other.subclassOf.contains(result.mediaType)) {
            // result is a parent of other; without magic, prefer the parent.
            keepSet.remove(other.mediaType);
          }
        }
      }
      return globResults.where((r) => keepSet.contains(r.mediaType)).toList();
    }

    // 3. Full-match mode: magic found results, filter glob to consistent matches.
    //    Keep a glob entry when:
    //      a) it has no magic of its own (extension-only type — always keep), or
    //      b) magic confirmed the same type directly, or
    //      c) magic confirmed a parent type and the glob identifies the subtype.
    final magicMediaTypes = magicResults.map((m) => m.mediaType).toSet();
    final globMediaTypes = globResults.map((m) => m.mediaType).toSet();

    globResults = globResults.where((m) {
      if (!m.hasMagic) return true;
      if (magicMediaTypes.contains(m.mediaType)) return true;
      return m.subclassOf.any((parent) => magicMediaTypes.contains(parent));
    }).toList();

    // 4. Combine: magic first (baseline), then filtered glob (refinements).
    final allResults = [...magicResults, ...globResults];

    // 5. Deduplicate by mediaType, keeping first occurrence.
    final uniqueResults = <MatchResult>[];
    final seenMediaTypes = <String>{};
    for (final result in allResults) {
      if (seenMediaTypes.add(result.mediaType)) {
        uniqueResults.add(result);
      }
    }

    // 6. Types appearing in BOTH magic and glob results have the highest
    //    confidence.  Sort them first, then by priority descending.
    final doublyConfirmed = magicMediaTypes.intersection(globMediaTypes);
    uniqueResults.sort((a, b) {
      final aTier = doublyConfirmed.contains(a.mediaType) ? 0 : 1;
      final bTier = doublyConfirmed.contains(b.mediaType) ? 0 : 1;
      if (aTier != bTier) return aTier.compareTo(bTier);
      return b.priority.compareTo(a.priority);
    });

    // 7. Parent-child filtering.
    //    Three-way decision for each (parent, child) pair:
    //      a) child is in magic results → child wins (magic explicitly identified it)
    //      b) parent is doubly-confirmed AND child is not in magic → parent wins
    //         (e.g. gzip confirmed by both glob *.gz and magic beats x-compressed-tar
    //          that only matched by glob extension, so we can't confirm it's really tar)
    //      c) otherwise → child wins (more specific identification)
    final keepSet = uniqueResults.map((r) => r.mediaType).toSet();
    for (final result in uniqueResults) {
      if (!keepSet.contains(result.mediaType)) continue;
      for (final other in uniqueResults) {
        if (other.mediaType == result.mediaType) continue;
        if (!keepSet.contains(other.mediaType)) continue;
        if (other.subclassOf.contains(result.mediaType)) {
          // result is a parent of other (child).
          if (magicMediaTypes.contains(other.mediaType)) {
            keepSet.remove(
              result.mediaType,
            ); // (a) magic confirmed child — parent out
          } else if (doublyConfirmed.contains(result.mediaType)) {
            keepSet.remove(
              other.mediaType,
            ); // (b) doubly-confirmed parent — child out
          } else {
            keepSet.remove(result.mediaType); // (c) child wins by default
          }
        }
      }
    }

    return uniqueResults.where((r) => keepSet.contains(r.mediaType)).toList();
  }

  List<MatchResult> get merged => List.unmodifiable(_merged);

  String? get bestMatch {
    return _merged.firstOrNull?.mediaType;
  }
}

/// Represents a successful match result for a file or stream.
class MatchResult implements Comparable<MatchResult> {
  /// The priority of the match rule that succeeded (e.g., from magic or rootXML).
  ///
  /// Higher values indicate stronger or more specific matches (usually up to 100).
  final int priority;

  final RegistryEntry _entry;

  /// The underlying media type that was matched.
  String get mediaType => _entry.mediaType;

  /// The parent media type.
  List<String> get subclassOf => _entry.subclassOf;

  bool get hasMagic => _entry.magic.isNotEmpty;

  /// Creates a new [MatchResult] with the given [priority] and [mediaType].
  MatchResult({required this.priority, required RegistryEntry entry})
    : _entry = entry;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MatchResult &&
        other.priority == priority &&
        other.mediaType == mediaType;
  }

  @override
  int get hashCode => Object.hash(priority, mediaType);

  @override
  int compareTo(MatchResult other) {
    // Sort descending by priority (higher priority first)
    final priorityComparison = other.priority.compareTo(priority);
    return priorityComparison != 0
        ? priorityComparison
        : mediaType.compareTo(other.mediaType);
  }

  Map<String, dynamic> toMap() {
    return {'priority': priority, 'mediaType': mediaType};
  }

  @override
  String toString() => jsonEncode(toMap());
}
