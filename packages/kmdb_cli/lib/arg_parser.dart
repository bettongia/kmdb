import 'package:args/args.dart';

class CommandLineResult {
  final String? dbPath;
  final String? scriptFile;
  final bool isInteractive;
  final String? subcommand;

  CommandLineResult({
    this.dbPath,
    this.scriptFile,
    required this.isInteractive,
    this.subcommand,
  });
}

class CommandLineParser {
  final ArgParser _parser = ArgParser()
    ..addOption('file', abbr: 'f', help: 'Path to a script file to execute.')
    ..addCommand('list-dbs')
    ..addCommand('list-namespaces')
    ..addCommand('list-indexes')
    ..addCommand('compact')
    ..addCommand('check-integrity')
    ..addCommand('backup');

  CommandLineResult parse(List<String> args) {
    // Pre-process args to handle dbPath before command
    String? dbPath;
    final remainingArgs = <String>[];
    
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith('-')) {
        remainingArgs.add(arg);
        // If it's an option that takes a value, add the next arg too
        if ((arg == '--file' || arg == '-f') && i + 1 < args.length) {
          remainingArgs.add(args[++i]);
        }
      } else if (_parser.commands.containsKey(arg)) {
        remainingArgs.addAll(args.sublist(i));
        break;
      } else if (dbPath == null) {
        dbPath = arg;
      } else {
        remainingArgs.add(arg);
      }
    }

    final results = _parser.parse(remainingArgs);

    String? subcommand;
    if (results.command != null) {
      subcommand = results.command!.name;
    }

    final scriptFile = results['file'] as String?;
    final isInteractive = scriptFile == null && subcommand == null;

    return CommandLineResult(
      dbPath: dbPath,
      scriptFile: scriptFile,
      isInteractive: isInteractive,
      subcommand: subcommand,
    );
  }
}
