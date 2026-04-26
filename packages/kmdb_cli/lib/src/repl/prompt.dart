// Copyright 2026 The KMDB Authors.
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

/// Builds the REPL prompt strings.
///
/// The prompt reflects the current session context:
///
/// ```
/// kmdb[mydb]>            ← default (no active collection)
/// kmdb[mydb:notes]>      ← with active collection set
///    ...>                ← continuation prompt (multi-line input)
/// ```
abstract final class Prompt {
  Prompt._();

  /// Continuation prompt used when the user has typed `\` at the end of a line
  /// or when an open JSON brace/bracket is awaiting its closing pair.
  static const continuation = '   ...> ';

  /// Builds the primary prompt from [dbName] and an optional [collection].
  ///
  /// [dbName] is the last path component of the database path without its
  /// file extension (e.g. `"mydb"` for `"/data/mydb.kmdb"`).
  static String build({required String dbName, String? collection}) {
    if (collection != null && collection.isNotEmpty) {
      return 'kmdb[$dbName:$collection]> ';
    }
    return 'kmdb[$dbName]> ';
  }

  /// Extracts the display name from a full [dbPath].
  ///
  /// Returns the last path component with any `.kmdb` suffix stripped.
  /// Falls back to the full path if decomposition fails.
  static String dbNameFrom(String dbPath) {
    final lastSep = dbPath.lastIndexOf('/');
    var name = lastSep == -1 ? dbPath : dbPath.substring(lastSep + 1);
    if (name.endsWith('.kmdb')) {
      name = name.substring(0, name.length - 5);
    }
    return name.isEmpty ? dbPath : name;
  }
}
