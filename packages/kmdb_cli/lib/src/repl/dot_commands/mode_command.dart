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
import '../../output/output_mode.dart';
import '../dot_command.dart';
import '../session_state.dart';

/// `.mode <mode>` — sets the active output format.
///
/// Valid modes: `json`, `compact`, `ndjson`, `table`, `csv`, `line`.
final class ModeCommand extends DotCommand {
  const ModeCommand();

  @override
  String get name => 'mode';

  @override
  String get description =>
      'Set output format (json, compact, ndjson, table, csv, line).';

  @override
  String get argSynopsis => '<mode>';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.err.writeln(
        'Error: .mode requires a mode name.\nUsage: .mode $argSynopsis',
      );
      return false;
    }
    try {
      state.outputMode = OutputMode.fromString(args[0]);
      ctx.out.writeln('mode: ${state.outputMode.displayName}');
      return true;
    } on ArgumentError catch (e) {
      ctx.err.writeln('Error: ${e.message}');
      return false;
    }
  }
}
