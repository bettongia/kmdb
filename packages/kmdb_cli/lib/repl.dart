/*
 Copyright 2026 The Aurochs KMesh Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A handler for single lines of input in the REPL.
typedef LineHandler = void Function(String line);

/// A Read-Eval-Print Loop (REPL) for interactive database interaction.
class REPL {
  /// The handler for each line of input.
  final LineHandler onLine;
  
  /// The prompt string to display to the user.
  final String prompt;

  /// Creates a new [REPL] with the given [onLine] handler and optional [prompt].
  REPL({required this.onLine, this.prompt = '> '});

  /// Runs the REPL, taking input from the provided [inputStream].
  /// For interactive sessions, this will typically be stdin.
  Future<void> run([Stream<String>? inputStream]) async {
    final stream = inputStream ?? _stdinLineStream();

    await for (final line in stream) {
      if (line.trim() == 'exit') {
        onLine('Exiting.');
        break;
      }
      onLine('Processing: ${line.trim()}');
    }
  }

  Stream<String> _stdinLineStream() {
    stdout.write(prompt);
    return stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) {
      stdout.write(prompt);
      return line;
    });
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is REPL &&
          runtimeType == other.runtimeType &&
          prompt == other.prompt;

  @override
  int get hashCode => prompt.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {
        'prompt': prompt,
      };
}
