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

import 'dart:async';
import 'dart:io' as io;

// coverage:ignore-start
// Spinner requires io.stdout.hasTerminal and Timer.periodic — not exercisable
// in headless tests. Sync commands in tests use FakeInputReader which bypasses
// the tty path entirely.

/// Animated text spinner for long-running operations.
///
/// Cycles through `|/-\` frames at 100 ms intervals, overwriting the same
/// terminal line via `\r`. Automatically suppressed when stdout is not a
/// terminal (pipe/file), in which case [start] and [stop] are no-ops.
///
/// ## Usage
///
/// ```dart
/// final spinner = Spinner();
/// spinner.start('Pushing changes…');
/// await engine.push();
/// spinner.stop();
/// ```
final class Spinner {
  /// Creates a [Spinner] that writes to [output] (defaults to stdout).
  Spinner({io.IOSink? output}) : _out = output ?? io.stdout;

  static const _frames = ['|', '/', '-', r'\'];
  static const _intervalMs = 100;

  final io.IOSink _out;
  Timer? _timer;
  int _frame = 0;

  /// Whether the spinner is currently running.
  bool get isRunning => _timer != null;

  /// Starts the spinner with [message] displayed after the frame character.
  ///
  /// No-op when stdout is not a terminal or the spinner is already running.
  void start(String message) {
    if (!io.stdout.hasTerminal) return;
    if (_timer != null) return;
    _frame = 0;
    _timer = Timer.periodic(const Duration(milliseconds: _intervalMs), (_) {
      _out.write('\r${_frames[_frame % _frames.length]} $message');
      _frame++;
    });
  }

  /// Stops the spinner and clears the spinner line.
  ///
  /// No-op when the spinner is not running.
  void stop() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    if (io.stdout.hasTerminal) {
      _out.write('\r\x1b[K'); // clear the spinner line
    }
  }
}

// coverage:ignore-end
