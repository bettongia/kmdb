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

/// The output format used when rendering documents to stdout.
enum OutputMode {
  /// Indented JSON array of documents (default).
  json,

  /// Compact single-line JSON array (no indentation).
  compact,

  /// Newline-delimited JSON — one object per line.
  ndjson,

  /// Column-aligned ASCII table. Keys become column headers.
  table,

  /// RFC 4180 CSV with a header row.
  csv,

  /// Each field on its own line: `fieldName = value`. Documents separated by
  /// a blank line.
  line;

  /// Parses [name] (case-insensitive) to an [OutputMode].
  ///
  /// Throws [ArgumentError] for unrecognised names.
  static OutputMode fromString(String name) {
    return switch (name.toLowerCase()) {
      'json' => json,
      'compact' => compact,
      'ndjson' => ndjson,
      'table' => table,
      'csv' => csv,
      'line' => line,
      _ => throw ArgumentError(
        'Unknown output mode "$name". '
        'Valid modes: json, compact, ndjson, table, csv, line',
      ),
    };
  }

  /// Display name of this mode.
  String get displayName => name;
}
