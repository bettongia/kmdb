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

import 'package:test/test.dart';

import 'package:kmdb/src/engine/compaction/reclamation_policy.dart';

void main() {
  group('ReclamationPolicyRegistry.resolve', () {
    test('default registry collapses ordinary user namespaces', () {
      final registry = ReclamationPolicyRegistry();
      expect(registry.resolve('users').collapseVersions, isTrue);
      expect(registry.resolve('orders').collapseVersions, isTrue);
      expect(registry.resolve('').collapseVersions, isTrue);
    });

    test('default registry collapses KMDB current-state system namespaces', () {
      // Cache, secondary indexes, search, sync, meta: all current-state only,
      // all expected to collapse.
      final registry = ReclamationPolicyRegistry();
      for (final ns in [
        r'$meta',
        r'$cache',
        r'$index:users:email',
        r'$fts:users:body',
        r'$vec:users:embedding',
        r'$sync',
      ]) {
        expect(
          registry.resolve(ns).collapseVersions,
          isTrue,
          reason: '$ns should be collapsible',
        );
      }
    });

    test('default registry retains \$ver: history-bearing namespaces', () {
      final registry = ReclamationPolicyRegistry();
      expect(registry.resolve(r'$ver:users').collapseVersions, isFalse);
      expect(registry.resolve(r'$ver:users:abc123').collapseVersions, isFalse);
    });

    test('custom retainAllPrefixes overrides the default', () {
      final registry = ReclamationPolicyRegistry(
        retainAllPrefixes: const [r'$archive:'],
      );
      // Custom retain-all hit.
      expect(registry.resolve(r'$archive:logs').collapseVersions, isFalse);
      // The built-in \$ver: default is replaced when an override is supplied,
      // so \$ver: now collapses.
      expect(registry.resolve(r'$ver:users').collapseVersions, isTrue);
    });

    test('empty retainAllPrefixes makes every namespace collapse', () {
      final registry = ReclamationPolicyRegistry(retainAllPrefixes: const []);
      expect(registry.resolve('users').collapseVersions, isTrue);
      expect(registry.resolve(r'$ver:users').collapseVersions, isTrue);
    });

    test(
      'prefix match is anchored at the start, not anywhere in the string',
      () {
        final registry = ReclamationPolicyRegistry();
        // The string "$ver:" appearing mid-namespace must NOT match the
        // retain-all rule; the rule is a startsWith check.
        expect(registry.resolve(r'users:$ver:legacy').collapseVersions, isTrue);
      },
    );

    test(
      'retainAllPrefixes argument is captured by value (defensive copy)',
      () {
        final mutable = <String>[r'$ver:'];
        final registry = ReclamationPolicyRegistry(retainAllPrefixes: mutable);
        mutable.clear();
        // Mutating the caller's list does not affect the registry.
        expect(registry.resolve(r'$ver:users').collapseVersions, isFalse);
      },
    );
  });

  group('built-in policy implementations', () {
    test('CollapseToNewestPolicy collapses', () {
      expect(const CollapseToNewestPolicy().collapseVersions, isTrue);
    });

    test('RetainAllVersionsPolicy retains', () {
      expect(const RetainAllVersionsPolicy().collapseVersions, isFalse);
    });
  });
}
