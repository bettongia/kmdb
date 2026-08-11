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

import 'package:kmdb/src/sync/auth/sync_auth_exception.dart';
import 'package:test/test.dart';

void main() {
  group('SyncAuthException', () {
    test('toString includes the message', () {
      final e = SyncAuthException('something went wrong');
      expect(e.toString(), equals('SyncAuthException: something went wrong'));
    });

    test('path defaults to null (e.g. the R-4 no-key-enrolled case)', () {
      final e = SyncAuthException('no key enrolled');
      expect(e.path, isNull);
    });

    test('path is preserved when supplied', () {
      final e = SyncAuthException('bad MAC', path: 'sstables/x.sst');
      expect(e.path, equals('sstables/x.sst'));
    });

    test('is an Exception', () {
      expect(SyncAuthException('x'), isA<Exception>());
    });
  });
}
