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

import '../../commands/command.dart';
import '../dot_command.dart';
import '../session_state.dart';

/// `.commands [name]` — lists REPL-available database commands or shows full
/// syntax for one.
///
/// With no argument, prints a two-column table of command names and their
/// one-line descriptions, sorted alphabetically.
///
/// With a command name, prints the full usage synopsis (which may span
/// multiple lines for commands with sub-forms), the description, and — when
/// the command has registered flags — an options table built from the live
/// [ArgParser] configuration.
final class CommandsCommand extends DotCommand {
  const CommandsCommand(this._commands);

  /// REPL-visible commands, keyed by name.
  final Map<String, CliCommand> _commands;

  @override
  String get name => 'commands';

  @override
  String get description =>
      'List available database commands, or show syntax for one.';

  @override
  String get argSynopsis => '[command]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isNotEmpty) {
      return _showDetail(ctx, args[0]);
    }
    return _listAll(ctx);
  }

  bool _listAll(CommandContext ctx) {
    final sorted = _commands.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    const nameWidth = 20;
    ctx.out.writeln('Commands:');
    for (final cmd in sorted) {
      ctx.out.writeln('  ${cmd.name.padRight(nameWidth)} ${cmd.description}');
    }
    ctx.out.writeln(
      '\nType .commands <name> for full syntax and options.',
    );
    return true;
  }

  bool _showDetail(CommandContext ctx, String cmdName) {
    final cmd = _commands[cmdName];
    if (cmd == null) {
      ctx.err.writeln("Error: unknown command '$cmdName'.");
      ctx.err.writeln(
        'Type .commands to see available commands.',
      );
      return false;
    }

    ctx.out.writeln(cmd.usage);
    ctx.out.writeln('  ${cmd.description}');

    final parser = ArgParser(usageLineLength: 80);
    cmd.configureArgParser(parser);
    final optionsText = parser.usage;
    if (optionsText.isNotEmpty) {
      ctx.out.writeln('\nOptions:');
      ctx.out.writeln(optionsText);
    }

    return true;
  }
}
