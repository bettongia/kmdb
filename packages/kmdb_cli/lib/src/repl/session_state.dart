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

import '../output/output_mode.dart';

/// Controls whether ANSI colour codes are emitted.
enum ColorMode {
  /// Always emit colour codes.
  on,

  /// Never emit colour codes.
  off,

  /// Emit colour codes only when stdout is attached to a terminal (default).
  auto,
}

/// Mutable session settings for the REPL.
///
/// [SessionState] is the single source of truth for all user-configurable
/// options within a REPL session. Dot-commands mutate this object; [ReplRunner]
/// reads it to configure [CommandContext] before each dispatch.
final class SessionState {
  /// Active output format (mirrors `--format` in batch mode).
  OutputMode outputMode = OutputMode.json;

  /// The collection that bare commands operate on when no explicit collection
  /// is supplied. `null` means no active collection is set.
  String? activeCollection;

  /// When `true`, JSON output is compact (single-line) rather than indented.
  bool compact = false;

  /// Colour output policy.
  ColorMode colorMode = ColorMode.auto;

  /// Whether column headers are shown in `table` and `csv` modes.
  bool headers = true;

  /// String used to represent null/missing values in `table`, `csv`, and
  /// `line` modes.
  String nullValue = '';

  /// Default `--limit` applied to `scan` commands (0 = no limit).
  int defaultLimit = 0;

  /// When `true`, each command is echoed to the output sink before execution.
  bool echo = false;

  /// When `true`, the REPL exits on the first command error.
  bool bail = false;

  /// When `true`, elapsed time is printed after each command.
  bool timer = false;

  /// Persistent output redirect set by `.output <file>`.
  ///
  /// `null` means output goes to the terminal. When set, all command output is
  /// written here instead. Reset to `null` by `.output` (no args).
  StringSink? outputSink;

  /// One-shot output redirect set by `.once <file>`.
  ///
  /// Consumed (set to `null`) after the next command executes, regardless of
  /// success. Takes precedence over [outputSink] for that single command.
  StringSink? onceSink;

  // ── Derived accessors ───────────────────────────────────────────────────────

  /// Whether colour codes should be emitted given the current [colorMode].
  bool get colorEnabled => switch (colorMode) {
    ColorMode.on => true,
    ColorMode.off => false,
    ColorMode.auto => io.stdout.hasTerminal,
  };

  /// Returns a human-readable summary of all current settings.
  ///
  /// Used by the `.show` dot-command.
  String describe() {
    final lines = <String>[
      'mode         ${outputMode.displayName}',
      'collection   ${activeCollection ?? "(none)"}',
      'compact      ${compact ? "on" : "off"}',
      'color        ${colorMode.name}',
      'headers      ${headers ? "on" : "off"}',
      'nullvalue    "$nullValue"',
      'limit        ${defaultLimit == 0 ? "none" : "$defaultLimit"}',
      'echo         ${echo ? "on" : "off"}',
      'bail         ${bail ? "on" : "off"}',
      'timer        ${timer ? "on" : "off"}',
      'output       ${outputSink != null ? "(file)" : "stdout"}',
    ];
    return lines.join('\n');
  }
}
