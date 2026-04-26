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

/// `.limit <n>` — sets the default `--limit` applied to scan commands.
///
/// `0` means no limit (the default).
final class LimitCommand extends DotCommand {
  const LimitCommand();

  @override
  String get name => 'limit';

  @override
  String get description => 'Default --limit for scan commands (0 = no limit).';

  @override
  String get argSynopsis => '<n>';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      final display = state.defaultLimit == 0
          ? 'none'
          : '${state.defaultLimit}';
      ctx.out.writeln('limit: $display');
      return true;
    }
    final n = int.tryParse(args[0]);
    if (n == null || n < 0) {
      ctx.err.writeln(
        'Error: .limit requires a non-negative integer (0 = no limit).',
      );
      return false;
    }
    state.defaultLimit = n;
    ctx.out.writeln('limit: ${n == 0 ? "none" : "$n"}');
    return true;
  }
}
