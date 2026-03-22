import 'dart:async';

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
}
