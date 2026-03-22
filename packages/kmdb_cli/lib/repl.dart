import 'dart:async';
import 'dart:io';
import 'dart:convert';

typedef LineHandler = void Function(String line);

class REPL {
  final LineHandler onLine;
  final String prompt;

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
}
