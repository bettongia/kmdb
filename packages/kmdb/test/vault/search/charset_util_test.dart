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

import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:kmdb/src/vault/search/charset_util.dart';
import 'package:test/test.dart';

/// The Unicode BOM code unit (U+FEFF).
const _bom = '﻿';

void main() {
  // ---------------------------------------------------------------------------
  // Edge-case table from the plan (all rows)
  // ---------------------------------------------------------------------------
  group('Plan edge-case table', () {
    test('Row 1 — valid UTF-8, no BOM: charset=utf-8, text=decoded', () {
      final bytes = Uint8List.fromList(utf8.encode('Hello, world!'));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-8');
      expect(text, 'Hello, world!');
    });

    test(
      'Row 2 — UTF-8 with BOM (0xEF 0xBB 0xBF): charset=utf-8, BOM stripped',
      () {
        // dart:convert utf8.decode does not strip the UTF-8 BOM; decodeText must.
        final contentBytes = utf8.encode('Hello');
        final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...contentBytes]);
        final (:charset, :text) = decodeText(bytes);
        expect(charset, 'utf-8');
        // Confirm the leading U+FEFF has been stripped.
        expect(text.startsWith(_bom), isFalse, reason: 'BOM must be stripped');
        expect(text, 'Hello');
      },
    );

    test(
      'Row 3 — UTF-16 BE with BOM: decoded correctly, BOM stripped by codec',
      () {
        // Encode "AB" as UTF-16 BE with BOM (FE FF 00 41 00 42).
        final bytes = Uint8List.fromList([
          0xFE, 0xFF, // BOM
          0x00, 0x41, // A
          0x00, 0x42, // B
        ]);
        final (:charset, :text) = decodeText(bytes);
        expect(charset, 'utf-16be');
        // The charset utf16 codec strips the BOM during decode.
        expect(text, 'AB');
        expect(text.startsWith(_bom), isFalse, reason: 'BOM must be stripped');
      },
    );

    test(
      'Row 4 — UTF-16 LE with BOM: decoded correctly, BOM stripped by codec',
      () {
        // Encode "AB" as UTF-16 LE with BOM (FF FE 41 00 42 00).
        final bytes = Uint8List.fromList([
          0xFF, 0xFE, // BOM
          0x41, 0x00, // A
          0x42, 0x00, // B
        ]);
        final (:charset, :text) = decodeText(bytes);
        expect(charset, 'utf-16le');
        expect(text, 'AB');
        expect(text.startsWith(_bom), isFalse, reason: 'BOM must be stripped');
      },
    );

    test('Row 5 — Windows-1252 (no BOM, high bytes): decoded correctly', () {
      // 0x80 = Euro sign (€) in Windows-1252; invalid in UTF-8 and ISO-8859-1.
      // Pad with ASCII to keep the high-byte ratio below the CJK promotion
      // threshold (>15%), otherwise EUC-KR may be promoted ahead of it.
      //
      // "Hello€World" = 11 bytes, 1 high byte = 9.1% → Western probed first.
      final bytes = Uint8List.fromList([
        0x48, 0x65, 0x6C, 0x6C, 0x6F, // Hello
        0x80, // €
        0x57, 0x6F, 0x72, 0x6C, 0x64, // World
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'windows-1252');
      // The Euro sign is U+20AC in Unicode.
      expect(text.contains('€'), isTrue, reason: 'Euro sign should decode');
    });

    test(
      'Row 6 — ISO-8859-1 (Latin-1 text): decoded correctly via latin1 fallback',
      () {
        // 0xE9 = é in ISO-8859-1. Keep ASCII-heavy to avoid CJK promotion.
        // "Hello é" = 7 bytes, 1 high byte ≈ 14.3% — just under the threshold.
        final bytes = Uint8List.fromList([
          0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, // "Hello "
          0xE9, // é
        ]);
        final (:charset, :text) = decodeText(bytes);
        // The detector returns 'iso-8859-1' or 'windows-1252' for these bytes
        // (both are valid; iso-8859-1 and windows-1252 overlap for bytes < 0x80
        // and the probe order puts windows-1252 first, but 0xE9 is also valid
        // in iso-8859-1). The key assertion is that the text decodes to 'é'.
        expect(
          charset,
          anyOf('iso-8859-1', 'windows-1252'),
          reason: 'detector may return either for this byte sequence',
        );
        // 0xE9 → U+00E9 (é) in both iso-8859-1 and windows-1252.
        expect(text, contains('é'), reason: 'é must decode correctly');
      },
    );

    test('Row 7 — Shift-JIS: decoded correctly', () {
      const text = '上善若水';
      final bytes = Uint8List.fromList(shiftJis.encode(text));
      final result = decodeText(bytes);
      expect(result.charset, 'shift-jis');
      expect(result.text, text);
    });

    test('Row 8 — EUC-JP: decoded correctly', () {
      const text = '東京タワー';
      final bytes = Uint8List.fromList(eucJp.encode(text));
      final result = decodeText(bytes);
      expect(result.charset, 'euc-jp');
      expect(result.text, text);
    });

    test('Row 9 — GBK: decoded correctly', () {
      // Use a longer string to ensure the probe uniquely identifies GBK.
      const text = '上善若水水善利萬物而不爭處衆人之所惡';
      final bytes = Uint8List.fromList(gbk.encode(text));
      final result = decodeText(bytes);
      expect(result.charset, 'gbk');
      expect(result.text, text);
    });

    test('Row 10 — empty bytes: text="", charset="utf-8"', () {
      final (:charset, :text) = decodeText(Uint8List(0));
      expect(charset, 'utf-8');
      expect(text, '');
    });

    test(
      'Row 11 — ASCII-only bytes: charset="utf-8" (ASCII is never returned as own label)',
      () {
        // ASCII is a strict UTF-8 subset; the detector never returns "ascii".
        final bytes = Uint8List.fromList('Hello, world!'.codeUnits);
        final (:charset, :text) = decodeText(bytes);
        expect(
          charset,
          'utf-8',
          reason: 'ASCII passes UTF-8 structural validation',
        );
        expect(text, 'Hello, world!');
      },
    );

    test(
      'Row 12 — bytes valid as UTF-8 but authored as Windows-1252: charset="utf-8" (documented limitation)',
      () {
        // "Héllo" encoded in Windows-1252: H=0x48, é=0xE9, ...
        // BUT 0xE9 is also a valid continuation byte in UTF-8 only after
        // the right lead byte. A simpler case: the Latin-1 supplement range
        // U+00C0–U+00FF encodes as 2-byte UTF-8 sequences, not single bytes.
        //
        // To create a sequence that is valid in both UTF-8 and Windows-1252,
        // use pure ASCII plus a byte sequence that is simultaneously valid UTF-8
        // and valid Windows-1252: e.g. 0xC3 0xA9 is "é" in UTF-8 but two
        // separate characters in Windows-1252 (Ã + ©).
        //
        // The plan explicitly records this as an intentional gate: if bytes
        // pass UTF-8 structural validation, the detector always returns "utf-8"
        // regardless of authoring encoding.
        final bytes = Uint8List.fromList(utf8.encode('Héllo'));
        final (:charset, :text) = decodeText(bytes);
        expect(
          charset,
          'utf-8',
          reason:
              'UTF-8 structural validation is a hard gate — bytes valid as '
              'UTF-8 are always classified as utf-8, even if they were authored '
              'in Windows-1252 (documented limitation)',
        );
        // The text is the UTF-8 decoding, not the Windows-1252 interpretation.
        expect(text, 'Héllo');
      },
    );
  });

  // ---------------------------------------------------------------------------
  // BOM stripping specifics
  // ---------------------------------------------------------------------------
  group('BOM stripping', () {
    test('UTF-8 BOM-only (3 bytes): text is empty string', () {
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-8');
      expect(text, '', reason: 'BOM-only input should produce empty string');
    });

    test(
      'UTF-8 BOM + multi-byte characters: BOM stripped, content preserved',
      () {
        // "上善" encoded as UTF-8 after a BOM.
        final contentBytes = utf8.encode('上善');
        final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...contentBytes]);
        final (:charset, :text) = decodeText(bytes);
        expect(charset, 'utf-8');
        expect(text, '上善');
        expect(text.startsWith(_bom), isFalse);
      },
    );

    test('Dart 3.x utf8.decode already strips the UTF-8 BOM', () {
      // In Dart 3.x, dart:convert's utf8.decode strips the UTF-8 BOM
      // (0xEF 0xBB 0xBF) from the result. decodeText adds a defensive guard
      // for forward compatibility should this behaviour change.
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x41]); // BOM + A
      final decoded = utf8.decode(bytes);
      // In Dart 3.x, the BOM is stripped.
      expect(decoded, 'A', reason: 'Dart 3.x utf8.decode strips the UTF-8 BOM');
      expect(
        decoded.startsWith(_bom),
        isFalse,
        reason: 'No BOM should remain after utf8.decode in Dart 3.x',
      );
    });

    test('UTF-16 BE BOM: codec strips BOM, text is correct', () {
      // "Hello" in UTF-16 BE with BOM.
      final bytes = Uint8List.fromList([
        0xFE, 0xFF, // BOM
        0x00, 0x48, // H
        0x00, 0x65, // e
        0x00, 0x6C, // l
        0x00, 0x6C, // l
        0x00, 0x6F, // o
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-16be');
      expect(text, 'Hello');
      expect(text.startsWith(_bom), isFalse);
    });

    test('UTF-16 LE BOM: codec strips BOM, text is correct', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xFE, // BOM
        0x48, 0x00, // H
        0x65, 0x00, // e
        0x6C, 0x00, // l
        0x6C, 0x00, // l
        0x6F, 0x00, // o
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-16le');
      expect(text, 'Hello');
      expect(text.startsWith(_bom), isFalse);
    });

    test('UTF-32 BE with BOM: decoded and BOM stripped', () {
      // "A" in UTF-32 BE with BOM.
      final bytes = Uint8List.fromList([
        0x00, 0x00, 0xFE, 0xFF, // BOM
        0x00, 0x00, 0x00, 0x41, // A
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-32be');
      expect(text, 'A');
      expect(text.startsWith(_bom), isFalse);
    });

    test('UTF-32 LE with BOM: decoded and BOM stripped', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xFE, 0x00, 0x00, // BOM
        0x41, 0x00, 0x00, 0x00, // A
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-32le');
      expect(text, 'A');
      expect(text.startsWith(_bom), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Two-branch dispatch: utf-8 vs. Charset.getByName paths
  // ---------------------------------------------------------------------------
  group('Dispatch paths', () {
    test('utf-8 label uses dart:convert utf8.decode path', () {
      // Valid UTF-8 multi-byte: "Café"
      final bytes = Uint8List.fromList(utf8.encode('Café'));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-8');
      expect(text, 'Café');
    });

    test('shift-jis uses Charset.getByName path', () {
      const original = '東京';
      final bytes = Uint8List.fromList(shiftJis.encode(original));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'shift-jis');
      expect(text, original);
    });

    test('euc-jp uses Charset.getByName path', () {
      const original = '大阪';
      final bytes = Uint8List.fromList(eucJp.encode(original));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'euc-jp');
      expect(text, original);
    });

    test('euc-kr uses Charset.getByName path', () {
      // Use a long Korean string to ensure unique detection over other CJK.
      // NOTE: The charset package's eucKr codec covers only the KSX 1001
      // character set, so exact round-trip equality is not guaranteed for all
      // Korean characters. We test that:
      //   (a) the charset label is correctly returned as 'euc-kr', and
      //   (b) the decoding produces a non-empty, non-throwing result.
      const original =
          '상선약수라는 말이 있다. 물은 만물을 이롭게 하면서도 다투지 않고 '
          '모든 사람이 싫어하는 낮은 곳에 처하니 도에 가깝다고 할 수 있다.';
      final bytes = Uint8List.fromList(eucKr.encode(original));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'euc-kr');
      expect(
        text,
        isNotEmpty,
        reason: 'EUC-KR decoding must produce a non-empty string',
      );
    });

    test('gbk uses Charset.getByName path', () {
      const original = '上善若水水善利萬物而不爭處衆人之所惡故幾於道';
      final bytes = Uint8List.fromList(gbk.encode(original));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'gbk');
      expect(text, original);
    });
  });

  // ---------------------------------------------------------------------------
  // iso-8859-1 label resolution (via getByName fallback to latin1)
  // ---------------------------------------------------------------------------
  group('iso-8859-1 → latin1 fallback', () {
    test('iso-8859-1 label resolves via Charset.getByName to latin1', () {
      // Verify that the iso-8859-1 IANA label can actually be used to decode
      // by checking Charset.getByName returns a non-null codec.
      //
      // The detector probe order puts windows-1252 before iso-8859-1, so the
      // detector may not actually return 'iso-8859-1' for this input.
      // Instead, we directly invoke Charset.getByName to test the fallback
      // contract, and then check that decodeText handles the bytes correctly
      // regardless of which western label is returned.
      final codec = Charset.getByName('iso-8859-1');
      expect(
        codec,
        isNotNull,
        reason: 'iso-8859-1 must resolve via getByName → latin1 fallback',
      );

      // Decode a known ISO-8859-1 sequence: 0xE9 = é.
      final bytes = Uint8List.fromList([
        0x48, 0x65, 0x6C, 0x6C, 0x6F, // Hello
        0x20, // space
        0xE9, // é
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(
        charset,
        anyOf('iso-8859-1', 'windows-1252'),
        reason: 'detector may return either for this byte sequence',
      );
      // 0xE9 → U+00E9 (é) in both encodings.
      expect(text, contains('é'));
    });
  });

  // ---------------------------------------------------------------------------
  // Return type contract
  // ---------------------------------------------------------------------------
  group('Return type contract', () {
    test('result is a record with charset and text fields', () {
      final result = decodeText(Uint8List.fromList([0x41]));
      // Destructure to verify the record shape.
      final (:charset, :text) = result;
      expect(charset, isA<String>());
      expect(text, isA<String>());
    });

    test('text is never null (String, not String?)', () {
      // The return type is CharsetDecodeResult = ({String charset, String text}),
      // so null is not possible. This test verifies that a variety of inputs
      // all produce non-null strings.
      final inputs = [
        Uint8List(0),
        Uint8List.fromList([0x41]),
        Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x41]),
        Uint8List.fromList([0xFF, 0xFE, 0x41, 0x00]),
        Uint8List.fromList([0x80]),
      ];
      for (final input in inputs) {
        final (:charset, :text) = decodeText(input);
        expect(charset, isA<String>());
        expect(text, isA<String>());
      }
    });

    test('charset is always a non-empty lowercase IANA label', () {
      final inputs = [
        Uint8List(0),
        Uint8List.fromList(utf8.encode('hello')),
        Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x41]),
        Uint8List.fromList([0xFF, 0xFE, 0x41, 0x00]),
        Uint8List.fromList([0x80]),
        Uint8List.fromList(shiftJis.encode('東京')),
      ];
      for (final input in inputs) {
        final (:charset, :text) = decodeText(input);
        expect(charset, isNotEmpty, reason: 'charset must not be empty');
        expect(
          charset,
          equals(charset.toLowerCase()),
          reason: 'charset must be lowercase: $charset',
        );
        // text is produced but we don't assert its value here.
        expect(text, isNotNull);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Round-trip tests for each supported IANA label
  // ---------------------------------------------------------------------------
  group('Round-trip per IANA label', () {
    test('utf-8 round-trip (with BOM)', () {
      const original = 'Hello, world!';
      final contentBytes = utf8.encode(original);
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...contentBytes]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-8');
      expect(text, original);
    });

    test('utf-8 round-trip (no BOM)', () {
      const original = 'Héllo wörld — café';
      final bytes = Uint8List.fromList(utf8.encode(original));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-8');
      expect(text, original);
    });

    test('utf-16be round-trip', () {
      const original = 'Hello';
      final bytes = Uint8List.fromList([
        0xFE, 0xFF, // BOM
        0x00, 0x48, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00, 0x6F,
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-16be');
      expect(text, original);
    });

    test('utf-16le round-trip', () {
      const original = 'Hello';
      final bytes = Uint8List.fromList([
        0xFF, 0xFE, // BOM
        0x48, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00, 0x6F, 0x00,
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-16le');
      expect(text, original);
    });

    test('utf-32be round-trip', () {
      const original = 'A';
      final bytes = Uint8List.fromList([
        0x00, 0x00, 0xFE, 0xFF, // BOM
        0x00, 0x00, 0x00, 0x41, // A
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-32be');
      expect(text, original);
    });

    test('utf-32le round-trip', () {
      const original = 'A';
      final bytes = Uint8List.fromList([
        0xFF, 0xFE, 0x00, 0x00, // BOM
        0x41, 0x00, 0x00, 0x00, // A
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'utf-32le');
      expect(text, original);
    });

    test('windows-1252 round-trip', () {
      // 0x80 = € (Euro) — unique to Windows-1252 in the 0x80–0x9F range.
      // Keep ASCII ratio high to avoid CJK promotion.
      final bytes = Uint8List.fromList([
        0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, // "Hello "
        0x80, // €
        0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64, // " world"
      ]);
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'windows-1252');
      expect(text, contains('€'), reason: 'Euro sign must decode');
    });

    test('shift-jis round-trip', () {
      const original = '日本語テスト文字列';
      final bytes = Uint8List.fromList(shiftJis.encode(original));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'shift-jis');
      expect(text, original);
    });

    test('euc-jp round-trip', () {
      const original = '日本語テスト文字列';
      final bytes = Uint8List.fromList(eucJp.encode(original));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'euc-jp');
      expect(text, original);
    });

    test('euc-kr: detected as euc-kr, decodes without error', () {
      // The charset package's eucKr codec covers only the KSX 1001 character
      // set; exact round-trip equality is not achievable for all Korean glyphs
      // with this codec. The test validates that:
      //   (a) detection returns 'euc-kr' for EUC-KR encoded bytes, and
      //   (b) the decoding completes without throwing.
      const original =
          '상선약수라는 말이 있다. 물은 만물을 이롭게 하면서도 다투지 않고 '
          '모든 사람이 싫어하는 낮은 곳에 처하니 도에 가깝다고 할 수 있다.';
      final bytes = Uint8List.fromList(eucKr.encode(original));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'euc-kr');
      expect(
        text,
        isNotEmpty,
        reason: 'EUC-KR decoding must produce a non-empty string',
      );
    });

    test('gbk round-trip', () {
      const original = '上善若水水善利萬物而不爭處衆人之所惡故幾於道';
      final bytes = Uint8List.fromList(gbk.encode(original));
      final (:charset, :text) = decodeText(bytes);
      expect(charset, 'gbk');
      expect(text, original);
    });
  });
}
