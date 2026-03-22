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

/// A handler for single command lines in a batch execution.
typedef LineHandler = void Function(String line);

/// Executes a batch of commands from a stream or a file.
class BatchRunner {
  /// The handler for each line processed.
  final LineHandler onLine;

  /// Creates a new [BatchRunner] with the given [onLine] handler.
  BatchRunner({required this.onLine});

  /// Runs the batch process, executing commands from the provided [inputStream].
  Future<void> run(Stream<String> inputStream) async {
    await for (final line in inputStream) {
      final trimmedLine = line.trim();
      if (trimmedLine.isNotEmpty) {
        onLine('Executing: $trimmedLine');
      }
    }
  }

  /// Runs the batch process from a script file at the specified [path].
  Future<void> runFromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Script file not found', path);
    }
    final stream = file.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await run(stream);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BatchRunner && runtimeType == other.runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {};
}
