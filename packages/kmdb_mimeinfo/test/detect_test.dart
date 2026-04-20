/*
 Copyright 2026 The KMDB Authors

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

import 'dart:io';
import 'dart:typed_data';

import 'package:kmdb_mimeinfo/registry.dart';
import 'package:test/test.dart';

void main() {
  group('Match magic - test/data files', () {
    void testDetect(
      String fileName,
      String expectedMediaTypeForGlob,
      String expectedMediaTypeForMagic,
      String expectedFullBestMatch, {
      bool magicNull = false,
      String? dirOverride,
    }) {
      final category = expectedMediaTypeForGlob.split('/').first;
      test('glob matches $fileName: $expectedMediaTypeForGlob', () {
        final globMatches = detect(fileName: fileName);

        expect(globMatches.bestMatch, equals(expectedMediaTypeForGlob));
      });

      final Uint8List fileData;

      if (dirOverride != null) {
        fileData = File('test/data/$dirOverride/$fileName').readAsBytesSync();
      } else {
        fileData = File('test/data/$category/$fileName').readAsBytesSync();
      }

      test('magic matches $fileName: $expectedMediaTypeForMagic', () {
        final magicMatches = detect(bytes: fileData);
        if (magicNull) {
          expect(magicMatches.bestMatch, isNull);
        } else {
          expect(magicMatches.bestMatch, equals(expectedMediaTypeForMagic));
        }
      });
      test('full matches $fileName: $expectedMediaTypeForMagic', () {
        final fullMatch = detect(fileName: fileName, bytes: fileData);

        expect(fullMatch.bestMatch, equals(expectedFullBestMatch));
      });
    }

    group('application', () {
      testDetect(
        'test.xml',
        'application/xml',
        'application/xml',
        'application/xml',
      );
      testDetect(
        'docbook_4.xml',
        'application/xml',
        'application/x-docbook+xml',
        'application/x-docbook+xml',
      );
      testDetect(
        'docbook_5.xml',
        'application/xml',
        'application/xml',
        'application/xml',
      );
      testDetect(
        'test.pdf',
        'application/pdf',
        'application/pdf',
        'application/pdf',
      );
      testDetect(
        'test.xhtml',
        'application/xhtml+xml',
        'application/xhtml+xml',
        'application/xhtml+xml',
      );
      testDetect(
        'test.rdf',
        'application/rdf+xml',
        'application/xml',
        'application/rdf+xml',
      );
      testDetect(
        'test.atom',
        'application/atom+xml',
        'application/atom+xml',
        'application/atom+xml',
      );
      testDetect(
        'test.owx',
        'application/owl+xml',
        'application/xml',
        'application/owl+xml',
      );
      testDetect(
        'test.json',
        'application/json',
        'application/json',
        'application/json',
        magicNull: true,
      );
      testDetect(
        'test_atom.xml',
        'application/xml',
        'application/atom+xml',
        'application/atom+xml',
      );
      testDetect(
        'test_xhtml.xml',
        'application/xml',
        'application/xhtml+xml',
        'application/xhtml+xml',
      );
      testDetect(
        'test.docx',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/zip',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
      testDetect(
        'test.xlsx',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/zip',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      testDetect(
        'test.pptx',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'application/zip',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      );
      testDetect(
        'test.key',
        'application/vnd.apple.keynote',
        'application/zip',
        'application/vnd.apple.keynote',
      );
      testDetect(
        'test.pages',
        'application/vnd.apple.pages',
        'application/vnd.apple.pages',
        'application/vnd.apple.pages',
      );
      testDetect(
        'test.numbers',
        'application/vnd.apple.numbers',
        'application/vnd.apple.pages',
        'application/vnd.apple.numbers',
      );
      testDetect(
        'test.epub',
        'application/epub+zip',
        'application/epub+zip',
        'application/epub+zip',
      );
      testDetect(
        'test.odt',
        'application/vnd.oasis.opendocument.text',
        'application/vnd.oasis.opendocument.text',
        'application/vnd.oasis.opendocument.text',
      );
      testDetect(
        'test.ps',
        'application/postscript',
        'application/postscript',
        'application/postscript',
      );
      testDetect(
        'test.rtf',
        'application/rtf',
        'application/rtf',
        'application/rtf',
      );
      testDetect(
        'test.tar',
        'application/x-tar',
        'application/x-tar',
        'application/x-tar',
      );
      testDetect(
        'test.tar.gz',
        'application/gzip',
        'application/gzip',
        'application/gzip',
      );
      testDetect(
        'test.txt.gz',
        'application/gzip',
        'application/gzip',
        'application/gzip',
      );
      testDetect(
        'test.zip',
        'application/zip',
        'application/zip',
        'application/zip',
      );
    });

    group('audio', () {
      testDetect('test.mp3', 'audio/mpeg', 'audio/mpeg', 'audio/mpeg');
      testDetect('test.aac', 'audio/aac', 'audio/aac', 'audio/aac');
      testDetect('test.aiff', 'audio/x-aiff', 'audio/x-aiff', 'audio/x-aiff');
      testDetect('test.flac', 'audio/flac', 'audio/flac', 'audio/flac');
      testDetect(
        'test.wav',
        'audio/vnd.wave',
        'audio/vnd.wave',
        'audio/vnd.wave',
      );
      testDetect('test_alac.m4a', 'audio/mp4', 'audio/mp4', 'audio/mp4');
    });

    group('image', () {
      testDetect('test.heic', 'image/heif', 'image/heif', 'image/heif');
      testDetect('test.jpg', 'image/jpeg', 'image/jpeg', 'image/jpeg');
      testDetect('test.png', 'image/png', 'image/png', 'image/png');
      testDetect('test.tiff', 'image/tiff', 'image/tiff', 'image/tiff');
      testDetect('test.svg', 'image/svg+xml', 'image/svg+xml', 'image/svg+xml');
      testDetect('test.webp', 'image/webp', 'image/webp', 'image/webp');
      testDetect('test.gif', 'image/gif', 'image/gif', 'image/gif');
      testDetect('test.bmp', 'image/bmp', 'image/bmp', 'image/bmp');
    });

    group('text', () {
      testDetect('test.txt', 'text/plain', '', 'text/plain', magicNull: true);
      testDetect(
        'test.md',
        'text/markdown',
        '',
        'text/markdown',
        magicNull: true,
      );
      testDetect('test.html', 'text/html', 'text/html', 'text/html');
      testDetect('test_html4.html', 'text/html', 'text/html', 'text/html');
      testDetect('test.tex', 'text/x-tex', 'text/x-tex', 'text/x-tex');
      testDetect(
        'test.ttl',
        'text/turtle',
        ',',
        'text/turtle',
        magicNull: true,
      );
      testDetect('test.csv', 'text/csv', ',', 'text/csv', magicNull: true);
      testDetect('test.css', 'text/css', 'text/x-csrc', 'text/css');
      testDetect('test.rst', 'text/x-rst', '', 'text/x-rst', magicNull: true);
      testDetect(
        'test.tsv',
        'text/tab-separated-values',
        '',
        'text/tab-separated-values',
        magicNull: true,
      );
      test(
        'matches test.adoc content',
        () {},
        skip: 'AsciiDoc not in registry',
      );
      test(
        'matches test.asciidoc content',
        () {},
        skip: 'AsciiDoc not in registry',
      );

      group('programming samples', () {
        testDetect(
          'test.dart',
          'application/vnd.dart',
          'text/x-csrc',
          'application/vnd.dart',
          dirOverride: 'programming/dart',
        );
        testDetect(
          'test.py',
          'text/x-python',
          'text/x-python3',
          'text/x-python3',
          dirOverride: 'programming/python',
        );
        testDetect(
          'test.js',
          'text/javascript',
          '',
          'text/javascript',
          magicNull: true,
          dirOverride: 'programming/javascript',
        );
        testDetect(
          'test.sh',
          'application/x-shellscript',
          'application/x-shellscript',
          'application/x-shellscript',
          dirOverride: 'programming/shell',
        );
        testDetect(
          'test.c',
          'text/x-csrc',
          'text/x-csrc',
          'text/x-csrc',
          dirOverride: 'programming/c',
        );
        testDetect(
          'test.cpp',
          'text/x-c++src',
          'text/x-csrc',
          'text/x-c++src',
          dirOverride: 'programming/cpp',
        );
        testDetect(
          'test.java',
          'text/x-java',
          'text/x-csrc',
          'text/x-java',
          dirOverride: 'programming/java',
        );
        testDetect(
          'test.cs',
          'text/x-csharp',
          'text/x-csrc',
          'text/x-csharp',
          dirOverride: 'programming/csharp',
        );
        testDetect(
          'test.rs',
          'text/rust',
          'text/x-csrc',
          'text/rust',
          dirOverride: 'programming/rust',
        );
        testDetect(
          'test.go',
          'text/x-go',
          'text/x-csrc',
          'text/x-go',
          dirOverride: 'programming/go',
        );
        testDetect(
          'test.kt',
          'text/x-kotlin',
          'text/x-csrc',
          'text/x-kotlin',
          dirOverride: 'programming/kotlin',
        );
        testDetect(
          'test.php',
          'application/x-php',
          'application/x-php',
          'application/x-php',
          dirOverride: 'programming/php',
        );
      });

      group('video', () {
        testDetect('test.mp4', 'video/mp4', 'video/mp4', 'video/mp4');
        testDetect('test.ogv', 'video/ogg', 'audio/x-flac+ogg', 'video/ogg');
        testDetect('test.webm', 'video/webm', 'video/webm', 'video/webm');
        testDetect(
          'test.mov',
          'video/quicktime',
          'video/quicktime',
          'video/quicktime',
        );
        testDetect(
          'test.mkv',
          'video/x-matroska',
          'application/x-matroska',
          'video/x-matroska',
        );
        testDetect(
          'test.avi',
          'video/vnd.avi',
          'video/vnd.avi',
          'video/vnd.avi',
        );
        testDetect('test.3gp', 'video/3gpp', 'video/3gpp', 'video/3gpp');
      });
    });
  });
}
