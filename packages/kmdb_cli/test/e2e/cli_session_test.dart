@Tags(['e2e'])
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dbDir;
  late String dbPath;
  late String exePath;

  setUpAll(() async {
    // Compile CLI to exe
    final binPath = p.absolute('bin', 'kmdb.dart');
    exePath = p.absolute('bin', 'kmdb_e2e.exe');
    print('Compiling $binPath to $exePath...');
    final result = await Process.run('dart', ['compile', 'exe', binPath, '-o', exePath]);
    if (result.exitCode != 0) {
      fail('Failed to compile CLI: ${result.stderr}');
    }
  });

  tearDownAll(() {
    final file = File(exePath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  });

  setUp(() {
    dbDir = Directory.systemTemp.createTempSync('kmdb_e2e_');
    dbPath = p.join(dbDir.path, 'test.kmdb');
  });

  tearDown(() {
    if (dbDir.existsSync()) {
      dbDir.deleteSync(recursive: true);
    }
  });

  test('Replicate non-trivial user session (3000 records)', () async {
    final harness = CliHarness(exePath, dbPath);

    // Phase 1: Ingestion
    print('Phase 1: Ingestion (3000 records)...');
    final notes = <Map<String, dynamic>>[];
    final readingList = <Map<String, dynamic>>[];
    final shoppingList = <Map<String, dynamic>>[];

    final random = Random(42);

    // Track some IDs for later verification (10%)
    final capturedNotes = <Map<String, dynamic>>[];
    final capturedReading = <Map<String, dynamic>>[];
    final capturedShopping = <Map<String, dynamic>>[];

    for (var i = 0; i < 1000; i++) {
      final flush = random.nextBool();
      
      final note = NoteGenerator.generate(i, random);
      final noteResult = await harness.put('notes', note, flush: flush);
      if (i % 10 == 0) capturedNotes.add(noteResult);

      final reading = ReadingListGenerator.generate(i, random);
      final readingResult = await harness.put('reading_list', reading, flush: flush);
      if (i % 10 == 0) capturedReading.add(readingResult);

      final shopping = ShoppingListGenerator.generate(i, random);
      final shoppingResult = await harness.put('shopping_list', shopping, flush: flush);
      if (i % 10 == 0) capturedShopping.add(shoppingResult);

      // Occasional point lookup and deletion during ingestion
      if (i > 0 && i % 200 == 0) {
        final noteIdx = random.nextInt(capturedNotes.length);
        final sampleNote = capturedNotes[noteIdx];
        final retrieved = await harness.get('notes', sampleNote['id']);
        expect(retrieved['title'], sampleNote['title']);

        // Delete one
        final readingIdx = random.nextInt(capturedReading.length);
        final sampleReading = capturedReading.removeAt(readingIdx);
        await harness.run(['delete', 'reading_list', sampleReading['id']]);
        final gone = await harness.run(['get', 'reading_list', sampleReading['id']]);
        expect(gone.exitCode, isNot(0));
      }

      if ((i + 1) % 100 == 0) {
        print('  Ingested ${i + 1} records per collection...');
      }
    }

    // Phase 2: Point Lookups
    print('Phase 2: Point Lookups...');
    for (final expected in capturedNotes) {
      final actual = await harness.get('notes', expected['id']);
      expect(actual['title'], expected['title']);
    }
    for (final expected in capturedReading) {
      final actual = await harness.get('reading_list', expected['id']);
      expect(actual['title'], expected['title']);
    }
    for (final expected in capturedShopping) {
      final actual = await harness.get('shopping_list', expected['id']);
      expect(actual['item'], expected['item']);
    }

    // Verify non-existent
    for (var i = 0; i < 10; i++) {
      final ghostId = '0000000000000000000000000000000' + i.toString();
      final ghost = await harness.run(['get', 'notes', ghostId]);
      expect(ghost.exitCode, isNot(0));
    }

    // Phase 3: Bulk Operations & Output Modes
    print('Phase 3: Bulk Operations & Output Modes...');
    final notesCount = await harness.count('notes');
    expect(notesCount, 1000);
    final readingCount = await harness.count('reading_list');
    expect(readingCount, 996);
    final shoppingCount = await harness.count('shopping_list');
    expect(shoppingCount, 1000);

    // Filtered scan
    final neededShopping = await harness.scan('shopping_list', 
      filter: {'field': 'needed', 'op': 'eq', 'value': true});
    expect(neededShopping.every((doc) => doc['needed'] == true), isTrue);

    // Test NDJSON mode
    print('  Testing NDJSON mode...');
    final ndjsonResult = await harness.run(['--mode', 'ndjson', 'scan', 'shopping_list', '--limit', '5']);
    expect(ndjsonResult.exitCode, 0);
    final ndjsonLines = (ndjsonResult.stdout as String).trim().split('\n');
    expect(ndjsonLines.length, 5);
    for (final line in ndjsonLines) {
      expect(() => jsonDecode(line), returnsNormally);
    }

    // Test Table mode
    print('  Testing Table mode...');
    final tableResult = await harness.run(['--mode', 'table', 'scan', 'shopping_list', '--limit', '5']);
    expect(tableResult.exitCode, 0);
    expect(tableResult.stdout as String, contains('item'));
    expect(tableResult.stdout as String, contains('quantity'));
    expect(tableResult.stdout as String, contains('needed'));

    // Phase 4: Deletion
    print('Phase 4: Deletion...');
    final notesToDelete = capturedNotes.take(5).toList();
    for (final note in notesToDelete) {
      final delResult = await harness.run(['delete', 'notes', note['id']]);
      expect(delResult.exitCode, 0);
      
      // Verify immediate recall failure
      final gone = await harness.run(['get', 'notes', note['id']]);
      expect(gone.exitCode, isNot(0));
    }

    final afterDelCount = await harness.count('notes');
    expect(afterDelCount, 995);

    // Phase 5: Maintenance
    print('Phase 5: Maintenance...');
    expect((await harness.run(['flush'])).exitCode, 0);
    expect((await harness.run(['compact'])).exitCode, 0);
    expect((await harness.run(['verify'])).exitCode, 0);

    print('E2E Test Session Complete.');
  }, timeout: const Timeout(Duration(minutes: 60)));
}

class CliHarness {
  final String exePath;
  final String dbPath;

  CliHarness(this.exePath, this.dbPath);

  Future<ProcessResult> run(List<String> args, {bool flush = true}) async {
    final allArgs = [
      if (!flush) '--no-flush',
      dbPath,
      ...args,
    ];
    return Process.run(exePath, allArgs);
  }

  Future<Map<String, dynamic>> put(String ns, Map<String, dynamic> doc, {bool flush = true}) async {
    final result = await run(['put', ns, '--value', jsonEncode(doc)], flush: flush);
    if (result.exitCode != 0) {
      throw Exception('put failed: ${result.stderr}');
    }
    final output = jsonDecode(result.stdout as String);
    // put echoes an array of inserted documents
    return (output as List).first as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> get(String ns, String id) async {
    final result = await run(['get', ns, id]);
    if (result.exitCode != 0) {
      throw Exception('get failed: ${result.stderr}');
    }
    final output = jsonDecode(result.stdout as String);
    return (output as List).first as Map<String, dynamic>;
  }

  Future<int> count(String ns, {Map<String, dynamic>? filter}) async {
    final args = ['count', ns];
    if (filter != null) {
      args.addAll(['--filter', jsonEncode(filter)]);
    }
    final result = await run(args);
    if (result.exitCode != 0) {
      throw Exception('count failed: ${result.stderr}');
    }
    final output = jsonDecode(result.stdout as String);
    return output['count'] as int;
  }

  Future<List<Map<String, dynamic>>> scan(String ns, {Map<String, dynamic>? filter}) async {
    final args = ['scan', ns];
    if (filter != null) {
      args.addAll(['--filter', jsonEncode(filter)]);
    }
    final result = await run(args);
    if (result.exitCode != 0) {
      throw Exception('scan failed: ${result.stderr}');
    }
    final output = jsonDecode(result.stdout as String);
    return (output as List).cast<Map<String, dynamic>>();
  }
}

class NoteGenerator {
  static Map<String, dynamic> generate(int i, Random r) {
    return {
      'title': 'Note #$i',
      'body': 'This is the body for note $i. ' * (r.nextInt(5) + 1),
      'tags': ['tag${r.nextInt(10)}', 'tag${r.nextInt(10)}'],
      'creation_date': DateTime.now().subtract(Duration(days: i)).toIso8601String(),
    };
  }
}

class ReadingListGenerator {
  static Map<String, dynamic> generate(int i, Random r) {
    return {
      'title': 'Book #$i',
      'authors': ['Author ${r.nextInt(100)}', 'Author ${r.nextInt(100)}'],
      'tags': ['genre${r.nextInt(5)}'],
      'review': 'Review for book $i: ' + ('Excellent. ' * r.nextInt(3)),
    };
  }
}

class ShoppingListGenerator {
  static Map<String, dynamic> generate(int i, Random r) {
    return {
      'item': 'Item #$i',
      'quantity': r.nextInt(10) + 1,
      'needed': r.nextBool(),
    };
  }
}
