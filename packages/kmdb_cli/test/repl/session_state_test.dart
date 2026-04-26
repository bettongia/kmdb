// Copyright 2026 The KMDB Authors.
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

import 'package:kmdb_cli/src/output/output_mode.dart';
import 'package:kmdb_cli/src/repl/session_state.dart';
import 'package:test/test.dart';

void main() {
  group('SessionState defaults', () {
    test('has expected initial values', () {
      final s = SessionState();
      expect(s.outputMode, OutputMode.json);
      expect(s.activeCollection, isNull);
      expect(s.compact, isFalse);
      expect(s.colorMode, ColorMode.auto);
      expect(s.headers, isTrue);
      expect(s.nullValue, '');
      expect(s.defaultLimit, 0);
      expect(s.echo, isFalse);
      expect(s.bail, isFalse);
      expect(s.timer, isFalse);
      expect(s.outputSink, isNull);
      expect(s.onceSink, isNull);
    });
  });

  group('describe', () {
    test('includes all settings', () {
      final s = SessionState()
        ..outputMode = OutputMode.table
        ..activeCollection = 'notes'
        ..compact = true
        ..colorMode = ColorMode.off
        ..headers = false
        ..nullValue = 'NULL'
        ..defaultLimit = 10
        ..echo = true
        ..bail = true
        ..timer = true;

      final desc = s.describe();
      expect(desc, contains('table'));
      expect(desc, contains('notes'));
      expect(desc, contains('on')); // compact on
      expect(desc, contains('off')); // color off
      expect(desc, contains('NULL'));
      expect(desc, contains('10'));
    });

    test('shows (none) when no active collection', () {
      expect(SessionState().describe(), contains('(none)'));
    });

    test('shows none for limit 0', () {
      expect(SessionState().describe(), contains('none'));
    });
  });

  group('colorEnabled', () {
    test('on mode always returns true', () {
      final s = SessionState()..colorMode = ColorMode.on;
      expect(s.colorEnabled, isTrue);
    });

    test('off mode always returns false', () {
      final s = SessionState()..colorMode = ColorMode.off;
      expect(s.colorEnabled, isFalse);
    });
  });
}
