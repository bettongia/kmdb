// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:io' as io;

import 'package:kmdb_cli/src/repl/history.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late io.Directory tmpDir;
  late String histPath;

  setUp(() async {
    tmpDir = await io.Directory.systemTemp.createTemp('kmdb_history_test_');
    histPath = p.join(tmpDir.path, 'history');
  });

  tearDown(() async {
    await tmpDir.delete(recursive: true);
  });

  History make() => History(filePath: histPath);

  group('add', () {
    test('records entries in order', () {
      final h = make();
      h.add('scan notes');
      h.add('get notes abc');
      expect(h.entries, ['scan notes', 'get notes abc']);
    });

    test('ignores blank lines', () {
      final h = make();
      h.add('');
      h.add('   ');
      expect(h.entries, isEmpty);
    });

    test('deduplicates consecutive identical entries', () {
      final h = make();
      h.add('scan notes');
      h.add('scan notes');
      h.add('scan notes');
      expect(h.entries, ['scan notes']);
    });

    test('allows same entry non-consecutively', () {
      final h = make();
      h.add('scan notes');
      h.add('count notes');
      h.add('scan notes');
      expect(h.entries, ['scan notes', 'count notes', 'scan notes']);
    });

    test('trims to maxEntries', () {
      final h = make();
      for (var i = 0; i < History.maxEntries + 10; i++) {
        h.add('cmd $i');
      }
      expect(h.entries.length, History.maxEntries);
      expect(h.entries.first, 'cmd 10');
    });
  });

  group('load / save', () {
    test('round-trips entries through file', () async {
      final h = make();
      h.add('scan notes');
      h.add('get notes abc');
      await h.save();

      final h2 = make();
      await h2.load();
      expect(h2.entries, ['scan notes', 'get notes abc']);
    });

    test('load is a no-op when file does not exist', () async {
      final h = History(filePath: p.join(tmpDir.path, 'nonexistent'));
      await h.load();
      expect(h.entries, isEmpty);
    });

    test('caps entries to maxEntries on load', () async {
      // Write more than maxEntries lines to the file.
      final lines = List.generate(History.maxEntries + 5, (i) => 'cmd $i');
      await io.File(histPath).writeAsString(lines.join('\n'));

      final h = make();
      await h.load();
      expect(h.entries.length, History.maxEntries);
      expect(h.entries.first, 'cmd 5');
    });
  });

  group('recent', () {
    test('returns last n entries with 1-based indices', () {
      final h = make();
      for (var i = 1; i <= 5; i++) {
        h.add('cmd $i');
      }
      final r = h.recent(3);
      expect(r, [(3, 'cmd 3'), (4, 'cmd 4'), (5, 'cmd 5')]);
    });

    test('returns all when fewer than n entries exist', () {
      final h = make();
      h.add('only one');
      expect(h.recent(20), [(1, 'only one')]);
    });

    test('returns empty list when history is empty', () {
      expect(make().recent(), isEmpty);
    });
  });

  group('getByIndex', () {
    test('returns entry at 1-based index', () {
      final h = make();
      h.add('first');
      h.add('second');
      expect(h.getByIndex(1), 'first');
      expect(h.getByIndex(2), 'second');
    });

    test('returns null for out-of-range index', () {
      final h = make();
      h.add('only');
      expect(h.getByIndex(0), isNull);
      expect(h.getByIndex(2), isNull);
    });
  });
}
