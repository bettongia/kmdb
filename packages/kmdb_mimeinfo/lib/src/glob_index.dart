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

import 'entry.dart';
import 'glob.dart';

/// A pre-computed index of glob patterns for fast filename matching.
class GlobIndex {
  /// Simple `*.ext` patterns mapped by their lowercase extension.
  final Map<String, List<IndexedGlob>> byExtension = {};

  /// Complex patterns (e.g. `README*`, `*.tar.gz`) that require a linear scan.
  final List<IndexedGlob> complexPatterns = [];

  GlobIndex(Map<String, RegistryEntry> entries) {
    for (final entry in entries.values) {
      for (final glob in entry.globs) {
        final indexed = IndexedGlob(entry, glob);
        if (_isSimpleExtension(glob.pattern)) {
          // Extract the extension without the leading '*.'
          final ext = glob.pattern.substring(2).toLowerCase();
          byExtension.putIfAbsent(ext, () => []).add(indexed);
        } else {
          complexPatterns.add(indexed);
        }
      }
    }
  }

  /// Re-implements `Glob._isSimpleExtension` as we cannot access it if it's private
  /// without changing its signature, but we need it here.
  static bool _isSimpleExtension(String pattern) {
    if (!pattern.startsWith('*.')) return false;
    final extension = pattern.substring(2);
    if (extension.isEmpty) return false;
    // Check for glob special characters
    return !extension.contains('*') &&
        !extension.contains('?') &&
        !extension.contains('[') &&
        !extension.contains('\\');
  }
}

/// A tuple linking a glob pattern back to its parent registry entry.
class IndexedGlob {
  final RegistryEntry registryEntry;
  final Glob glob;

  IndexedGlob(this.registryEntry, this.glob);
}
