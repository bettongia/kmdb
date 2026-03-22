import 'dart:typed_data';
import 'package:kmdb/kmdb.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

void main() async {
  final dbPath = p.join(Directory.systemTemp.path, 'kmdb_example.db');
  final engine = StorageEngine(dbPath);

  try {
    print('Opening database at $dbPath...');
    await engine.open();

    final key = Uint8List.fromList('hello'.codeUnits);
    final value = Uint8List.fromList('world'.codeUnits);

    print('Putting key-value pair...');
    await engine.put(key, value);

    print('Getting value for key "hello"...');
    final result = await engine.get(key);
    if (result != null) {
      print('Retrieved: ${String.fromCharCodes(result)}');
    }

    print('Compacting database...');
    await engine.compact();

    print('Retrieving all entries:');
    final all = await engine.getAll();
    for (final entry in all) {
      print('  ${String.fromCharCodes(entry.key)}: ${String.fromCharCodes(entry.value)}');
    }

  } finally {
    await engine.close();
    print('Database closed.');
  }
}
