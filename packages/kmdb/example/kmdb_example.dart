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
      print(
        '  ${String.fromCharCodes(entry.key)}: ${String.fromCharCodes(entry.value)}',
      );
    }
  } finally {
    await engine.close();
    print('Database closed.');
  }
}
