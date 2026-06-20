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

import 'package:flutter_test/flutter_test.dart';
import 'package:kmdb_flutter/kmdb_flutter.dart';
import 'package:kmdb_flutter/src/kmdb_flutter_init.dart';

void main() {
  // Initialize the Flutter test binding before any tests run.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Reset the initialization guard so each test starts from a clean state.
    KmdbFlutter.resetForTesting();
  });

  group('KmdbFlutter.initialize()', () {
    test('does not throw on first call', () {
      // Under flutter_test the native channel is mocked/absent; the important
      // thing is that the call completes without throwing.
      expect(() => KmdbFlutter.initialize(), returnsNormally);
    });

    test('is idempotent — calling twice does not throw', () {
      // This is the primary correctness property: hosts that call initialize()
      // more than once (e.g. in tests or across hot-reloads) must not see an
      // error.
      expect(() {
        KmdbFlutter.initialize();
        KmdbFlutter.initialize();
      }, returnsNormally);
    });

    test('is idempotent — calling three times does not throw', () {
      expect(() {
        KmdbFlutter.initialize();
        KmdbFlutter.initialize();
        KmdbFlutter.initialize();
      }, returnsNormally);
    });

    test('resetForTesting allows re-initialization', () {
      KmdbFlutter.initialize();
      KmdbFlutter.resetForTesting();
      // After reset a fresh initialize() call should succeed.
      expect(() => KmdbFlutter.initialize(), returnsNormally);
    });
  });
}
