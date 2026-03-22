import 'dart:async';
import 'dart:io';
import 'dart:convert';

typedef LineHandler = void Function(String line);

class BatchRunner {
  final LineHandler onLine;

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
}
