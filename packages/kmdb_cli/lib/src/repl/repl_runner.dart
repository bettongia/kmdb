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

import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';

import '../cli_runner.dart';
import '../commands/command.dart';
import 'colorizer.dart';
import 'completer.dart';
import 'dot_command.dart';
import 'dot_commands/collection_command.dart';
import 'dot_commands/color_command.dart';
import 'dot_commands/database_commands.dart';
import 'dot_commands/commands_command.dart';
import 'dot_commands/help_command.dart';
import 'dot_commands/history_command.dart';
import 'dot_commands/introspection_commands.dart';
import 'dot_commands/io_commands.dart';
import 'dot_commands/limit_command.dart';
import 'dot_commands/mode_command.dart';
import 'dot_commands/nullvalue_command.dart';
import 'dot_commands/output_command.dart';
import 'dot_commands/quit_command.dart';
import 'dot_commands/show_command.dart';
import 'dot_commands/toggle_commands.dart';
import 'history.dart';
import 'input_reader.dart';
import 'prompt.dart';
import 'repl_config.dart';
import 'session_state.dart';
import 'spinner.dart';

/// CLI version string, kept in sync with [KmdbCli].
const _kVersion = '0.1.0';

/// Interactive REPL for exploring and editing KMDB databases.
///
/// [ReplRunner.run] is called by [KmdbCli.run] when stdin is a terminal and no
/// inline commands are provided. It owns the event loop: read → dispatch →
/// print, until `.quit`, `.exit`, or Ctrl+D.
///
/// Any unhandled exception that escapes the loop (including [io.StdinException]
/// from [InputReader.readLine] when the terminal cannot be put into raw mode)
/// is caught, a human-readable message is written to stderr, and [run] returns
/// exit code 1 rather than propagating a raw stack trace to `main`.
///
/// ## Architecture
///
/// - [InputReader] abstracts raw-mode terminal I/O; [FakeInputReader] is used
///   in tests.
/// - [SessionState] holds all mutable session settings changed by dot-commands.
/// - [DotCommandRegistry] maps `.name` to [DotCommand] implementations.
/// - [History] persists command history to `~/.kmdb_history`.
/// - [LiveCompletionProvider] provides context-aware tab completions.
/// - [Spinner] displays progress during long-running sync operations.
final class ReplRunner {
  ReplRunner({
    required CommandContext ctx,
    required String dbPath,
    Map<String, CliCommand>? commands,
    InputReader? reader,
    History? history,
    ReplConfig? config,
    SessionState? state,
  }) : _dbPath = dbPath,
       _commands = commands ?? const {},
       _state = state ?? SessionState(),
       _history = history ?? History(),
       _config = config ?? ReplConfig(),
       _reader = reader ?? TtyInputReader() {
    _ctx = ctx;
    _registry = _buildRegistry();
    _completer = LiveCompletionProvider(_ctx, _registry);
  }

  final String _dbPath;
  final Map<String, CliCommand> _commands;
  final SessionState _state;
  final History _history;
  final ReplConfig _config;
  final InputReader _reader;

  late CommandContext _ctx;
  late DotCommandRegistry _registry;
  late CompletionProvider _completer;

  // ── Public entry point ────────────────────────────────────────────────────

  /// Runs the REPL loop until exit.
  ///
  /// Returns the exit code: 0 for normal exit, non-zero from `.exit <code>`.
  Future<int> run() async {
    await _config.load(_state);
    await _history.load();
    _reader.setHistory(_history.entries);

    final dbName = Prompt.dbNameFrom(_dbPath);
    _ctx.out.writeln('kmdb $_kVersion  •  $_dbPath');
    _ctx.out.writeln('Type .help for dot-commands or .quit to exit.');

    var exitCode = 0;

    try {
      while (true) {
        final promptStr = Prompt.build(
          dbName: dbName,
          collection: _state.activeCollection,
        );

        // Accumulate continuation lines.
        final line = await _readMultiLine(promptStr);
        if (line == null) break; // EOF

        if (line.trim().isEmpty) continue;

        _history.add(line);
        _reader.setHistory(_history.entries);

        if (_state.echo) {
          _effectiveSink().writeln(line);
        }

        final before = _state.timer ? DateTime.now() : null;

        final success = await _dispatchLine(line);

        if (before != null) {
          final elapsed = DateTime.now().difference(before);
          final c = Colorizer(enabled: _state.colorEnabled);
          _effectiveSink().writeln(c.muted('(${elapsed.inMilliseconds} ms)'));
        }

        // Consume the one-shot sink regardless of success.
        if (_state.onceSink is io.IOSink) {
          await (_state.onceSink as io.IOSink).flush();
          await (_state.onceSink as io.IOSink).close();
        }
        _state.onceSink = null;

        if (!success && _state.bail) break;
      }
    } on QuitException catch (e) {
      exitCode = e.code;
    } catch (e) {
      _errSink().writeln(
        'Error: unexpected REPL failure ($e). The session has ended.',
      );
      exitCode = 1;
    } finally {
      await _history.save();
      await _ctx.db.close(flush: true);
      await _reader.dispose();
    }

    return exitCode;
  }

  // ── Multi-line accumulation ───────────────────────────────────────────────

  /// Reads one logical command, which may span multiple physical lines.
  ///
  /// A line ending with `\` or containing unbalanced JSON braces/brackets
  /// triggers the continuation prompt until the input is complete.
  ///
  /// Returns the accumulated text (without continuation `\`), or `null` on EOF.
  Future<String?> _readMultiLine(String primaryPrompt) async {
    final parts = <String>[];
    var currentPrompt = primaryPrompt;

    while (true) {
      final outcome = await _reader.readLine(
        currentPrompt,
        completer: (text, pos) => _completer.complete(text, pos),
      );

      switch (outcome.result) {
        case ReadLineResult.eof:
          if (parts.isEmpty) return null;
          // EOF mid-continuation: submit what we have.
          return parts.join(' ');
        case ReadLineResult.interrupt:
          // Ctrl+C cancels the current line; print newline and return empty.
          _ctx.out.writeln('');
          return '';
        case ReadLineResult.line:
          final raw = outcome.value!;
          // Line continuation with trailing `\`.
          if (raw.endsWith(r'\')) {
            parts.add(raw.substring(0, raw.length - 1).trimRight());
            currentPrompt = Prompt.continuation;
            continue;
          }
          parts.add(raw);
          final full = parts.join(' ');
          // Continue if JSON braces/brackets are unbalanced.
          if (_hasUnbalancedJson(full)) {
            currentPrompt = Prompt.continuation;
            continue;
          }
          return full;
      }
    }
  }

  /// Returns `true` when [text] contains an unbalanced `{`, `[`, or `'`
  /// that indicates the user is mid-way through a JSON argument.
  bool _hasUnbalancedJson(String text) {
    var braces = 0;
    var brackets = 0;
    String? inQuote;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inQuote != null) {
        if (ch == '\\' && i + 1 < text.length) {
          i++; // skip escaped char
          continue;
        }
        if (ch == inQuote) inQuote = null;
        continue;
      }
      if (ch == '"' || ch == "'") {
        inQuote = ch;
      } else if (ch == '{') {
        braces++;
      } else if (ch == '}') {
        braces--;
      } else if (ch == '[') {
        brackets++;
      } else if (ch == ']') {
        brackets--;
      }
    }
    return braces > 0 || brackets > 0 || inQuote != null;
  }

  // ── Dispatch ──────────────────────────────────────────────────────────────

  /// Dispatches a complete command line.
  ///
  /// Returns `true` on success, `false` on error.
  Future<bool> _dispatchLine(String line) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return true;

    // Handle `!n` history recall.
    if (trimmed.startsWith('!')) {
      final n = int.tryParse(trimmed.substring(1));
      if (n == null) {
        _errSink().writeln('Error: expected a number after !');
        return false;
      }
      final recalled = _history.getByIndex(n);
      if (recalled == null) {
        _errSink().writeln('Error: no history entry $n.');
        return false;
      }
      _effectiveSink().writeln(recalled);
      return _dispatchLine(recalled);
    }

    // Dot-command.
    if (trimmed.startsWith('.')) {
      return _handleDotCommand(trimmed);
    }

    // Sync commands get a spinner.
    final firstToken = trimmed.split(' ').first;
    final isSync =
        firstToken == 'push' || firstToken == 'pull' || firstToken == 'sync';

    Spinner? spinner;
    if (isSync) {
      spinner = Spinner();
      spinner.start(
        firstToken == 'push'
            ? 'Pushing…'
            : firstToken == 'pull'
            ? 'Pulling…'
            : 'Syncing…',
      );
    }

    final outSink = _effectiveSink();
    final dispatchCtx = CommandContext(
      db: _ctx.db,
      config: _ctx.config,
      mode: _state.outputMode,
      out: outSink,
      err: _errSink(),
    );

    bool success;
    try {
      success = await KmdbCli.dispatchLine(trimmed, dispatchCtx);
    } on SchemaValidationException catch (e) {
      spinner?.stop();
      _formatSchemaError(e, dispatchCtx);
      return false;
    } finally {
      spinner?.stop();
    }

    return success;
  }

  // ── Dot-command handler ───────────────────────────────────────────────────

  Future<bool> _handleDotCommand(String line) async {
    // Strip the leading dot and tokenise.
    final tokens = _tokenize(line.substring(1));
    if (tokens.isEmpty) return true;

    final cmdName = tokens[0];
    final cmd = _registry.lookup(cmdName);
    if (cmd == null) {
      _errSink().writeln(
        "Error: unknown dot-command '.$cmdName'. Type .help for a list.",
      );
      return false;
    }

    final dispatchCtx = CommandContext(
      db: _ctx.db,
      config: _ctx.config,
      mode: _state.outputMode,
      out: _effectiveSink(),
      err: _errSink(),
    );

    return cmd.execute(_state, dispatchCtx, tokens.sublist(1));
  }

  // ── Sink accessors ─────────────────────────────────────────────────────────

  /// Returns the output sink for the current command:
  /// `.once` sink → `.output` sink → ctx.out (stdout in production, buffer in tests).
  StringSink _effectiveSink() =>
      _state.onceSink ?? _state.outputSink ?? _ctx.out;

  StringSink _errSink() => _ctx.err;

  // ── Schema error formatting ───────────────────────────────────────────────

  void _formatSchemaError(SchemaValidationException e, CommandContext ctx) {
    final c = Colorizer(enabled: _state.colorEnabled);
    _errSink().writeln(c.error('Schema validation failed:'));
    for (final v in e.violations) {
      if (v.path.isEmpty) {
        _errSink().writeln('  ${c.error(v.message)}');
      } else {
        _errSink().writeln('  ${c.field(v.path)}: ${c.error(v.message)}');
      }
    }
  }

  // ── Registry factory ──────────────────────────────────────────────────────

  DotCommandRegistry _buildRegistry() {
    Future<CommandContext?> onOpen(String path, SessionState state) async {
      final newCtx = await openDatabase(path, io.stderr);
      if (newCtx == null) return null;
      _ctx = newCtx;
      _completer = LiveCompletionProvider(_ctx, _registry);
      return newCtx;
    }

    Future<void> onClose() async {
      await _ctx.db.close(flush: true);
    }

    Future<bool> dispatcher(String line, CommandContext ctx) =>
        _dispatchLine(line);

    // Build the command list without HelpCommand first so we can obtain a
    // fully-populated registry to pass into HelpCommand.
    final commands = <DotCommand>[
      // Session state
      const ModeCommand(),
      const OutputCommand(),
      const OnceCommand(),
      const CompactCommand(),
      const ColorCommand(),
      const HeadersCommand(),
      const NullValueCommand(),
      const LimitCommand(),
      const CollectionCommand(),
      const EchoCommand(),
      const BailCommand(),
      const TimerCommand(),
      // Introspection
      const CollectionsAliasCommand(),
      const IndexesAliasCommand(),
      const SchemaAliasCommand(),
      const ShowCommand(),
      HistoryCommand(_history),
      // I/O & scripting
      ReadCommand(dispatcher),
      const ExportAliasCommand(),
      const ImportAliasCommand(),
      const DumpAliasCommand(),
      const RestoreAliasCommand(),
      // Database
      OpenCommand(onOpen),
      CloseCommand(onClose),
      // Exit (no help yet)
      const QuitCommand(),
      const ExitCommand(),
    ];

    // CommandsCommand is added before building tempReg so that HelpCommand
    // sees it in its listing.
    final allButHelp = [...commands, CommandsCommand(_commands)];
    final tempReg = DotCommandRegistry(allButHelp);

    return DotCommandRegistry([...allButHelp, HelpCommand(tempReg)]);
  }

  // ── Tokenizer ─────────────────────────────────────────────────────────────

  static List<String> _tokenize(String line) {
    final tokens = <String>[];
    final buf = StringBuffer();
    String? quote;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (quote != null) {
        if (ch == '\\' && i + 1 < line.length) {
          final next = line[i + 1];
          if (next == quote || next == '\\') {
            buf.write(next);
            i++;
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
}
