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

import 'dart:convert';
import 'package:args/args.dart';

/// Represents the results of parsing command-line arguments.
class CommandLineResult {
  /// The path to the database file, if provided.
  final String? dbPath;
  
  /// The path to a script file to execute, if provided.
  final String? scriptFile;
  
  /// Whether the session should be interactive (REPL).
  final bool isInteractive;
  
  /// The subcommand to execute, if provided.
  final String? subcommand;

  /// Creates a new [CommandLineResult] with the given parameters.
  CommandLineResult({
    this.dbPath,
    this.scriptFile,
    required this.isInteractive,
    this.subcommand,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandLineResult &&
          runtimeType == other.runtimeType &&
          dbPath == other.dbPath &&
          scriptFile == other.scriptFile &&
          isInteractive == other.isInteractive &&
          subcommand == other.subcommand;

  @override
  int get hashCode =>
      dbPath.hashCode ^
      scriptFile.hashCode ^
      isInteractive.hashCode ^
      subcommand.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {
        'dbPath': dbPath,
        'scriptFile': scriptFile,
        'isInteractive': isInteractive,
        'subcommand': subcommand,
      };
}

/// A parser for kmdb-specific command-line arguments.
class CommandLineParser {
  final ArgParser _parser = ArgParser()
    ..addOption('file', abbr: 'f', help: 'Path to a script file to execute.')
    ..addCommand('list-dbs')
    ..addCommand('list-namespaces')
    ..addCommand('list-indexes')
    ..addCommand('compact')
    ..addCommand('check-integrity')
    ..addCommand('backup');

  /// Parses the given [args] and returns a [CommandLineResult].
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandLineParser && runtimeType == other.runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {};
}
