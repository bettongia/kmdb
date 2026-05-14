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

/// `.color on|off|auto` — controls ANSI colour output.
///
/// `auto` (default) emits colour codes only when stdout is a terminal.
final class ColorCommand extends DotCommand {
  const ColorCommand();

  @override
  String get name => 'color';

  @override
  String get description => 'Control ANSI colour output (on/off/auto).';

  @override
  String get argSynopsis => 'on|off|auto';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.out.writeln('color: ${state.colorMode.name}');
      return true;
    }
    final mode = switch (args[0].toLowerCase()) {
      'on' => ColorMode.on,
      'off' => ColorMode.off,
      'auto' => ColorMode.auto,
      _ => null,
    };
    if (mode == null) {
      ctx.err.writeln('Error: .color requires on, off, or auto.');
      return false;
    }
    state.colorMode = mode;
    ctx.out.writeln('color: ${mode.name}');
    return true;
  }
}
