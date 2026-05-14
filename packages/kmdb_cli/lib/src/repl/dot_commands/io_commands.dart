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

import '../../commands/command.dart';
import '../../commands/dump_command.dart';
import '../../commands/export_command.dart';
import '../../commands/import_command.dart';
import '../../commands/restore_command.dart';
import '../dot_command.dart';
import '../session_state.dart';

/// `.read <file>` — executes a Phase-1 script file from inside the REPL.
///
/// Lines in the file are executed sequentially. Blank lines and `#` comment
/// lines are ignored. The execution uses the current [SessionState] output
/// mode and active collection.
final class ReadCommand extends DotCommand {
  const ReadCommand(this._dispatcher);

  /// Callback that dispatches a single command line, returning `true` on
  /// success. Provided by [ReplRunner] at construction time.
  final Future<bool> Function(String line, CommandContext ctx) _dispatcher;

  @override
  String get name => 'read';

  @override
  String get description => 'Execute commands from a script file.';

  @override
  String get argSynopsis => '<file>';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.err.writeln('Error: .read requires a file path.');
      return false;
    }
    final path = args[0];
    final file = io.File(path);
    if (!file.existsSync()) {
      ctx.err.writeln('Error: file not found: $path');
      return false;
    }

    List<String> lines;
    try {
      final content = await file.readAsString(encoding: utf8);
      lines = const LineSplitter().convert(content);
    } on io.IOException catch (e) {
      ctx.err.writeln('Error: cannot read "$path": $e');
      return false;
    }

    var ok = true;
    for (final raw in lines) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final success = await _dispatcher(trimmed, ctx);
      if (!success) {
        ok = false;
        if (state.bail) break;
      }
    }
    return ok;
  }
}

/// `.export <collection> [file]` — alias for `export <collection> [--output file]`.
final class ExportAliasCommand extends DotCommand {
  const ExportAliasCommand();

  @override
  String get name => 'export';

  @override
  String get description => 'Export a collection to NDJSON.';

  @override
  String get argSynopsis => '<collection> [file]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.err.writeln('Error: .export requires a collection name.');
      return false;
    }
    final posArgs = [args[0]];
    final flags = <String, dynamic>{};
    if (args.length >= 2) flags['output'] = args[1];
    return const ExportCommand().execute(ctx, posArgs, flags);
  }
}

/// `.import <collection> <file>` — alias for `import <collection> --input <file>`.
final class ImportAliasCommand extends DotCommand {
  const ImportAliasCommand();

  @override
  String get name => 'import';

  @override
  String get description => 'Import NDJSON into a collection.';

  @override
  String get argSynopsis => '<collection> <file>';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.length < 2) {
      ctx.err.writeln('Error: .import requires a collection and a file path.');
      return false;
    }
    return const ImportCommand().execute(ctx, [args[0]], {'input': args[1]});
  }
}

/// `.dump [file]` — alias for `dump [--output file]`.
final class DumpAliasCommand extends DotCommand {
  const DumpAliasCommand();

  @override
  String get name => 'dump';

  @override
  String get description => 'Dump entire database as NDJSON.';

  @override
  String get argSynopsis => '[file]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    final flags = <String, dynamic>{};
    if (args.isNotEmpty) flags['output'] = args[0];
    return const DumpCommand().execute(ctx, [], flags);
  }
}

/// `.restore <file>` — alias for `restore --input <file>`.
final class RestoreAliasCommand extends DotCommand {
  const RestoreAliasCommand();

  @override
  String get name => 'restore';

  @override
  String get description => 'Restore database from an NDJSON dump.';

  @override
  String get argSynopsis => '<file>';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.err.writeln('Error: .restore requires a file path.');
      return false;
    }
    return const RestoreCommand().execute(ctx, [], {'input': args[0]});
  }
}
