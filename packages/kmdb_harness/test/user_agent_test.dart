// Copyright 2026 The Authors
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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_harness/kmdb_harness.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

HarnessConfig _config({
  int deviceCount = 3,
  int collectionCount = 5,
  KeyPoolRatios? keyPoolRatios,
  DocSizeDistribution? docSizeDistribution,
}) => HarnessConfig(
  syncAdapter: MemorySyncAdapter(),
  deviceCount: deviceCount,
  collectionCount: collectionCount,
  velocityPreset: VelocityPreset.one,
  keyPoolRatios: keyPoolRatios ?? const KeyPoolRatios.defaults(),
  docSizeDistribution:
      docSizeDistribution ?? const DocSizeDistribution.defaults(),
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('UserAgent — PRNG reproducibility', () {
    test('same seed produces same action type sequence', () {
      final config = _config();

      final agentA = UserAgent(config: config, seed: 42);
      final agentB = UserAgent(config: config, seed: 42);

      // Generate 50 action types from a stub ready device by inspecting
      // the preSeedActions (which are deterministic put sequences).
      final actionsA = agentA.preSeedActions(0, 10);
      final actionsB = agentB.preSeedActions(0, 10);

      expect(actionsA.length, equals(actionsB.length));
      for (var i = 0; i < actionsA.length; i++) {
        expect(actionsA[i].type, equals(actionsB[i].type));
        expect(actionsA[i].key, equals(actionsB[i].key));
      }
    });

    test('different seeds produce different document content', () {
      // Keys are drawn from a deterministic pool (not PRNG-driven), so they
      // are the same across seeds. Document content IS PRNG-driven and will
      // differ between seeds.
      final config = _config();
      final agentA = UserAgent(config: config, seed: 1);
      final agentB = UserAgent(config: config, seed: 2);

      final titlesA = agentA
          .preSeedActions(0, 20)
          .map((a) => a.document!['title'] as String)
          .toList();
      final titlesB = agentB
          .preSeedActions(0, 20)
          .map((a) => a.document!['title'] as String)
          .toList();

      // At least one title should differ between seeds.
      expect(titlesA, isNot(equals(titlesB)));
    });

    test('effectiveSeed matches the supplied seed', () {
      final agent = UserAgent(config: _config(), seed: 99999);
      expect(agent.effectiveSeed, equals(99999));
    });

    test('fuzz mode derives seed from clock (non-null)', () {
      final agent = UserAgent(config: _config());
      expect(agent.effectiveSeed, isNonZero);
    });
  });

  group('UserAgent — createDb and createCollection actions', () {
    test('createDb action targets the correct device', () {
      final agent = UserAgent(config: _config(deviceCount: 3), seed: 1);
      final action = agent.createDb(2);
      expect(action.deviceId, equals(2));
      expect(action.type, equals(ActionType.createDb));
    });

    test('createCollection action uses col_N naming', () {
      final agent = UserAgent(config: _config(), seed: 1);
      final action = agent.createCollection(0, 3);
      expect(action.type, equals(ActionType.createCollection));
      expect(action.collectionName, equals('col_3'));
    });
  });

  group('UserAgent — pre-seeding', () {
    test('preSeedActions returns correct count', () {
      final agent = UserAgent(config: _config(collectionCount: 5), seed: 42);
      final actions = agent.preSeedActions(0, 10);
      expect(actions, hasLength(10));
    });

    test('all preSeedActions are puts', () {
      final agent = UserAgent(config: _config(), seed: 42);
      final actions = agent.preSeedActions(0, 20);
      for (final a in actions) {
        expect(a.type, equals(ActionType.put));
      }
    });

    test('preSeedActions target the given device', () {
      final agent = UserAgent(config: _config(deviceCount: 3), seed: 42);
      final actions = agent.preSeedActions(2, 5);
      for (final a in actions) {
        expect(a.deviceId, equals(2));
      }
    });

    test('preSeedActions produce documents with required fields', () {
      final agent = UserAgent(config: _config(), seed: 42);
      final actions = agent.preSeedActions(0, 5);
      for (final a in actions) {
        final doc = a.document!;
        expect(doc, containsPair('title', isA<String>()));
        expect(doc, containsPair('body', isA<String>()));
        expect(doc, containsPair('count', isA<int>()));
        expect(doc, containsPair('active', isA<bool>()));
        expect(doc, containsPair('tags', isA<List>()));
      }
    });
  });

  group('UserAgent — document generation size tiers', () {
    test('small tier body is short', () {
      // Force 100% small documents.
      final config = _config(
        docSizeDistribution: const DocSizeDistribution(
          small: 100,
          medium: 0,
          large: 0,
        ),
      );
      final agent = UserAgent(config: config, seed: 1);
      final actions = agent.preSeedActions(0, 20);
      for (final a in actions) {
        final body = a.document!['body'] as String;
        // Small bodies should be well under 1 KB.
        expect(body.length, lessThan(500));
      }
    });

    test('large tier body is long', () {
      final config = _config(
        docSizeDistribution: const DocSizeDistribution(
          small: 0,
          medium: 0,
          large: 100,
        ),
      );
      final agent = UserAgent(config: config, seed: 1);
      final actions = agent.preSeedActions(0, 5);
      for (final a in actions) {
        final body = a.document!['body'] as String;
        // Large bodies should be well over 100 KB.
        expect(body.length, greaterThan(100000));
      }
    });

    test('all three tiers are reachable with default distribution', () {
      // With default 60/30/10 distribution and enough samples, all tiers
      // should appear.
      final config = _config(
        collectionCount: 100,
        docSizeDistribution: const DocSizeDistribution(
          small: 60,
          medium: 30,
          large: 10,
        ),
      );
      final agent = UserAgent(config: config, seed: 7);
      final actions = agent.preSeedActions(0, 100);
      final lengths = actions.map(
        (a) => (a.document!['body'] as String).length,
      );
      final hasSmall = lengths.any((l) => l < 500);
      final hasMedium = lengths.any((l) => l > 1000 && l < 100000);
      final hasLarge = lengths.any((l) => l > 100000);
      expect(hasSmall, isTrue, reason: 'expected small-tier documents');
      expect(hasMedium, isTrue, reason: 'expected medium-tier documents');
      expect(hasLarge, isTrue, reason: 'expected large-tier documents');
    });
  });

  group('UserAgent — key pool distribution', () {
    test('shared keys are non-empty', () {
      final agent = UserAgent(config: _config(deviceCount: 2), seed: 1);
      // Pre-seed actions use shared keys.
      final actions = agent.preSeedActions(0, 10);
      final keys = actions.map((a) => a.key!).toSet();
      expect(keys, isNotEmpty);
    });

    test('same key can appear across different devices (shared pool)', () {
      final config = _config(
        deviceCount: 2,
        collectionCount: 5,
        keyPoolRatios: const KeyPoolRatios(shared: 100, deviceLocal: 0, hot: 0),
      );
      final agent = UserAgent(config: config, seed: 42);
      final actionsD0 = agent.preSeedActions(0, 10);
      final actionsD1 = agent.preSeedActions(1, 10);

      final keysD0 = actionsD0.map((a) => a.key!).toSet();
      final keysD1 = actionsD1.map((a) => a.key!).toSet();

      // With 100% shared keys, both devices draw from the same pool.
      expect(keysD0.intersection(keysD1), isNotEmpty);
    });

    test('action IDs are monotonically increasing', () {
      final agent = UserAgent(config: _config(), seed: 1);
      final actions = [
        agent.createDb(0),
        agent.createCollection(0, 0),
        ...agent.preSeedActions(0, 5),
      ];
      for (var i = 1; i < actions.length; i++) {
        expect(actions[i].id, greaterThan(actions[i - 1].id));
      }
    });
  });
}
