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

/// Unit tests for [dbScopedSecretKey]/[isSecretKeyForDb] — the per-database
/// scope hash that keeps `kmdb credentials prune` from ever touching another
/// database's secret in the globally-shared profile secret store. The
/// boundary-safety and injectivity cases below are the ones a plain
/// encoded-path prefix got wrong (QA finding, 2026-08-10).
library;

import 'dart:io' as io;

import 'package:kmdb_cli/src/config/secret_store/secret_key.dart';
import 'package:test/test.dart';

void main() {
  group('dbScopedSecretKey / isSecretKeyForDb', () {
    test('a scoped key is recognised as belonging to its own database', () {
      final key = dbScopedSecretKey('/data/work', 'google_credentials.json');
      expect(isSecretKeyForDb(key, '/data/work'), isTrue);
    });

    test('the scope prefix is a fixed-length lowercase hex digest', () {
      final key = dbScopedSecretKey('/data/work', 'google_credentials.json');
      expect(key, matches(RegExp(r'^[0-9a-f]{32}-google_credentials\.json$')));
    });

    test('distinct databases produce distinct scopes', () {
      final a = dbScopedSecretKey('/data/work', 'c.json');
      final b = dbScopedSecretKey('/data/play', 'c.json');
      expect(a, isNot(equals(b)));
      expect(isSecretKeyForDb(a, '/data/play'), isFalse);
      expect(isSecretKeyForDb(b, '/data/work'), isFalse);
    });

    // Regression: the former encoded-path + '--' delimiter mis-scoped a sibling
    // whose path was a '--'-suffixed extension of another database's path — a
    // key for `/data/work--archive` had `/data/work` (encoded) as a prefix, so
    // `/data/work`'s prune would delete it as orphaned. The hash scope is
    // fixed-length and '-'-free, so the boundary is unambiguous.
    test("a sibling path that extends another with '--' is not mis-scoped", () {
      final sibling = dbScopedSecretKey(
        '/data/work--archive',
        'google_credentials.json',
      );
      expect(isSecretKeyForDb(sibling, '/data/work'), isFalse);
      expect(isSecretKeyForDb(sibling, '/data/work--archive'), isTrue);
    });

    test('a name containing the delimiter or "--" does not break matching', () {
      final key = dbScopedSecretKey(
        '/data/work',
        'weird--name-with-dashes.json',
      );
      expect(isSecretKeyForDb(key, '/data/work'), isTrue);
      // And it is not attributed to any other database.
      expect(isSecretKeyForDb(key, '/data/work2'), isFalse);
    });

    test('canonicalisation makes redundant path segments equivalent', () {
      final direct = dbScopedSecretKey('/data/work', 'c.json');
      final indirect = dbScopedSecretKey('/data/./sub/../work', 'c.json');
      expect(direct, equals(indirect));
    });

    // POSIX-only: ':' is a legal filename character there, and the former
    // separators-and-':'-to-'_' encoding collapsed `a:b` and `a/b` to the same
    // prefix. The SHA-256 scope is injective, so these stay distinct.
    test(
      'paths differing only by separator vs colon stay distinct (POSIX)',
      () {
        final slash = dbScopedSecretKey('/data/a/b', 'c.json');
        final colon = dbScopedSecretKey('/data/a:b', 'c.json');
        expect(slash, isNot(equals(colon)));
      },
      skip: io.Platform.isWindows
          ? 'colon is not a path char on Windows'
          : false,
    );
  });
}
