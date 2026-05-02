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

import 'package:args/args.dart';
export 'package:args/args.dart' show ArgParser;
import 'package:kmdb/kmdb.dart';

import 'package:kmdb/kmdb_config.dart';
import '../output/document_formatter.dart';
import '../output/output_mode.dart';

/// Execution context passed to every CLI command.
///
/// Carries the open [KmdbDatabase], the CLI config, the chosen output mode,
/// and output sinks so commands can be tested without real disk I/O or stdout.
///
/// ## Query Layer access
///
/// Commands that read or write documents should use [rawCollection] to obtain
/// an untyped [KmdbCollection] for the target collection. Writes through
/// [rawCollection] pass through the full write pipeline (schema validation,
/// secondary index maintenance, FTS updates, vault ref counts).
///
/// ## Engine-level access
///
/// Commands that operate on engine internals (dump, restore, sync, compact,
/// flush, vault, etc.) may use [store] directly. Writes at the store level
/// bypass the write pipeline — this is intentional for such commands (the same
/// reason database restores bypass constraints in any database system).
final class CommandContext {
  /// Creates a [CommandContext] backed by [db].
  ///
  /// [config] defaults to [KmdbConfig.empty] when omitted. [mode] defaults to
  /// [OutputMode.json]. [out] and [err] default to stdout and stderr.
  CommandContext({
    required this.db,
    KmdbConfig? config,
    this.mode = OutputMode.json,
    this.dbCreated = false,
    StringSink? out,
    StringSink? err,
  }) : config = config ?? KmdbConfig.empty(),
       out = out ?? _StdoutSink(), // coverage:ignore-line
       err = err ?? _StderrSink(); // coverage:ignore-line

  /// The open database.
  ///
  /// The primary field. Commands that read or write documents should use
  /// [rawCollection] rather than accessing [db] directly. Commands that need
  /// engine-level access use [store].
  final KmdbDatabase db;

  /// The per-database CLI configuration loaded from `local/config.json`.
  ///
  /// Holds named sync remotes and secondary index definitions that persist
  /// across CLI sessions. Commands that mutate this config must call
  /// [KmdbConfig.save] to persist the changes.
  final KmdbConfig config;

  /// The active output format.
  final OutputMode mode;

  /// Whether the database was freshly created during this session open.
  ///
  /// `true` when no `CURRENT` file existed before [DatabaseOpener.open] was
  /// called (i.e. this is the first ever open of the database at this path).
  /// `false` when an existing database was reopened.
  final bool dbCreated;

  /// Sink for normal output (stdout in production).
  final StringSink out;

  /// Sink for error messages (stderr in production).
  final StringSink err;

  /// When `true`, the CLI runner must not flush the memtable on exit.
  ///
  /// Set by read-only diagnostic commands (e.g. [UtilCommand]) that must never
  /// cause side-effects on the database they are inspecting.
  bool suppressFlush = false;

  // ── Convenience accessors ──────────────────────────────────────────────────

  /// The underlying key-value store.
  ///
  /// Use this only for engine-level operations (dump, restore, sync, compact,
  /// flush, vault, etc.) that legitimately bypass the write pipeline.
  /// For document reads and writes, prefer [rawCollection].
  KvStoreImpl get store => db.store;

  /// The index manager for write interception and lazy build.
  ///
  /// Use this for commands that inspect or manage index state (e.g. the
  /// `index` command and `scan --explain`).
  IndexManager get indexManager => db.indexManager;

  /// The vault store, or `null` when vault is not configured.
  ///
  /// Vault commands that require this field should check for `null` and report
  /// an error rather than crashing.
  VaultStore? get vaultStore => db.vaultStore;

  /// Returns an untyped [KmdbCollection] for [collectionName].
  ///
  /// The returned collection routes writes through the full write pipeline:
  /// schema validation, secondary index maintenance, FTS updates, and vault
  /// ref-count adjustments all run automatically. This is the recommended way
  /// for CLI commands to read and write documents.
  KmdbCollection<Map<String, dynamic>> rawCollection(String collectionName) =>
      db.rawCollection(collectionName);

  // ── Output helpers ─────────────────────────────────────────────────────────

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
abstract class CliCommand {
  const CliCommand();

  /// The primary name of this command (e.g. `'get'`).
  String get name;

  /// Short description shown in `--help` listings.
  String get description;

  /// Positional-argument synopsis shown as the command invocation in help.
  ///
  /// Include only the positional arguments (e.g. `'scan <collection>'`).
  /// Option flags are registered via [configureArgParser] and appear in the
  /// generated options table below the invocation line.
  String get usage;

  /// Whether this command is meaningful inside an interactive REPL session.
  ///
  /// Commands that operate at database-open time (e.g. `init`) or are
  /// one-time setup operations (e.g. `new-device-id`) return `false` so they
  /// are excluded from the `.commands` dot-command listing. All other commands
  /// default to `true`.
  bool get replVisible => true;

  /// Registers this command's flags and options on [parser].
  ///
  /// Called by the help-text builder so that `kmdb help <command>` shows a
  /// structured options table rather than a hand-written synopsis string.
  /// The default implementation is a no-op for commands with no flags.
  void configureArgParser(ArgParser parser) {} // coverage:ignore-line

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

// coverage:ignore-start
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

// coverage:ignore-end
