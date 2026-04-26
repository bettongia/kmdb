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

import 'dart:io' as io;

import '../../commands/command.dart';
import '../dot_command.dart';
import '../session_state.dart';

/// `.output [file]` — redirects all subsequent output to a file.
///
/// With no arguments, resets output to stdout.
final class OutputCommand extends DotCommand {
  const OutputCommand();

  @override
  String get name => 'output';

  @override
  String get description =>
      'Redirect output to a file; no argument resets to stdout.';

  @override
  String get argSynopsis => '[file]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    // Close any previously opened file sink.
    if (state.outputSink is io.IOSink) {
      await (state.outputSink as io.IOSink).flush();
      await (state.outputSink as io.IOSink).close();
    }

    if (args.isEmpty) {
      state.outputSink = null;
      ctx.out.writeln('output: reset to stdout.');
      return true;
    }

    final path = args[0];
    try {
      state.outputSink = io.File(path).openWrite();
      ctx.out.writeln('output: writing to $path');
      return true;
    } on io.IOException catch (e) {
      ctx.err.writeln('Error: cannot open "$path": $e');
      return false;
    }
  }
}

/// `.once [file]` — redirects only the next command's output to a file.
///
/// With no arguments, redirects to stdout (a no-op in practice but resets any
/// pending `.once` sink).
final class OnceCommand extends DotCommand {
  const OnceCommand();

  @override
  String get name => 'once';

  @override
  String get description =>
      'Redirect the next command\'s output to a file; no argument resets.';

  @override
  String get argSynopsis => '[file]';

  @override
  Future<bool> execute(
    SessionState state,
    CommandContext ctx,
    List<String> args,
  ) async {
    if (args.isEmpty) {
      state.onceSink = null;
      return true;
    }

    final path = args[0];
    try {
      state.onceSink = io.File(path).openWrite();
      ctx.out.writeln('once: next command output goes to $path');
      return true;
    } on io.IOException catch (e) {
      ctx.err.writeln('Error: cannot open "$path": $e');
      return false;
    }
  }
}
