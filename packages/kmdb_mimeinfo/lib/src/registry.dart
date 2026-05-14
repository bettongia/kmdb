/*
 Copyright 2026 The Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'entry.dart' show RegistryEntry;
import 'glob_index.dart';
import 'match.dart' show MatchResult, MatchList;
import 'xml.dart';

/// A registry of MIME types and their associated file extensions and magic numbers.
class Registry {
  final Map<String, RegistryEntry> _entries;

  /// Lazily-built index for fast glob lookups by file extension.
  final GlobIndex _globIndex;

  /// Creates a new instance of the [Registry].
  ///
  /// Since the underlying database is generated and global, instances of
  /// [Registry] share the same underlying immutable map of entries.
  Registry(Map<String, RegistryEntry> entries)
    : _entries = UnmodifiableMapView(entries),
      _globIndex = GlobIndex(entries);

  /// The number of media type entries in the registry.
  int get length => _entries.length;

  /// All registry entries as an unmodifiable iterable.
  // Iterable<RegistryEntry> get entries => UnmodifiableListView(_entries.values);

  /// Whether the registry contains an entry for the given [mediaType] string.
  bool contains(String mediaType) => _entries.containsKey(mediaType);

  /// Determine the possible media types for the file
  ///
  /// Providing [bytes] allows for checking magic numbers in the file
  /// [fileName] is used to check the file extension against known globs
  ///
  /// If [bytes] is empty, only a file extension check is used.
  ///
  /// This method expects a [fileName] (e.g., `document.pdf`) rather than a full
  /// file path containing directory separators. Providing a path with
  /// directory components will likely result in no matches being found. For
  /// full file paths, consider using [identify] or extracting the filename
  /// first using `path.basename`.
  ///
  /// Per the FreeDesktop shared-mime-info specification:
  /// - If magic matches are found, they take precedence over glob matches.
  /// - If a magic match confirms a glob match (i.e. the same type appears in
  ///   both), that result is promoted to the top.
  /// - Root XML matches refine XML-based types further.
  ///
  /// A list of [MatchResult]s is returned, ordered by priority descending
  MatchList detect({
    Uint8List? bytes,
    String? fileName,
    bool caseSensitive = false,
  }) {
    List<MatchResult>? globMatches;
    List<MatchResult>? magicMatches;
    List<MatchResult>? rootXmlMatches;

    // Step 1: Glob match on the file name.
    globMatches = (fileName != null)
        ? matchGlob(fileName, caseSensitive: caseSensitive)
        : null;

    // Step 2: Magic matching.
    magicMatches = (bytes != null) ? matchMagic(bytes) : null;

    // Step 3: Root XML matching (only if magic or glob suggest XML).
    if (isLikelyXml(globMatches, magicMatches)) {
      rootXmlMatches = (bytes != null) ? matchRootXML(bytes) : [];
    } else {
      rootXmlMatches = null;
    }

    return MatchList(
      rootXmlMatches: rootXmlMatches,
      magicMatches: magicMatches,
      globMatches: globMatches,
    );
  }

  bool isLikelyXml(
    List<MatchResult>? globMatches,
    List<MatchResult>? magicMatches,
  ) {
    /// Whether this media type is effectively an XML-based format.
    bool isXml(String mediaType) {
      final tokens = mediaType.split('/');
      return (tokens[0] == 'xml' || tokens[1].endsWith('+xml'));
    }

    return ((globMatches?.any(
              (m) => m.subclassOf.contains('application/xml'),
            ) ??
            false) ||
        (magicMatches?.any((m) => m.subclassOf.contains('application/xml')) ??
            false) ||
        (globMatches?.any((m) => isXml(m.mediaType)) ?? false) ||
        (magicMatches?.any((m) => isXml(m.mediaType)) ?? false));
  }

  Map<String, Map<String, dynamic>> toMap() {
    return _entries.map((key, value) => MapEntry(key, value.toMap()));
  }

  /// Search through the database to find a match for the given file name.
  ///
  /// This method expects a file name (e.g., `document.pdf`) rather than a full
  /// file path containing directory separators. Providing a path with
  /// directory components will likely result in no matches being found. For
  /// full file paths, consider using [identify] or extracting the filename
  /// first using `path.basename`.
  ///
  /// Simple `*.ext` patterns are looked up via a pre-built extension index in
  /// O(1). Complex patterns (e.g. `README*`, `*.tar.gz`) are checked via a
  /// linear scan of only the entries that have such patterns.
  ///
  /// Returns a list of media types that match the given file name, ordered by descending weight.
  /// Duplicate matches are removed.
  List<MatchResult> matchGlob(String fileName, {bool caseSensitive = false}) {
    final matches = <MatchResult>[];

    // Fast path: look up by file extension(s).
    // We check progressively shorter extensions (e.g. "tar.gz" then "gz")
    // to catch compound extensions like *.tar.gz.
    final lowerName = fileName.toLowerCase();
    final dotIndex = lowerName.indexOf('.');
    if (dotIndex != -1 && dotIndex < lowerName.length - 1) {
      var remaining = lowerName.substring(dotIndex + 1);
      while (remaining.isNotEmpty) {
        final indexed = _globIndex.byExtension[remaining];
        if (indexed != null) {
          for (final entry in indexed) {
            if (entry.glob.matches(fileName, caseSensitive: caseSensitive)) {
              matches.add(
                MatchResult(
                  priority: entry.glob.weight,
                  entry: entry.registryEntry,
                ),
              );
            }
          }
        }
        //if (matches.isNotEmpty) {
        //  break;
        //}
        final nextDot = remaining.indexOf('.');
        if (nextDot == -1) break;
        remaining = remaining.substring(nextDot + 1);
      }
    }

    // Slow path: check complex patterns that can't be indexed by extension.
    for (final pattern in _globIndex.complexPatterns) {
      if (pattern.glob.matches(fileName, caseSensitive: caseSensitive)) {
        matches.add(
          MatchResult(
            priority: pattern.glob.weight,
            entry: pattern.registryEntry,
          ),
        );
      }
    }

    matches.sort((a, b) => b.priority.compareTo(a.priority));
    return matches.toSet().toList();
  }

  /// Search through the database to find a match for the given byte stream.
  ///
  /// Returns a list of media types that match the given byte stream, ordered by descending priority.
  /// Duplicate matches are removed.
  List<MatchResult> matchMagic(List<int> bytes) {
    final matches = <MatchResult>[];
    for (final entry in _entries.values) {
      matches.addAll(entry.matchesMagic(bytes));
    }
    matches.sort((a, b) => b.priority.compareTo(a.priority));
    return matches.toSet().toList();
  }

  /// Search through the database to find a match for the given XML file by examining its root element.
  ///
  /// The file is read and parsed once. The parsed root element is then checked
  /// against all registered [RootXML] rules.
  ///
  /// Returns a list of media types that match the given file's root XML element, ordered by descending priority.
  /// Duplicate matches are removed.
  List<MatchResult> matchRootXML(Uint8List bytes) {
    // Parse the XML file once at this level.
    final XmlName rootName;
    try {
      final document = XmlDocument.parse(utf8.decode(bytes));
      rootName = document.rootElement.name;
    } catch (_) {
      return [];
    }

    final matches = <MatchResult>[];
    for (final entry in _entries.values) {
      if (entry.rootXML.isNotEmpty) {
        for (final rule in entry.rootXML) {
          if (rule.matchesElement(rootName)) {
            matches.add(MatchResult(priority: rule.weight, entry: entry));
          }
        }
      }
    }
    matches.sort((a, b) => b.priority.compareTo(a.priority));
    return matches.toSet().toList();
  }

  @override
  String toString() => jsonEncode(toMap());
}
