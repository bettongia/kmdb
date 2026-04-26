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

/// `.nullvalue <str>` — sets the string shown for null/missing values in
/// table, csv, and line modes.
final class NullValueCommand extends DotCommand {
  const NullValueCommand();

  @override
  String get name => 'nullvalue';

  @override
  String get description =>
      'String shown for null/missing values in table/csv/line modes.';

  @override
  String get argSynopsis => '<str>';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.out.writeln('nullvalue: "${state.nullValue}"');
      return true;
    }
    state.nullValue = args[0];
    ctx.out.writeln('nullvalue: "${state.nullValue}"');
    return true;
  }
}
