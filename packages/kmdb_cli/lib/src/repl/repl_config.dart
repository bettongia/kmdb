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

import 'dart:convert';
import 'dart:io' as io;

import '../output/output_mode.dart';
import 'session_state.dart';

/// Persists REPL user preferences to `~/.kmdbrc` (JSON).
///
/// [load] is called once at REPL start. If the file does not yet exist the
/// defaults are written out so the user has a documented starting point.
/// Corrupt or unreadable files are silently ignored and the session proceeds
/// with [SessionState] defaults.
///
/// ## Configurable fields
///
/// | JSON key    | [SessionState] field  | Type              |
/// |-------------|----------------------|-------------------|
/// | `bail`      | [SessionState.bail]         | bool              |
/// | `color`     | [SessionState.colorMode]    | `on`/`off`/`auto` |
/// | `compact`   | [SessionState.compact]      | bool              |
/// | `echo`      | [SessionState.echo]         | bool              |
/// | `headers`   | [SessionState.headers]      | bool              |
/// | `limit`     | [SessionState.defaultLimit] | int (0 = none)    |
/// | `mode`      | [SessionState.outputMode]   | `json`/`table`/…  |
/// | `nullvalue` | [SessionState.nullValue]    | string            |
/// | `timer`     | [SessionState.timer]        | bool              |
/// | `cacheDir`  | — (returned by [cacheDir])  | string path       |
///
/// Unknown keys and invalid values are silently ignored so that forward- and
/// backward-compatible config files can coexist with any KMDB version.
final class ReplConfig {
  /// Creates a [ReplConfig] backed by [filePath].
  ///
  /// [filePath] defaults to `~/.kmdbrc`. Pass a custom path in tests.
  ReplConfig({String? filePath}) : _path = filePath ?? _defaultPath();

  final String _path;

  /// The resolved model cache directory.
  ///
  /// Populated after [load] from the `cacheDir` key in `~/.kmdbrc`, or
  /// defaults to `~/.kmdb_cache`. The directory is created lazily on first
  /// download — it does not need to exist before [load] is called.
  String? _cacheDir;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Returns the resolved cache directory for downloaded model files.
  ///
  /// Value is available after [load] has been called. Defaults to
  /// `~/.kmdb_cache` if not overridden in `~/.kmdbrc`. The directory is
  /// created lazily by [ModelDownloader] on first download.
  String get cacheDir => _cacheDir ?? _defaultCacheDir();

  /// Loads config from [_path] and applies it to [state].
  ///
  /// If the file does not exist, writes a defaults file and returns without
  /// mutating [state] (it is already at defaults). Read/parse errors are
  /// silently ignored.
  Future<void> load(SessionState state) async {
    final file = io.File(_path);
    if (!file.existsSync()) {
      await _writeDefaults();
      return;
    }
    try {
      final text = await file.readAsString(encoding: utf8);
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        _apply(decoded, state);
      }
    } catch (_) {
      // Corrupt or unreadable config — leave state at defaults.
    }
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  Future<void> _writeDefaults() async {
    try {
      await io.File(_path).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(_defaults())}\n',
        encoding: utf8,
      );
    } catch (_) {
      // Silently ignore write failures (e.g. read-only home directory).
    }
  }

  void _apply(Map<String, dynamic> json, SessionState state) {
    if (json['bail'] is bool) state.bail = json['bail'] as bool;
    if (json['compact'] is bool) state.compact = json['compact'] as bool;
    if (json['echo'] is bool) state.echo = json['echo'] as bool;
    if (json['headers'] is bool) state.headers = json['headers'] as bool;
    if (json['timer'] is bool) state.timer = json['timer'] as bool;
    if (json['limit'] is int) {
      final v = json['limit'] as int;
      if (v >= 0) state.defaultLimit = v;
    }
    if (json['nullvalue'] is String) {
      state.nullValue = json['nullvalue'] as String;
    }
    if (json['color'] is String) {
      state.colorMode = switch (json['color'] as String) {
        'on' => ColorMode.on,
        'off' => ColorMode.off,
        _ => ColorMode.auto,
      };
    }
    if (json['mode'] is String) {
      try {
        state.outputMode = OutputMode.fromString(json['mode'] as String);
      } catch (_) {
        // Unknown mode string — keep default.
      }
    }
    // Resolve cache dir — must be non-empty to override the default.
    if (json['cacheDir'] is String) {
      final dir = (json['cacheDir'] as String).trim();
      if (dir.isNotEmpty) _cacheDir = dir;
    }
  }

  static Map<String, dynamic> _defaults() => {
    'bail': false,
    'color': 'auto',
    'compact': false,
    'echo': false,
    'headers': true,
    'limit': 0,
    'mode': 'json',
    'nullvalue': '',
    'timer': false,
    // cacheDir is commented out in the defaults file to show the user the
    // option exists without overriding the system default.
    // 'cacheDir': '~/.kmdb_cache',
  };

  static String _defaultPath() {
    final home =
        io.Platform.environment['HOME'] ??
        io.Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/.kmdbrc';
  }

  static String _defaultCacheDir() {
    final home =
        io.Platform.environment['HOME'] ??
        io.Platform.environment['USERPROFILE'] ??
        '.';
    return '$home/.kmdb_cache';
  }
}
