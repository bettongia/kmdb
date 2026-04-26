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

/// Sentinel exception thrown by `.quit` / `.exit` to signal clean exit.
final class QuitException implements Exception {
  const QuitException([this.code = 0]);

  /// The requested exit code.
  final int code;
}

/// `.quit` / `.exit [code]` — exits the REPL with an optional exit code.
final class QuitCommand extends DotCommand {
  const QuitCommand();

  @override
  String get name => 'quit';

  @override
  String get description => 'Exit the REPL (alias: .exit [code]).';

  @override
  String get argSynopsis => '[code]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    final code = args.isNotEmpty ? (int.tryParse(args[0]) ?? 0) : 0;
    throw QuitException(code);
  }
}

/// `.exit [code]` — alias for `.quit`.
final class ExitCommand extends DotCommand {
  const ExitCommand();

  @override
  String get name => 'exit';

  @override
  String get description => 'Exit the REPL (alias: .quit [code]).';

  @override
  String get argSynopsis => '[code]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    final code = args.isNotEmpty ? (int.tryParse(args[0]) ?? 0) : 0;
    throw QuitException(code);
  }
}
