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

import 'dart:io' as io;

/// Applies ANSI colour and style codes to text for terminal output.
///
/// Colour codes are only emitted when [enabled] is `true`. When disabled every
/// method returns its [text] argument unchanged, which makes the output safe
/// for pipes and files.
///
/// ## Typical usage
///
/// ```dart
/// final c = Colorizer(enabled: stdout.hasTerminal);
/// print(c.error('Something went wrong'));  // red
/// print(c.field('name'));                  // yellow
/// print(c.muted('(0.3 ms)'));              // dim
/// ```
final class Colorizer {
  /// Creates a [Colorizer].
  ///
  /// [enabled] defaults to `true` when [io.stdout] is attached to a terminal,
  /// and `false` otherwise (i.e. when output is being piped or redirected).
  Colorizer({bool? enabled}) : enabled = enabled ?? io.stdout.hasTerminal;

  /// Whether ANSI codes will be emitted.
  final bool enabled;

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Red text — used for error messages.
  String error(String text) => _wrap(text, _red);

  /// Yellow text — used for field names in schema violations.
  String field(String text) => _wrap(text, _yellow);

  /// Dim/muted text — used for timing output, null values, hints.
  String muted(String text) => _wrap(text, _dim);

  /// Bold text — used for headings and collection names.
  String bold(String text) => _wrap(text, _bold);

  /// Cyan text — used for informational highlights.
  String info(String text) => _wrap(text, _cyan);

  /// Green text — used for success messages.
  String success(String text) => _wrap(text, _green);

  // ── Internal ─────────────────────────────────────────────────────────────────

  static const _reset = '\x1b[0m';
  static const _red = '\x1b[31m';
  static const _yellow = '\x1b[33m';
  static const _dim = '\x1b[2m';
  static const _bold = '\x1b[1m';
  static const _cyan = '\x1b[36m';
  static const _green = '\x1b[32m';

  String _wrap(String text, String code) =>
      enabled ? '$code$text$_reset' : text;
}
