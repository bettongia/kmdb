import 'package:args/args.dart';

class CommandLineResult {
  final String? dbPath;
  final String? scriptFile;
  final bool isInteractive;

  CommandLineResult({this.dbPath, this.scriptFile, required this.isInteractive});
}

class CommandLineParser {
  final ArgParser _parser = ArgParser()
    ..addOption('file', abbr: 'f', help: 'Path to a script file to execute.');

  CommandLineResult parse(List<String> args) {
    final results = _parser.parse(args);
    
    String? dbPath;
    if (results.rest.isNotEmpty) {
      dbPath = results.rest.first;
    }
    
    final scriptFile = results['file'] as String?;
    final isInteractive = scriptFile == null;

    return CommandLineResult(
      dbPath: dbPath,
      scriptFile: scriptFile,
      isInteractive: isInteractive,
    );
  }
}
