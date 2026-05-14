// Copyright 2026 The Authors
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

import 'package:glob/glob.dart' as glob_pattern;

/// Represents a glob pattern match rule for file names.
class Glob {
  final String pattern;
  final int weight;
  final bool caseSensitive;

  const Glob({
    required this.pattern,
    this.weight = 50,
    required this.caseSensitive,
  });

  @override
  int get hashCode => Object.hash(pattern, weight, caseSensitive);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Glob &&
          runtimeType == other.runtimeType &&
          pattern == other.pattern &&
          weight == other.weight &&
          caseSensitive == other.caseSensitive;

  static final Map<Glob, glob_pattern.Glob> _cacheIgnoreCase = {};
  static final Map<Glob, glob_pattern.Glob> _cacheCaseSensitive = {};

  /// Check if the given file name matches the glob pattern.
  ///
  /// Note that caches are used to store the glob patterns. The caching is basic and
  /// can grow to a maximum of [Registry._globIndex.length] * 2 entries (one each for case sensitive and insensitive).
  ///
  /// TODO: Consider LRU caching here
  bool matches(String fileName, {bool caseSensitive = false}) {
    final effectiveCaseSensitive = caseSensitive || this.caseSensitive;

    if (effectiveCaseSensitive) {
      final glob = _cacheCaseSensitive.putIfAbsent(
        this,
        () => glob_pattern.Glob(pattern, caseSensitive: true),
      );
      return glob.matches(fileName);
    } else {
      final glob = _cacheIgnoreCase.putIfAbsent(
        this,
        () => glob_pattern.Glob(pattern, caseSensitive: false),
      );
      return glob.matches(fileName);
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'pattern': pattern,
      'weight': weight,
      'caseSensitive': caseSensitive,
    };
  }

  @override
  String toString() => jsonEncode(toMap());
}
