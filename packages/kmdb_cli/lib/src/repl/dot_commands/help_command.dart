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
import '../dot_command.dart';
import '../session_state.dart';

/// `.help [command]` — lists all dot-commands or shows help for one.
final class HelpCommand extends DotCommand {
  const HelpCommand(this._registry);

  final DotCommandRegistry _registry;

  @override
  String get name => 'help';

  @override
  String get description =>
      'Show help for all dot-commands, or for a specific one.';

  @override
  String get argSynopsis => '[command]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isNotEmpty) {
      final cmdName = args[0].startsWith('.') ? args[0].substring(1) : args[0];
      final cmd = _registry.lookup(cmdName);
      if (cmd == null) {
        ctx.err.writeln("Error: unknown dot-command '.$cmdName'.");
        return false;
      }
      final synopsis = cmd.argSynopsis.isNotEmpty
          ? '.${cmd.name} ${cmd.argSynopsis}'
          : '.${cmd.name}';
      ctx.out.writeln('$synopsis\n  ${cmd.description}');
      return true;
    }

    // List all commands sorted alphabetically.
    ctx.out.writeln('Dot-commands:');
    for (final cmd in _registry.all) {
      final synopsis = cmd.argSynopsis.isNotEmpty
          ? '.${cmd.name} ${cmd.argSynopsis}'
          : '.${cmd.name}';
      ctx.out.writeln('  ${synopsis.padRight(30)} ${cmd.description}');
    }
    return true;
  }
}
