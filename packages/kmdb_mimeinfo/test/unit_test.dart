// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';
import 'dart:typed_data';

import 'package:kmdb_mimeinfo/src/glob.dart';
import 'package:kmdb_mimeinfo/src/icon.dart';
import 'package:kmdb_mimeinfo/src/magic.dart';
import 'package:kmdb_mimeinfo/src/xml.dart';
import 'package:test/test.dart';

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  // RootXML
  // ──────────────────────────────────────────────────────────────────────────

  group('RootXML', () {
    const svg = RootXML(
      namespaceURI: 'http://www.w3.org/2000/svg',
      localName: 'svg',
    );
    const svgSame = RootXML(
      namespaceURI: 'http://www.w3.org/2000/svg',
      localName: 'svg',
    );
    const other = RootXML(namespaceURI: 'http://example.com', localName: 'foo');

    test('equality — same values are equal', () {
      expect(svg, equals(svgSame));
    });

    test('equality — different values are not equal', () {
      expect(svg, isNot(equals(other)));
    });

    test('hashCode is consistent with equality', () {
      expect(svg.hashCode, equals(svgSame.hashCode));
    });

    test('default weight is 50', () {
      expect(svg.weight, equals(50));
    });

    test('custom weight is preserved', () {
      const r = RootXML(namespaceURI: 'ns', localName: 'x', weight: 80);
      expect(r.weight, equals(80));
    });

    test('matches — valid SVG document matches', () {
      const xmlDoc = '''<?xml version="1.0"?>
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"/>''';
      final bytes = Uint8List.fromList(utf8.encode(xmlDoc));
      expect(svg.matches(bytes), isTrue);
    });

    test('matches — wrong namespace returns false', () {
      const xmlDoc = '''<?xml version="1.0"?>
<svg xmlns="http://example.com/other" width="100"/>''';
      final bytes = Uint8List.fromList(utf8.encode(xmlDoc));
      expect(svg.matches(bytes), isFalse);
    });

    test('matches — wrong local name returns false', () {
      const xmlDoc = '''<?xml version="1.0"?>
<html xmlns="http://www.w3.org/2000/svg"/>''';
      final bytes = Uint8List.fromList(utf8.encode(xmlDoc));
      expect(svg.matches(bytes), isFalse);
    });

    test('matches — invalid XML returns false', () {
      final bytes = Uint8List.fromList(utf8.encode('not xml at all'));
      expect(svg.matches(bytes), isFalse);
    });

    test('matches — empty bytes returns false', () {
      expect(svg.matches(Uint8List(0)), isFalse);
    });

    test('toString returns JSON', () {
      final s = svg.toString();
      final map = jsonDecode(s) as Map<String, dynamic>;
      expect(map['namespaceURI'], equals('http://www.w3.org/2000/svg'));
      expect(map['localName'], equals('svg'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // GenericIcon
  // ──────────────────────────────────────────────────────────────────────────

  group('GenericIcon', () {
    test('tryParse returns correct value for known icon name', () {
      expect(GenericIcon.tryParse('folder'), equals(GenericIcon.folder));
      expect(
        GenericIcon.tryParse('text-x-generic'),
        equals(GenericIcon.textXGeneric),
      );
      expect(
        GenericIcon.tryParse('image-x-generic'),
        equals(GenericIcon.imageXGeneric),
      );
    });

    test('tryParse returns null for unknown icon name', () {
      expect(GenericIcon.tryParse('unknown-icon'), isNull);
      expect(GenericIcon.tryParse(''), isNull);
    });

    test('toString returns the FreeDesktop icon string', () {
      expect(GenericIcon.folder.toString(), equals('folder'));
      expect(GenericIcon.textHtml.toString(), equals('text-html'));
      expect(
        GenericIcon.xOfficeDocument.toString(),
        equals('x-office-document'),
      );
    });

    test('all enum values round-trip through tryParse', () {
      for (final icon in GenericIcon.values) {
        final parsed = GenericIcon.tryParse(icon.value);
        expect(parsed, equals(icon), reason: 'failed for ${icon.value}');
      }
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Glob
  // ──────────────────────────────────────────────────────────────────────────

  group('Glob', () {
    test('matches extension glob case-insensitively by default', () {
      const g = Glob(pattern: '*.txt', weight: 50, caseSensitive: false);
      expect(g.matches('README.txt'), isTrue);
      expect(g.matches('README.TXT'), isTrue);
      expect(g.matches('README.md'), isFalse);
    });

    test('case-sensitive glob rejects wrong case', () {
      const g = Glob(pattern: '*.TXT', weight: 50, caseSensitive: true);
      expect(g.matches('readme.TXT'), isTrue);
      expect(g.matches('readme.txt'), isFalse);
    });

    test('caller override caseSensitive=true on insensitive glob', () {
      const g = Glob(pattern: '*.txt', weight: 50, caseSensitive: false);
      // When the caller requests case-sensitive matching, the stricter rule wins.
      expect(g.matches('readme.TXT', caseSensitive: true), isFalse);
      expect(g.matches('readme.txt', caseSensitive: true), isTrue);
    });

    test('equality — same fields are equal', () {
      const a = Glob(pattern: '*.png', weight: 70, caseSensitive: true);
      const b = Glob(pattern: '*.png', weight: 70, caseSensitive: true);
      expect(a, equals(b));
    });

    test('equality — different weight is not equal', () {
      const a = Glob(pattern: '*.png', weight: 50, caseSensitive: true);
      const b = Glob(pattern: '*.png', weight: 70, caseSensitive: true);
      expect(a, isNot(equals(b)));
    });

    test('hashCode is consistent with equality', () {
      const a = Glob(pattern: '*.dart', weight: 50, caseSensitive: false);
      const b = Glob(pattern: '*.dart', weight: 50, caseSensitive: false);
      expect(a.hashCode, equals(b.hashCode));
    });

    test('second match uses cache without error', () {
      const g = Glob(pattern: '*.json', weight: 50, caseSensitive: false);
      expect(g.matches('data.json'), isTrue);
      // Second call exercises the cached path.
      expect(g.matches('data.json'), isTrue);
      expect(g.matches('data.xml'), isFalse);
    });

    test('toString returns JSON with pattern, weight, caseSensitive', () {
      const g = Glob(pattern: '*.html', weight: 60, caseSensitive: false);
      final map = jsonDecode(g.toString()) as Map<String, dynamic>;
      expect(map['pattern'], equals('*.html'));
      expect(map['weight'], equals(60));
      expect(map['caseSensitive'], isFalse);
    });

    test('wildcard glob matches any filename', () {
      const g = Glob(pattern: '*', weight: 10, caseSensitive: false);
      expect(g.matches('anything.xyz'), isTrue);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // MatchType
  // ──────────────────────────────────────────────────────────────────────────

  group('MatchType', () {
    test('tryParse returns correct type for known strings', () {
      expect(MatchType.tryParse('string'), equals(MatchType.string));
      expect(MatchType.tryParse('big16'), equals(MatchType.big16));
      expect(MatchType.tryParse('little32'), equals(MatchType.little32));
      expect(MatchType.tryParse('byte'), equals(MatchType.byte));
    });

    test('tryParse returns null for unknown strings', () {
      expect(MatchType.tryParse('unknown'), isNull);
      expect(MatchType.tryParse(''), isNull);
    });

    test('all values round-trip through tryParse', () {
      for (final t in MatchType.values) {
        expect(MatchType.tryParse(t.value), equals(t));
      }
    });

    test('toString returns the value string', () {
      expect(MatchType.string.toString(), equals('string'));
      expect(MatchType.big32.toString(), equals('big32'));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Magic / Match — string type
  // ──────────────────────────────────────────────────────────────────────────

  group('Match — string type', () {
    test('matches bytes at offset 0', () {
      final m = Match(offset: '0', type: MatchType.string, value: 'PK');
      final bytes = [0x50, 0x4B, 0x03, 0x04]; // ZIP magic
      expect(m.matches(bytes), isTrue);
    });

    test('does not match wrong bytes', () {
      final m = Match(offset: '0', type: MatchType.string, value: 'PK');
      expect(m.matches([0x00, 0x01, 0x02]), isFalse);
    });

    test('offset range — matches at any position in range', () {
      // offset "0:2" means try positions 0, 1, 2.
      final m = Match(offset: '0:2', type: MatchType.string, value: 'AB');
      expect(m.matches([0x00, 0x41, 0x42, 0x00]), isTrue); // match at pos 1
      expect(m.matches([0x41, 0x42, 0x00, 0x00]), isTrue); // match at pos 0
    });

    test('returns false when data too short', () {
      final m = Match(offset: '0', type: MatchType.string, value: 'PK');
      expect(m.matches([0x50]), isFalse);
    });

    test('returns false for empty bytes', () {
      final m = Match(offset: '0', type: MatchType.string, value: 'PK');
      expect(m.matches([]), isFalse);
    });
  });

  group('Match — byte type', () {
    test('matches single byte', () {
      final m = Match(offset: '0', type: MatchType.byte, value: '0xFF');
      expect(m.matches([0xFF, 0x00]), isTrue);
    });

    test('does not match different byte', () {
      final m = Match(offset: '0', type: MatchType.byte, value: '0xFF');
      expect(m.matches([0xFE, 0x00]), isFalse);
    });
  });

  group('Match — big16 type', () {
    test('matches big-endian 16-bit value', () {
      // 0xFFFE in big-endian is bytes [0xFF, 0xFE].
      final m = Match(offset: '0', type: MatchType.big16, value: '0xFFFE');
      expect(m.matches([0xFF, 0xFE, 0x00]), isTrue);
    });

    test('does not match little-endian layout', () {
      final m = Match(offset: '0', type: MatchType.big16, value: '0xFFFE');
      expect(m.matches([0xFE, 0xFF, 0x00]), isFalse);
    });
  });

  group('Match — little16 type', () {
    test('matches little-endian 16-bit value', () {
      // 0x4D42 ("BM") in little-endian is bytes [0x42, 0x4D].
      final m = Match(offset: '0', type: MatchType.little16, value: '0x4D42');
      expect(m.matches([0x42, 0x4D, 0x00]), isTrue);
    });
  });

  group('Match — big32 type', () {
    test('matches big-endian 32-bit value', () {
      // PNG magic: 0x89504E47 in big-endian.
      final m = Match(offset: '0', type: MatchType.big32, value: '0x89504E47');
      expect(m.matches([0x89, 0x50, 0x4E, 0x47, 0x00]), isTrue);
    });
  });

  group('Match — little32 type', () {
    test('matches little-endian 32-bit value', () {
      // 0x04034B50 in little-endian is [0x50, 0x4B, 0x03, 0x04].
      final m = Match(
        offset: '0',
        type: MatchType.little32,
        value: '0x04034B50',
      );
      expect(m.matches([0x50, 0x4B, 0x03, 0x04]), isTrue);
    });
  });

  group('Match — mask', () {
    test('mask is applied before comparison', () {
      // Pattern 0xFE with mask 0xFE: any byte with top 7 bits set matches.
      final m = Match(
        offset: '0',
        type: MatchType.byte,
        value: '0xFE',
        mask: '0xFE',
      );
      expect(m.matches([0xFF]), isTrue); // 0xFF & 0xFE = 0xFE ✓
      expect(m.matches([0xFE]), isTrue); // 0xFE & 0xFE = 0xFE ✓
      expect(m.matches([0x01]), isFalse); // 0x01 & 0xFE = 0x00 ≠ 0xFE
    });
  });

  group('Match — subMatches', () {
    test('parent match + passing sub-match returns true', () {
      final sub = Match(offset: '2', type: MatchType.byte, value: '0x03');
      final parent = Match(
        offset: '0',
        type: MatchType.string,
        value: 'PK',
        subMatches: [sub],
      );
      // bytes: PK at 0 ✓, 0x03 at 2 ✓
      expect(parent.matches([0x50, 0x4B, 0x03, 0x04]), isTrue);
    });

    test('parent match + failing sub-match returns false', () {
      final sub = Match(offset: '2', type: MatchType.byte, value: '0xFF');
      final parent = Match(
        offset: '0',
        type: MatchType.string,
        value: 'PK',
        subMatches: [sub],
      );
      // bytes: PK at 0 ✓, but 0x03 ≠ 0xFF at 2 ✗
      expect(parent.matches([0x50, 0x4B, 0x03, 0x04]), isFalse);
    });

    test('OR semantics — any passing sub-match is sufficient', () {
      final sub1 = Match(offset: '2', type: MatchType.byte, value: '0xFF');
      final sub2 = Match(offset: '2', type: MatchType.byte, value: '0x03');
      final parent = Match(
        offset: '0',
        type: MatchType.string,
        value: 'PK',
        subMatches: [sub1, sub2],
      );
      expect(parent.matches([0x50, 0x4B, 0x03, 0x04]), isTrue);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Magic container
  // ──────────────────────────────────────────────────────────────────────────

  group('Magic', () {
    test('match returns priority set when a Match succeeds', () {
      final magic = Magic(
        matches: [Match(offset: '0', type: MatchType.string, value: 'PK')],
        priority: 80,
      );
      final result = magic.match([0x50, 0x4B, 0x03, 0x04]);
      expect(result, contains(80));
    });

    test('match returns empty set when no Match succeeds', () {
      final magic = Magic(
        matches: [Match(offset: '0', type: MatchType.string, value: 'XX')],
        priority: 80,
      );
      expect(magic.match([0x50, 0x4B, 0x03, 0x04]), isEmpty);
    });

    test('equality — same fields are equal', () {
      final a = Magic(
        matches: [Match(offset: '0', type: MatchType.byte, value: '0xFF')],
        priority: 50,
      );
      final b = Magic(
        matches: [Match(offset: '0', type: MatchType.byte, value: '0xFF')],
        priority: 50,
      );
      expect(a, equals(b));
    });

    test('hashCode consistent with equality', () {
      final a = Magic(
        matches: [Match(offset: '0', type: MatchType.byte, value: '0xAB')],
        priority: 50,
      );
      final b = Magic(
        matches: [Match(offset: '0', type: MatchType.byte, value: '0xAB')],
        priority: 50,
      );
      expect(a.hashCode, equals(b.hashCode));
    });

    test('matches list is unmodifiable', () {
      final magic = Magic(
        matches: [Match(offset: '0', type: MatchType.byte, value: '0x00')],
      );
      expect(
        () => magic.matches.add(
          Match(offset: '0', type: MatchType.byte, value: '0x01'),
        ),
        throwsUnsupportedError,
      );
    });

    test('toString returns valid JSON', () {
      final magic = Magic(
        matches: [Match(offset: '0', type: MatchType.string, value: 'PK')],
        priority: 60,
      );
      final map = jsonDecode(magic.toString()) as Map<String, dynamic>;
      expect(map['priority'], equals(60));
      expect(map['match'], isA<List>());
    });
  });
}
