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
import '../history.dart';
import '../session_state.dart';

/// `.history [n]` — prints the last n history entries (default 20).
///
/// Each entry is shown with its 1-based index so that `!n` can be used to
/// re-execute it.
final class HistoryCommand extends DotCommand {
  const HistoryCommand(this._history);

  final History _history;

  @override
  String get name => 'history';

  @override
  String get description => 'Print last n history entries (default 20).';

  @override
  String get argSynopsis => '[n]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    int n = 20;
    if (args.isNotEmpty) {
      final parsed = int.tryParse(args[0]);
      if (parsed == null || parsed < 1) {
        ctx.err.writeln('Error: .history requires a positive integer.');
        return false;
      }
      n = parsed;
    }

    final entries = _history.recent(n);
    if (entries.isEmpty) {
      ctx.out.writeln('(no history)');
      return true;
    }
    for (final (index, line) in entries) {
      ctx.out.writeln('$index  $line');
    }
    return true;
  }
}
