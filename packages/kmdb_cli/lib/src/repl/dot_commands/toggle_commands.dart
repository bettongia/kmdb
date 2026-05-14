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

// Shared helper for on/off toggles.
bool? _parseOnOff(String value) => switch (value.toLowerCase()) {
  'on' => true,
  'off' => false,
  _ => null,
};

/// `.compact on|off` — toggles compact (single-line) JSON output.
final class CompactCommand extends DotCommand {
  const CompactCommand();
  @override
  String get name => 'compact';
  @override
  String get description => 'Toggle compact JSON output (on/off).';
  @override
  String get argSynopsis => 'on|off';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.out.writeln('compact: ${state.compact ? "on" : "off"}');
      return true;
    }
    final v = _parseOnOff(args[0]);
    if (v == null) {
      ctx.err.writeln('Error: .compact requires on or off.');
      return false;
    }
    state.compact = v;
    ctx.out.writeln('compact: ${v ? "on" : "off"}');
    return true;
  }
}

/// `.headers on|off` — toggles column headers in table/csv modes.
final class HeadersCommand extends DotCommand {
  const HeadersCommand();
  @override
  String get name => 'headers';
  @override
  String get description =>
      'Toggle column headers in table/csv modes (on/off).';
  @override
  String get argSynopsis => 'on|off';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.out.writeln('headers: ${state.headers ? "on" : "off"}');
      return true;
    }
    final v = _parseOnOff(args[0]);
    if (v == null) {
      ctx.err.writeln('Error: .headers requires on or off.');
      return false;
    }
    state.headers = v;
    ctx.out.writeln('headers: ${v ? "on" : "off"}');
    return true;
  }
}

/// `.echo on|off` — echoes each command before executing it.
final class EchoCommand extends DotCommand {
  const EchoCommand();
  @override
  String get name => 'echo';
  @override
  String get description => 'Echo each command before executing (on/off).';
  @override
  String get argSynopsis => 'on|off';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.out.writeln('echo: ${state.echo ? "on" : "off"}');
      return true;
    }
    final v = _parseOnOff(args[0]);
    if (v == null) {
      ctx.err.writeln('Error: .echo requires on or off.');
      return false;
    }
    state.echo = v;
    ctx.out.writeln('echo: ${v ? "on" : "off"}');
    return true;
  }
}

/// `.bail on|off` — exits the REPL on first error when on.
final class BailCommand extends DotCommand {
  const BailCommand();
  @override
  String get name => 'bail';
  @override
  String get description => 'Exit on first error (on) or continue (off).';
  @override
  String get argSynopsis => 'on|off';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.out.writeln('bail: ${state.bail ? "on" : "off"}');
      return true;
    }
    final v = _parseOnOff(args[0]);
    if (v == null) {
      ctx.err.writeln('Error: .bail requires on or off.');
      return false;
    }
    state.bail = v;
    ctx.out.writeln('bail: ${v ? "on" : "off"}');
    return true;
  }
}

/// `.timer on|off` — prints elapsed time after each command.
final class TimerCommand extends DotCommand {
  const TimerCommand();
  @override
  String get name => 'timer';
  @override
  String get description => 'Print execution time after each command (on/off).';
  @override
  String get argSynopsis => 'on|off';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      ctx.out.writeln('timer: ${state.timer ? "on" : "off"}');
      return true;
    }
    final v = _parseOnOff(args[0]);
    if (v == null) {
      ctx.err.writeln('Error: .timer requires on or off.');
      return false;
    }
    state.timer = v;
    ctx.out.writeln('timer: ${v ? "on" : "off"}');
    return true;
  }
}
