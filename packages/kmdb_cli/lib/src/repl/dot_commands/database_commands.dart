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

import '../../commands/command.dart';
import 'package:kmdb/kmdb_config.dart';
import '../../database_opener.dart';
import '../dot_command.dart';
import '../prompt.dart';
import '../session_state.dart';

// These commands need to swap out the CommandContext held by the ReplRunner.
// Rather than making CommandContext mutable, we use a callback that the
// ReplRunner installs at construction time.

/// Callback used by `.open` to replace the current [CommandContext].
///
/// Returns the new context, or `null` if opening failed.
typedef OpenCallback =
    Future<CommandContext?> Function(String dbPath, SessionState state);

/// `.open <path>` — closes the current database and opens a new one.
///
/// Session settings (output mode, color, etc.) are preserved. The history and
/// completer are not reset.
final class OpenCommand extends DotCommand {
  const OpenCommand(this._onOpen);

  final OpenCallback _onOpen;

  @override
  String get name => 'open';

  @override
  String get description => 'Close current database and open a new one.';

  @override
  String get argSynopsis => '<path>';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.err.writeln('Error: .open requires a database path.');
      return false;
    }
    final newCtx = await _onOpen(args[0], state);
    if (newCtx == null) return false;
    final dbName = Prompt.dbNameFrom(args[0]);
    newCtx.out.writeln('Opened $dbName.');
    return true;
  }
}

/// `.close` — closes the current database.
///
/// The REPL prompt remains but commands that require an open database will
/// fail until `.open` is used.
final class CloseCommand extends DotCommand {
  const CloseCommand(this._onClose);

  final Future<void> Function() _onClose;

  @override
  String get name => 'close';

  @override
  String get description => 'Close the current database (REPL remains open).';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    await _onClose();
    ctx.out.writeln('Database closed.');
    return true;
  }
}

// ── Standalone helper: opens a database and builds a CommandContext ──────────

/// Opens the database at [dbPath] and returns a fresh [CommandContext].
///
/// On failure, writes the error to [errSink] and returns `null`.
Future<CommandContext?> openDatabase(String dbPath, StringSink errSink) async {
  KmdbConfig config;
  try {
    config = await KmdbConfig.forDatabase(dbPath);
  } on FormatException catch (e) {
    errSink.writeln('Warning: could not load config: ${e.message}');
    config = KmdbConfig.empty();
  }

  try {
    final (db, created) = await DatabaseOpener.open(dbPath, config);
    return CommandContext(db: db, config: config, dbCreated: created);
  } catch (e) {
    errSink.writeln('Error opening database: $e');
    return null;
  }
}
