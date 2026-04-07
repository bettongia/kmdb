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

import 'commands/collections_command.dart';
import 'commands/command.dart';
import 'commands/compact_command.dart';
import 'commands/count_command.dart';
import 'commands/delete_command.dart';
import 'commands/dump_command.dart';
import 'commands/export_command.dart';
import 'commands/flush_command.dart';
import 'commands/get_command.dart';
import 'commands/import_command.dart';
import 'commands/insert_command.dart';
import 'commands/put_command.dart';
import 'commands/update_command.dart';
import 'commands/info_command.dart';
import 'commands/init_command.dart';
import 'commands/new_device_id_command.dart';
import 'commands/restore_command.dart';
import 'commands/scan_command.dart';
import 'commands/stats_command.dart';
import 'commands/pull_command.dart';
import 'commands/push_command.dart';
import 'commands/remote_command.dart';
import 'commands/sync_command.dart';
import 'commands/util_command.dart';
import 'commands/verify_command.dart';
import 'database_opener.dart';
import 'output/output_mode.dart';

/// @docImport 'commands/command.dart';

/// Version string shown by `--version`.
const _kVersion = '0.1.0';

/// All registered CLI commands, keyed by their primary name.
final _commands = <String, CliCommand>{
  for (final cmd in <CliCommand>[
    const InitCommand(),
    const GetCommand(),
    const InsertCommand(),
    const PutCommand(),
    const UpdateCommand(),
    const DeleteCommand(),
    const ScanCommand(),
    const CountCommand(),
    const CollectionsCommand(),
    const StatsCommand(),
    const InfoCommand(),
    const ExportCommand(),
    const ImportCommand(),
    const DumpCommand(),
    const RestoreCommand(),
    const FlushCommand(),
    const CompactCommand(),
    const VerifyCommand(),
    const NewDeviceIdCommand(),
    const UtilCommand(),
    const RemoteCommand(),
    const PushCommand(),
    const PullCommand(),
    const SyncCommand(),
  ])
    cmd.name: cmd,
};

/// Entry point for the KMDB CLI.
///
/// [KmdbCli.run] is called from [bin/kmdb.dart]. It parses global flags,
/// opens the database, and dispatches to the appropriate [CliCommand].
///
/// ## Invocation forms
///
/// ```bash
/// # Inline command
/// kmdb mydb get notes <key>
///
/// # Multiple inline commands (processed in order)
/// kmdb mydb ".mode table" "scan notes"
///
/// # Read commands from a file
/// kmdb mydb --read script.kmdb
///
/// # Pipe commands from stdin
/// echo "scan notes --limit 5" | kmdb mydb
/// ```
abstract final class KmdbCli {
  KmdbCli._();

  /// Runs the CLI with the given command-line [args].
  ///
  /// Returns an exit code: 0 for success, 1 for error.
  static Future<int> run(List<String> args) async {
    if (args.isEmpty) {
      _printUsage();
      return 1;
    }

    // ── Global flag scan ────────────────────────────────────────────────────
    // We do a lightweight manual scan rather than using package:args so we can
    // handle the unusual positional structure:
    //   kmdb [global-flags] <db-path> [command-tokens...]

    var modeStr = 'json';
    String? outputPath;
    String? readPath;
    var continueOnError = false;
    var showVersion = false;
    var showHelp = false;
    var flushOnExit = true;

    final remaining = <String>[];
    var i = 0;
    while (i < args.length) {
      final a = args[i];
      switch (a) {
        case '--version':
          showVersion = true;
        case '--help' || '-h':
          showHelp = true;
        case '--continue-on-error':
          continueOnError = true;
        case '--flush':
          flushOnExit = true;
        case '--no-flush':
          flushOnExit = false;
        case '--mode' || '-m':
          i++;
          if (i >= args.length) {
            io.stderr.writeln('Error: --mode requires a value.');
            return 1;
          }
          modeStr = args[i];
        case '--output' || '-o':
          i++;
          if (i >= args.length) {
            io.stderr.writeln('Error: --output requires a value.');
            return 1;
          }
          outputPath = args[i];
        case '--read' || '-r':
          i++;
          if (i >= args.length) {
            io.stderr.writeln('Error: --read requires a file path.');
            return 1;
          }
          readPath = args[i];
        default:
          remaining.add(a);
      }
      i++;
    }

    if (showVersion) {
      io.stdout.writeln('kmdb $_kVersion');
      return 0;
    }

    if (showHelp) {
      _printUsage();
      return 0;
    }

    if (remaining.isEmpty) {
      io.stderr.writeln('Error: database path required.');
      _printUsage();
      return 1;
    }

    // ── Parse output mode ───────────────────────────────────────────────────
    final OutputMode mode;
    try {
      mode = OutputMode.fromString(modeStr);
    } on ArgumentError catch (e) {
      io.stderr.writeln('Error: ${e.message}');
      return 1;
    }

    // ── Optional output file sink ────────────────────────────────────────────
    io.IOSink? fileSink;
    StringSink outSink;
    if (outputPath != null) {
      fileSink = io.File(outputPath).openWrite();
      outSink = fileSink;
    } else {
      outSink = io.stdout;
    }

    // ── Open database ────────────────────────────────────────────────────────
    final dbPath = remaining[0];

    // Guard: when the inline command is 'init', refuse to proceed if the
    // target directory already contains files that are not part of a KMDB
    // database.  This prevents accidental pollution of foreign directories
    // (e.g. home dirs, source trees) with KMDB files.  The check runs before
    // DatabaseOpener.open so we never write any files to the directory.
    if (remaining.length > 1 && remaining[1] == 'init') {
      final initError = _checkInitDirectory(dbPath);
      if (initError != null) {
        io.stderr.writeln('Error: $initError');
        return 1;
      }
    }

    final KvStoreImpl store;
    final bool dbCreated;
    try {
      (store, dbCreated) = await DatabaseOpener.open(dbPath);
    } on LockException catch (e) {
      io.stderr.writeln('Error: $e');
      return 1;
    } catch (e) {
      io.stderr.writeln('Error opening database: $e');
      return 1;
    }

    final ctx = CommandContext(
      store: store,
      mode: mode,
      out: outSink,
      dbCreated: dbCreated,
    );

    // ── Collect command source ───────────────────────────────────────────────
    // Sources (in priority order):
    //  1. Inline tokens (remaining[1..]) — already tokenised by the shell
    //  2. --read <file>
    //  3. stdin (when no inline commands and stdin is not a tty)
    List<String>? inlineTokens;
    List<String>? commandLines;

    if (remaining.length > 1) {
      // The shell already split the command into tokens; use them directly so
      // values containing spaces (e.g. JSON) are not re-split.
      inlineTokens = remaining.sublist(1);
    } else if (readPath != null) {
      commandLines = await _readLines(readPath, io.stderr);
      if (commandLines.isEmpty && !io.File(readPath).existsSync()) {
        io.stderr.writeln('Error: file not found: $readPath');
        await store.close();
        return 1;
      }
    } else if (!io.stdin.hasTerminal) {
      // Pipe: read all lines from stdin.
      commandLines = await io.stdin
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();
    } else {
      io.stderr.writeln('Error: no command provided.');
      _printUsage();
      await store.close();
      return 1;
    }

    // ── Execute commands ─────────────────────────────────────────────────────
    var exitCode = 0;
    try {
      if (inlineTokens != null) {
        // Inline args are already tokenised by the shell; dispatch directly.
        final success = await _dispatchTokens(inlineTokens, ctx, io.stderr);
        if (!success) exitCode = 1;
      } else {
        for (final raw in commandLines!) {
          final trimmed = raw.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

          final success = await _executeCommandLine(trimmed, ctx, io.stderr);
          if (!success) {
            exitCode = 1;
            if (!continueOnError) break;
          }
        }
      }
    } finally {
      await store.close(flush: flushOnExit && !ctx.suppressFlush);
      if (fileSink != null) {
        await fileSink.flush();
        await fileSink.close();
      }
    }

    return exitCode;
  }

  // ── Command line parsing & dispatch ───────────────────────────────────────

  /// Parses [line] into tokens, then dispatches.
  ///
  /// Returns `true` on success, `false` on error.
  static Future<bool> _executeCommandLine(
    String line,
    CommandContext ctx,
    StringSink errSink,
  ) async {
    // A line may start with a dot-command prefix (reserved for Phase 2 REPL).
    if (line.startsWith('.')) {
      errSink.writeln(
        'Error: dot-commands are only supported in REPL mode (Phase 2).',
      );
      return false;
    }

    return _dispatchTokens(_tokenize(line), ctx, errSink);
  }

  /// Dispatches a pre-tokenized command to the appropriate [CliCommand].
  ///
  /// Used both by [_executeCommandLine] (after tokenizing a string) and
  /// directly for inline CLI args that the shell has already split.
  ///
  /// Returns `true` on success, `false` on error.
  static Future<bool> _dispatchTokens(
    List<String> tokens,
    CommandContext ctx,
    StringSink errSink,
  ) async {
    if (tokens.isEmpty) return true;

    final commandName = tokens[0];
    final command = _commands[commandName];
    if (command == null) {
      errSink.writeln(
        "Error: unknown command '$commandName'. "
        "Run 'kmdb --help' for a list of commands.",
      );
      return false;
    }

    // Separate positional args from --flag value pairs.
    final posArgs = <String>[];
    final flags = <String, dynamic>{};
    var j = 1;
    while (j < tokens.length) {
      final t = tokens[j];
      if (t.startsWith('--')) {
        final flagName = t.substring(2);
        // Boolean flags have no value; value flags consume the next token.
        if (j + 1 < tokens.length && !tokens[j + 1].startsWith('--')) {
          flags[flagName] = tokens[j + 1];
          j += 2;
        } else {
          flags[flagName] = true;
          j++;
        }
      } else {
        posArgs.add(t);
        j++;
      }
    }

    try {
      return await command.execute(ctx, posArgs, flags);
    } catch (e, st) {
      errSink.writeln('Error executing "$commandName": $e\n$st');
      return false;
    }
  }

  // ── Init directory guard ──────────────────────────────────────────────────

  /// Returns an error message if [dbPath] is unsafe for `init`, or `null` if
  /// it is safe to proceed.
  ///
  /// A path is considered safe when:
  /// - the directory does not yet exist (will be created fresh), or
  /// - the directory already contains a `CURRENT` file (existing KMDB
  ///   database), or
  /// - the directory exists but is completely empty.
  ///
  /// Any other non-empty directory is rejected to prevent accidentally
  /// writing KMDB files into a foreign location such as a home directory or
  /// a source-code tree.
  static String? _checkInitDirectory(String dbPath) {
    final dir = io.Directory(dbPath);
    if (!dir.existsSync()) return null; // will be created fresh — safe
    if (io.File('$dbPath/CURRENT').existsSync())
      return null; // existing KMDB db — safe
    final entries = dir.listSync();
    if (entries.isEmpty) return null; // empty directory — safe
    return '"$dbPath" is not empty and does not contain an existing KMDB '
        'database. Provide an empty or non-existent directory to create a '
        'new database, or point init at an existing KMDB database path.';
  }

  // ── Tokeniser ─────────────────────────────────────────────────────────────

  /// Splits [line] into tokens, respecting single and double quoted strings.
  ///
  /// Quoted strings may contain spaces. Quotes are stripped from the result.
  static List<String> _tokenize(String line) {
    final tokens = <String>[];
    final buf = StringBuffer();
    String? quote;

    for (var ci = 0; ci < line.length; ci++) {
      final ch = line[ci];
      if (quote != null) {
        if (ch == '\\' && ci + 1 < line.length) {
          final next = line[ci + 1];
          if (next == quote || next == '\\') {
            buf.write(next);
            ci++;
            continue;
          }
        }
        if (ch == quote) {
          quote = null;
        } else {
          buf.write(ch);
        }
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == ' ' || ch == '\t') {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(ch);
      }
    }
    if (buf.isNotEmpty) tokens.add(buf.toString());
    return tokens;
  }

  // ── File reader ───────────────────────────────────────────────────────────

  static Future<List<String>> _readLines(
    String path,
    StringSink errSink,
  ) async {
    try {
      final content = await io.File(path).readAsString();
      return const LineSplitter().convert(content);
    } on io.FileSystemException catch (e) {
      errSink.writeln('Error reading file "$path": ${e.message}');
      return [];
    }
  }

  // ── Help ──────────────────────────────────────────────────────────────────

  static void _printUsage() {
    io.stdout.writeln('''
Usage: kmdb [options] <database-path> <command> [args...]
       kmdb [options] <database-path> --read <script>

Options:
  --mode, -m <mode>    Output format: json (default), compact, ndjson, table, csv, line
  --output, -o <file>  Write output to file instead of stdout
  --read, -r <file>    Read commands from a script file
  --continue-on-error  Keep running after a command error
  --flush              Flush memtable to SSTable on exit (default)
  --no-flush           Skip flush on exit (data remains in WAL)
  --version            Print version and exit
  --help, -h           Print this help and exit

Commands:
  Database:
    init

  Data:
    get <coll> <key> [--select <fields>]
    insert <coll> [--value <json>] [--file <path>]
    update <coll> [<id> | --id <id1,id2,...> | --filter <json> | --all] --set <json>
    delete <coll> <key>
    scan <coll> [--filter <json>] [--order-by <field>] [--desc]
              [--limit <n>] [--offset <n>] [--key-prefix <str>]
              [--select <field1,field2,...>]
    count <coll> [--filter <json>]
    put <coll> [--value <json>] [--file <path>]   (deprecated — use insert)

  Introspection:
    collections
    stats
    info

  Import / Export:
    export <coll>                        (use --output <file> to write to a file)
    import <coll> [--input <file>] [--on-conflict ignore|replace|error]
    dump                                 (use --output <file> to write to a file)
    restore [--input <file>]

  Maintenance:
    flush
    compact
    verify
    new-device-id

  Sync:
    remote add <name> --path <path>  Add a named sync remote
    remote remove <name>             Remove a named sync remote
    remote list                      List all sync remotes
    push [<remote>] [--collection <coll>]...   Push local SSTables to sync folder
    pull [<remote>] [--sync-dir <path>] [--collection <coll>]...   Pull peer SSTables from sync folder
    sync [<remote>] [--sync-dir <path>] [--collection <coll>]...   Push then pull

  Diagnostics:
    util sstable <filename>          Inspect SSTable file
    util wal <filename>              Inspect WAL file
    util manifest                    Inspect active Manifest

Examples:
  kmdb mydb get notes 019abc...
  kmdb mydb scan notes --filter '{"field":"status","op":"eq","value":"active"}' --limit 10
  kmdb mydb dump --output backup.ndjson
  kmdb mydb --read migrations/001.kmdb
  echo "collections" | kmdb mydb
''');
  }
}
