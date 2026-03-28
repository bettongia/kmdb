import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:kmdb/src/engine/manifest/current_file.dart';
import 'package:kmdb/src/engine/manifest/manifest_reader.dart';
import 'package:kmdb/src/engine/manifest/manifest_writer.dart';
import 'package:kmdb/src/engine/manifest/version_edit.dart';
import 'package:kmdb/src/engine/platform/storage_adapter_memory.dart';

const _dir = '/db';
const _manifestName = 'MANIFEST-00001';
const _manifestPath = '$_dir/$_manifestName';

VersionEdit _edit({
  int log = 1,
  int seq = 100,
  List<SstableMeta> added = const [],
  List<SstableRef> removed = const [],
}) =>
    VersionEdit(
      logNumber: log,
      nextSeq: seq,
      added: added,
      removed: removed,
    );

SstableMeta _meta(String filename, {int level = 0}) => SstableMeta(
      level: level,
      filename: filename,
      minKey: '0' * 32,
      maxKey: 'f' * 32,
      entryCount: 10,
    );

void main() {
  group('VersionEdit CBOR round-trip', () {
    test('empty edit round-trips', () {
      final edit = _edit();
      final decoded = VersionEdit.fromCbor(edit.toCbor());
      expect(decoded.logNumber, equals(1));
      expect(decoded.nextSeq, equals(100));
      expect(decoded.added, isEmpty);
      expect(decoded.removed, isEmpty);
    });

    test('add and remove entries survive round-trip', () {
      final edit = _edit(
        log: 3,
        seq: 5000,
        added: [
          SstableMeta(
            level: 0,
            filename: 'abc-000001-000002.sst',
            minKey: '0' * 32,
            maxKey: 'f' * 32,
            entryCount: 128,
            walSequence: 3,
          )
        ],
        removed: [
          const SstableRef(level: 0, filename: 'old-000000-000001.sst')
        ],
      );
      final decoded = VersionEdit.fromCbor(edit.toCbor());
      expect(decoded.added.length, equals(1));
      expect(decoded.added[0].walSequence, equals(3));
      expect(decoded.removed.length, equals(1));
      expect(decoded.removed[0].filename, equals('old-000000-000001.sst'));
    });
  });

  group('ManifestWriter / ManifestReader', () {
    test('single edit is readable after write', () async {
      final adapter = MemoryStorageAdapter();
      final writer =
          ManifestWriter(path: _manifestPath, adapter: adapter);
      final edit = _edit(log: 1, seq: 200,
          added: [_meta('a1b2c3d4-000001-000002.sst')]);
      await writer.append(edit);

      final reader = ManifestReader(adapter: adapter);
      final state = await reader.replay(_manifestPath);
      expect(state.levels[0], contains('a1b2c3d4-000001-000002.sst'));
      expect(state.maxLogNumber, equals(1));
      expect(state.maxNextSeq, equals(200));
    });

    test('multiple edits accumulate level state', () async {
      final adapter = MemoryStorageAdapter();
      final writer =
          ManifestWriter(path: _manifestPath, adapter: adapter);

      await writer.append(_edit(log: 1, seq: 100,
          added: [_meta('file1.sst')]));
      await writer.append(_edit(log: 2, seq: 200,
          added: [_meta('file2.sst')],
          removed: [const SstableRef(level: 0, filename: 'file1.sst')]));
      await writer.append(_edit(log: 3, seq: 300,
          added: [_meta('file3.sst', level: 1)]));

      final state = await ManifestReader(adapter: adapter).replay(_manifestPath);
      expect(state.levels[0], equals(['file2.sst']));
      expect(state.levels[1], contains('file3.sst'));
      expect(state.maxLogNumber, equals(3));
      expect(state.maxNextSeq, equals(300));
    });

    test('corrupted last record is silently ignored', () async {
      final adapter = MemoryStorageAdapter();
      final writer =
          ManifestWriter(path: _manifestPath, adapter: adapter);
      await writer.append(_edit(log: 1, seq: 100,
          added: [_meta('file1.sst')]));
      await writer.append(_edit(log: 2, seq: 200,
          added: [_meta('file2.sst')]));

      // Corrupt the last few bytes of the file to simulate truncation.
      final raw = adapter.files[_manifestPath]!;
      final corrupted = Uint8List.fromList(raw);
      corrupted[corrupted.length - 1] ^= 0xFF;
      adapter.files[_manifestPath] = corrupted;

      final state = await ManifestReader(adapter: adapter).replay(_manifestPath);
      // Only the first record should be visible.
      expect(state.levels[0], equals(['file1.sst']));
    });

    test('returns empty state when file does not exist', () async {
      final adapter = MemoryStorageAdapter();
      final state = await ManifestReader(adapter: adapter)
          .replay('/nonexistent/MANIFEST-00001');
      expect(state.levels[0], isEmpty);
      expect(state.maxLogNumber, equals(0));
    });

    test('allFiles spans all levels', () async {
      final adapter = MemoryStorageAdapter();
      final writer =
          ManifestWriter(path: _manifestPath, adapter: adapter);
      await writer.append(_edit(added: [
        _meta('l0.sst', level: 0),
        _meta('l1.sst', level: 1),
        _meta('l2.sst', level: 2),
      ]));
      final state =
          await ManifestReader(adapter: adapter).replay(_manifestPath);
      expect(state.allFiles.toSet(),
          equals({'l0.sst', 'l1.sst', 'l2.sst'}));
    });
  });

  group('CurrentFile', () {
    test('write then read returns same manifest name', () async {
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      await cf.write(_manifestName);
      expect(await cf.read(), equals(_manifestName));
    });

    test('manifestPath returns full path', () async {
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      await cf.write(_manifestName);
      expect(await cf.manifestPath(), equals(_manifestPath));
    });

    test('exists returns false before write', () async {
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      expect(await cf.exists(), isFalse);
    });

    test('exists returns true after write', () async {
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      await cf.write(_manifestName);
      expect(await cf.exists(), isTrue);
    });

    test('nextManifestName increments sequence', () {
      expect(CurrentFile.nextManifestName('MANIFEST-00001'),
          equals('MANIFEST-00002'));
      expect(CurrentFile.nextManifestName('MANIFEST-00009'),
          equals('MANIFEST-00010'));
    });

    test('nextManifestName throws on invalid format', () {
      expect(
        () => CurrentFile.nextManifestName('INVALID'),
        throwsA(isA<FormatException>()),
      );
    });

    test('write is atomic — uses rename', () async {
      // In the memory adapter rename is atomic; check the tmp file is cleaned up.
      final adapter = MemoryStorageAdapter();
      final cf = CurrentFile(dbDir: _dir, adapter: adapter);
      await cf.write(_manifestName);
      expect(adapter.files.containsKey('$_dir/CURRENT.tmp'), isFalse);
      expect(adapter.files.containsKey('$_dir/CURRENT'), isTrue);
    });
  });
}
