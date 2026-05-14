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

import '../commands/command.dart';
import 'session_state.dart';

/// Base interface for all REPL dot-commands (`.mode`, `.collection`, etc.).
///
/// Dot-commands are processed by [ReplRunner] before batch-command dispatch.
/// They never reach [KmdbCli] and have access to [SessionState] as well as
/// [CommandContext].
abstract class DotCommand {
  const DotCommand();

  /// The primary name of this dot-command, *without* the leading dot.
  ///
  /// For example, `'mode'` for the `.mode` command.
  String get name;

  /// Short one-line description shown by `.help`.
  String get description;

  /// Argument synopsis shown by `.help <name>`.
  ///
  /// Include only arguments, not the leading dot or command name.
  String get argSynopsis => '';

  /// Executes this dot-command.
  ///
  /// [args] are the whitespace-split tokens after the dot-command name.
  /// Returns `true` on success, `false` on a handled error.
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  );
}

// ── DotCommandRegistry ────────────────────────────────────────────────────────

/// Holds all registered [DotCommand] instances, keyed by name.
final class DotCommandRegistry {
  DotCommandRegistry(Iterable<DotCommand> commands)
    : _map = {for (final c in commands) c.name: c};

  final Map<String, DotCommand> _map;

  /// All registered dot-command names (without the leading dot).
  List<String> get names => _map.keys.map((n) => '.$n').toList()..sort();

  /// Looks up a dot-command by [name] (without the leading dot).
  ///
  /// Returns `null` when no command with that name is registered.
  DotCommand? lookup(String name) => _map[name];

  /// All registered commands in alphabetical order.
  List<DotCommand> get all =>
      _map.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}
