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

import 'package:kmdb/src/versioning/version_config.dart';
import 'package:test/test.dart';

void main() {
  group('VersionConfig', () {
    // ── Defaults ──────────────────────────────────────────────────────────────

    test('default config has maxVersions: 4 and retentionDays: 90', () {
      const cfg = VersionConfig.defaults;
      expect(cfg.maxVersions, equals(4));
      expect(cfg.retentionDays, equals(90));
      expect(cfg.isDisabled, isFalse);
    });

    test('disabled config has isDisabled true', () {
      const cfg = VersionConfig.disabled;
      expect(cfg.isDisabled, isTrue);
      expect(cfg.maxVersions, equals(0));
      expect(cfg.retentionDays, isNull);
    });

    // ── isDisabled semantics ─────────────────────────────────────────────────

    test('maxVersions=0 + no retentionDays is disabled', () {
      const cfg = VersionConfig(maxVersions: 0, retentionDays: null);
      expect(cfg.isDisabled, isTrue);
    });

    test('maxVersions=0 + retentionDays set is NOT disabled (window only)', () {
      const cfg = VersionConfig(maxVersions: 0, retentionDays: 30);
      // maxVersions=0 means keep-0 by count, but retentionDays=30 means
      // retain by window — versioning is active (window-only mode).
      expect(cfg.isDisabled, isFalse);
    });

    test('null maxVersions is NOT disabled (unlimited count)', () {
      const cfg = VersionConfig(maxVersions: null, retentionDays: 90);
      expect(cfg.isDisabled, isFalse);
    });

    // ── Serialisation ─────────────────────────────────────────────────────────

    test('toMap / fromMap round-trip for defaults', () {
      const cfg = VersionConfig.defaults;
      final map = cfg.toMap();
      final decoded = VersionConfig.fromMap(map);
      expect(decoded, equals(cfg));
    });

    test('toMap / fromMap round-trip for disabled', () {
      const cfg = VersionConfig.disabled;
      final map = cfg.toMap();
      // maxVersions=0, retentionDays=null — map should have only maxVersions.
      expect(map.containsKey('maxVersions'), isTrue);
      expect(map.containsKey('retentionDays'), isFalse);
      final decoded = VersionConfig.fromMap(map);
      expect(decoded, equals(cfg));
    });

    test('fromMap with empty map yields null constraints', () {
      // An empty map has no keys — both fields decode to null (no constraint).
      // Callers that want defaults for a missing config use VersionConfig.defaults
      // explicitly (e.g. VersionConfigStore.get when no entry is persisted).
      final decoded = VersionConfig.fromMap({});
      expect(decoded.maxVersions, isNull);
      expect(decoded.retentionDays, isNull);
    });

    test('fromMap with extra keys is forward-compatible (ignores extras)', () {
      final map = {
        'maxVersions': 10,
        'retentionDays': 60,
        'futureField': 'ignored',
      };
      final decoded = VersionConfig.fromMap(map);
      expect(decoded.maxVersions, equals(10));
      expect(decoded.retentionDays, equals(60));
    });

    // ── Equality ─────────────────────────────────────────────────────────────

    test('equality and hashCode are value-based', () {
      const a = VersionConfig(maxVersions: 5, retentionDays: 30);
      const b = VersionConfig(maxVersions: 5, retentionDays: 30);
      const c = VersionConfig(maxVersions: 5, retentionDays: 60);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
