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

import 'package:kmdb/kmdb.dart';

import '../output/document_formatter.dart';
import '../output/output_mode.dart';

/// Execution context passed to every CLI command.
///
/// Carries the open store, the chosen output mode, and output sinks so
/// commands can be tested without real disk I/O or stdout.
final class CommandContext {
  CommandContext({
    required this.store,
    this.mode = OutputMode.json,
    StringSink? out,
    StringSink? err,
  }) : out = out ?? _StdoutSink(),
       err = err ?? _StderrSink();

  /// The open key-value store.
  final KvStoreImpl store;

  /// The active output format.
  final OutputMode mode;

  /// Sink for normal output (stdout in production).
  final StringSink out;

  /// Sink for error messages (stderr in production).
  final StringSink err;

  /// Writes [docs] to [out] using the active [mode].
  void writeDocuments(List<Map<String, dynamic>> docs) {
    DocumentFormatter.format(docs, mode, sink: out);
  }

  /// Writes a single JSON value (non-document result like a count) to [out].
  void writeValue(Object? value) {
    out.writeln(const JsonEncoder.withIndent('  ').convert(value));
  }

  /// Writes [message] to [err].
  void writeError(String message) {
    err.writeln('Error: $message');
  }
}

/// Base interface for all CLI commands.
abstract interface class CliCommand {
  /// The primary name of this command (e.g. `'get'`).
  String get name;

  /// Short description shown in `--help` listings.
  String get description;

  /// Usage string shown under the command name in help.
  String get usage;

  /// Executes the command with the given positional [args] and [flags].
  ///
  /// Returns `true` on success, `false` on handled error. Unhandled errors
  /// (unexpected exceptions) propagate to the CLI runner.
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  );
}

// ── Stdout/stderr sinks ────────────────────────────────────────────────────

class _StdoutSink implements StringSink {
  @override
  void write(Object? object) => io.stdout.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      io.stdout.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => io.stdout.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => io.stdout.writeln(object);
}

class _StderrSink implements StringSink {
  @override
  void write(Object? object) => io.stderr.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      io.stderr.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => io.stderr.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => io.stderr.writeln(object);
}
