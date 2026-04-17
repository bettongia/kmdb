// Copyright 2026 The KMDB Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';
import 'dart:typed_data';

import 'package:kmdb/src/vault/vault_manifest.dart';
import 'package:kmdb/src/vault/vault_package.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// Builds a minimal valid vault package containing [documentJson] and
/// optional [attachments].
Uint8List _buildPackage({
  required Map<String, dynamic> documentJson,
  List<VaultAttachment> attachments = const [],
}) => VaultPackage.write(
  documentJson: documentJson,
  attachments: attachments,
);

/// A simple document with no vault references.
final _simpleDoc = {'title': 'Hello'};

/// A vault URI for use in document JSON fields.
final _fakeUri =
    'kmdb-vault://sha256/${'a' * 64}'; // ignore: prefer_const_declarations

void main() {
  group('VaultPackage', () {
    // ── write / read round-trip ────────────────────────────────────────────

    group('write and read (round-trip)', () {
      test('round-trips a document without attachments', () {
        final bytes = _buildPackage(documentJson: _simpleDoc);
        final contents = VaultPackage.read(bytes);
        expect(contents.documentJson['title'], equals('Hello'));
        expect(contents.attachments, isEmpty);
      });

      test('round-trips a document with one attachment', () {
        final blobData = _utf8('binary blob data');
        final bytes = _buildPackage(
          documentJson: {'file': _fakeUri},
          attachments: [
            VaultAttachment(subdirName: '0', bytes: blobData),
          ],
        );

        final contents = VaultPackage.read(bytes);
        expect(contents.documentJson['file'], equals(_fakeUri));
        expect(contents.attachments.length, equals(1));
        expect(contents.attachments[0].bytes, equals(blobData));
      });

      test('round-trips a document with multiple attachments', () {
        final blob1 = _utf8('first file');
        final blob2 = _utf8('second file');
        final bytes = _buildPackage(
          documentJson: {'a': _fakeUri, 'b': 'kmdb-vault://sha256/${'b' * 64}'},
          attachments: [
            VaultAttachment(subdirName: '0', bytes: blob1),
            VaultAttachment(subdirName: '1', bytes: blob2),
          ],
        );

        final contents = VaultPackage.read(bytes);
        expect(contents.attachments.length, equals(2));
        expect(contents.attachments[0].bytes, equals(blob1));
        expect(contents.attachments[1].bytes, equals(blob2));
      });

      test('round-trips a manifest.json in the package', () {
        final manifest = VaultManifest(
          sha256: 'a' * 64,
          size: 4,
          crc32c: 'deadbeef',
          mediaType: 'text/plain',
          originalName: 'readme.txt',
          createdAt: 't1',
        );
        final blobData = _utf8('data');
        final bytes = _buildPackage(
          documentJson: {'file': _fakeUri},
          attachments: [
            VaultAttachment(
              subdirName: '0',
              bytes: blobData,
              uploadManifest: manifest,
            ),
          ],
        );

        final contents = VaultPackage.read(bytes);
        expect(contents.attachments.length, equals(1));
        final att = contents.attachments[0];
        expect(att.uploadManifest, isNotNull);
        expect(att.uploadManifest!.originalName, equals('readme.txt'));
        // blob resolved via originalName
        expect(att.bytes, equals(blobData));
      });

      test('attachment resolved by originalName when manifest is present', () {
        final manifest = VaultManifest(
          sha256: 'a' * 64,
          size: 6,
          crc32c: 'aaaabbbb',
          mediaType: 'text/plain',
          originalName: 'myfile.txt',
          createdAt: 't1',
        );
        final blobData = _utf8('myfile');
        final bytes = _buildPackage(
          documentJson: {'f': _fakeUri},
          attachments: [
            VaultAttachment(
              subdirName: '0',
              bytes: blobData,
              uploadManifest: manifest,
            ),
          ],
        );

        final contents = VaultPackage.read(bytes);
        expect(contents.attachments[0].bytes, equals(blobData));
      });

      test('empty document JSON round-trips', () {
        final bytes = _buildPackage(documentJson: {});
        final contents = VaultPackage.read(bytes);
        expect(contents.documentJson, isEmpty);
      });
    });

    // ── read error cases ───────────────────────────────────────────────────

    group('read — error cases', () {
      test('throws FormatException for missing magic', () {
        final corrupt = _utf8('XXXX\x00\x00\x00\x01');
        expect(
          () => VaultPackage.read(corrupt),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for wrong version', () {
        final bytes = _buildPackage(documentJson: _simpleDoc);
        // Patch version bytes (offset 4..7) to version 99.
        final patched = Uint8List.fromList(bytes);
        patched[4] = 0;
        patched[5] = 0;
        patched[6] = 0;
        patched[7] = 99;
        expect(
          () => VaultPackage.read(patched),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException when document.json is absent', () {
        // Write a package that only contains a vault file (no document.json).
        // We abuse the write method by building entries manually.
        final raw = _buildPackage(documentJson: _simpleDoc);
        // Truncate to just magic + version + end marker (remove all entries).
        final minimal = Uint8List(4 + 4 + 2);
        minimal.setAll(0, raw.sublist(0, 8)); // magic + version
        minimal[8] = 0; // end marker hi byte
        minimal[9] = 0; // end marker lo byte
        expect(
          () => VaultPackage.read(minimal),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for unexpected path', () {
        // Craft an archive with an unexpected top-level path.
        // We must build the raw bytes manually.
        final docPath = _utf8('document.json');
        final docData = _utf8('{}');
        final extraPath = _utf8('unexpected.txt');
        final extraData = _utf8('oops');

        final builder = BytesBuilder();
        // Magic.
        builder.add([0x4B, 0x56, 0x4C, 0x54]);
        // Version 1.
        builder.add([0x00, 0x00, 0x00, 0x01]);
        // document.json entry.
        builder.add(_uint16(docPath.length));
        builder.add(docPath);
        builder.add(_uint64(docData.length));
        builder.add(docData);
        // Unexpected entry.
        builder.add(_uint16(extraPath.length));
        builder.add(extraPath);
        builder.add(_uint64(extraData.length));
        builder.add(extraData);
        // End marker.
        builder.add([0x00, 0x00]);

        expect(
          () => VaultPackage.read(builder.toBytes()),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException when originalName file is absent', () {
        // Build a package where manifest.json specifies originalName 'foo.txt'
        // but the file in the package is named 'bar.txt'.
        final manifest = VaultManifest(
          sha256: 'a' * 64,
          size: 3,
          crc32c: 'aaaabbbb',
          mediaType: 'text/plain',
          originalName: 'expected.txt', // will be 'wrong.txt' in archive
          createdAt: 't1',
        );
        // Manually build an archive with 'wrong.txt' instead of 'expected.txt'.
        final docPath = _utf8('document.json');
        final docData = _utf8('{"f":"$_fakeUri"}');
        final manifestPath = _utf8('vault/0/manifest.json');
        final manifestData = _utf8(manifest.toJsonString());
        final blobPath = _utf8('vault/0/wrong.txt'); // wrong name
        final blobData = _utf8('hi');

        final builder = BytesBuilder();
        builder.add([0x4B, 0x56, 0x4C, 0x54]);
        builder.add([0x00, 0x00, 0x00, 0x01]);
        _addEntry(builder, docPath, docData);
        _addEntry(builder, manifestPath, manifestData);
        _addEntry(builder, blobPath, blobData);
        builder.add([0x00, 0x00]);

        expect(
          () => VaultPackage.read(builder.toBytes()),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for truncated archive', () {
        final bytes = _buildPackage(documentJson: _simpleDoc);
        // Truncate to half the size.
        final truncated = bytes.sublist(0, bytes.length ~/ 2);
        expect(
          () => VaultPackage.read(truncated),
          throwsA(isA<FormatException>()),
        );
      });
    });

    // ── validate ──────────────────────────────────────────────────────────

    group('validate', () {
      test('no-op when document has no vault URIs and no attachments', () {
        // Should not throw.
        VaultPackage.validate(
          documentJson: {'title': 'plain'},
          attachments: const [],
        );
      });

      test('throws when attachments present but no vault URIs in document', () {
        expect(
          () => VaultPackage.validate(
            documentJson: {'title': 'plain'},
            attachments: [
              VaultAttachment(subdirName: '0', bytes: _utf8('data')),
            ],
          ),
          throwsA(isA<FormatException>()),
        );
      });

      test('no-op when vault URI in document and attachment matches', () {
        final sha = 'a' * 64;
        final manifest = VaultManifest(
          sha256: sha,
          size: 4,
          crc32c: 'aaaabbbb',
          mediaType: 'text/plain',
          originalName: 'file.txt',
          createdAt: 't1',
        );
        VaultPackage.validate(
          documentJson: {'f': 'kmdb-vault://sha256/$sha'},
          attachments: [
            VaultAttachment(
              subdirName: '0',
              bytes: _utf8('data'),
              uploadManifest: manifest,
            ),
          ],
        );
      });

      test('no-op when vault URI already in existingHashes', () {
        final sha = 'b' * 64;
        // No attachments in package — URI is resolved from existing vault.
        VaultPackage.validate(
          documentJson: {'f': 'kmdb-vault://sha256/$sha'},
          attachments: const [],
          existingHashes: {sha},
        );
      });
    });
  });
}

// ── Byte-encoding helpers for test archive construction ───────────────────────

Uint8List _uint16(int v) {
  final b = ByteData(2);
  b.setUint16(0, v, Endian.big);
  return b.buffer.asUint8List();
}

Uint8List _uint64(int v) {
  final b = ByteData(8);
  b.setUint32(0, (v >> 32) & 0xFFFFFFFF, Endian.big);
  b.setUint32(4, v & 0xFFFFFFFF, Endian.big);
  return b.buffer.asUint8List();
}

void _addEntry(BytesBuilder builder, Uint8List path, Uint8List data) {
  builder.add(_uint16(path.length));
  builder.add(path);
  builder.add(_uint64(data.length));
  builder.add(data);
}
