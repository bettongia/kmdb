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

import 'dart:convert';
import 'dart:io' as io;

/// Manages the REPL command history file (`~/.kmdb_history`).
///
/// History is stored as a plain UTF-8 newline-delimited text file — one entry
/// per line — compatible with readline-style history files. The file is loaded
/// on REPL start and written on clean exit (`.quit`, `.exit`, Ctrl+D) as well
/// as on SIGINT.
///
/// Up to [maxEntries] entries are retained; the oldest entries are dropped when
/// the cap is exceeded.
///
/// ## History recall
///
/// The [entries] list is handed to [InputReader.setHistory] before each prompt
/// so that up/down arrow navigation is always up-to-date with recent commands.
///
/// The `.history [n]` dot-command calls [recent] to display the last n entries.
/// `!n` recall calls [getByIndex] to retrieve a specific 1-based entry.
final class History {
  /// Creates a [History] backed by [filePath].
  ///
  /// [filePath] defaults to `~/.kmdb_history`. Pass a custom path in tests.
  History({String? filePath}) : _path = filePath ?? _defaultPath();

  static const maxEntries = 1000;

  final String _path;
  final List<String> _entries = [];

  // ── Public API ───────────────────────────────────────────────────────────────

  /// All loaded history entries in chronological order (oldest first).
  List<String> get entries => List.unmodifiable(_entries);

  /// Loads history from [_path].
  ///
  /// Non-fatal: if the file does not exist or cannot be read, history starts
  /// empty. Invalid (non-UTF-8) lines are silently skipped.
  Future<void> load() async {
    final file = io.File(_path);
    if (!file.existsSync()) return;
    try {
      final content = await file.readAsString(encoding: utf8);
      final lines = const LineSplitter()
          .convert(content)
          .where((l) => l.isNotEmpty)
          .toList();
      _entries
        ..clear()
        ..addAll(lines);
      _trim();
    } catch (_) {
      // Silently ignore unreadable history files.
    }
  }

  /// Persists history to [_path].
  ///
  /// Non-fatal: write errors are silently ignored so a history save failure
  /// never crashes the REPL.
  Future<void> save() async {
    try {
      final file = io.File(_path);
      await file.parent.create(recursive: true);
      await file.writeAsString('${_entries.join('\n')}\n', encoding: utf8);
    } catch (_) {
      // Silently ignore write failures (e.g. read-only home directory).
    }
  }

  /// Adds [line] to the history.
  ///
  /// Blank lines and exact duplicates of the immediately preceding entry are
  /// not recorded.
  void add(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    if (_entries.isNotEmpty && _entries.last == trimmed) return;
    _entries.add(trimmed);
    _trim();
  }

  /// Returns the last [n] entries as `(1-based-index, line)` pairs.
  ///
  /// [n] defaults to 20. If fewer than [n] entries exist, all are returned.
  List<(int, String)> recent([int n = 20]) {
    final start = (_entries.length - n).clamp(0, _entries.length);
    return [for (var i = start; i < _entries.length; i++) (i + 1, _entries[i])];
  }

  /// Returns the entry at 1-based [index], or `null` if out of range.
  String? getByIndex(int index) {
    if (index < 1 || index > _entries.length) return null;
    return _entries[index - 1];
  }

  // ── Internal ─────────────────────────────────────────────────────────────────

  void _trim() {
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  static String _defaultPath() {
    final home =
        io.Platform.environment['HOME'] ??
        io.Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/.kmdb_history';
  }
}
