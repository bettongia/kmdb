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

/// Unit tests for [ValueContext] itself (0.10.01 WI-3 / finding E-2):
/// the [ValueContext.toAad] byte composition, its length-prefix collision
/// guard, the leading domain byte, equality/hashCode, and each named
/// constructor's namespace-literal behaviour.
///
/// Higher-level AAD *behavioural* tests (relocation, transplant, rollback
/// boundary, `$ver:` isolation, `version:config` double-encryption, fault
/// injection) live in `test/encryption/value_aad_test.dart`. This file is
/// concerned only with [ValueContext]'s own byte-level correctness.
library;

import 'dart:typed_data';

import 'package:kmdb/src/encryption/value_context.dart';
import 'package:kmdb/src/engine/kvstore/meta_store.dart';
import 'package:test/test.dart';

void main() {
  group('ValueContext.toAad composition', () {
    test('starts with the 0x01 domain byte', () {
      final aad = const ValueContext('tasks', 'key1').toAad();
      expect(aad[0], equals(0x01));
    });

    test('is deterministic for the same namespace/key', () {
      final a = const ValueContext('tasks', 'key1').toAad();
      final b = const ValueContext('tasks', 'key1').toAad();
      expect(a, equals(b));
    });

    test('differs when the namespace differs', () {
      final a = const ValueContext('tasks', 'key1').toAad();
      final b = const ValueContext('notes', 'key1').toAad();
      expect(a, isNot(equals(b)));
    });

    test('differs when the key differs', () {
      final a = const ValueContext('tasks', 'key1').toAad();
      final b = const ValueContext('tasks', 'key2').toAad();
      expect(a, isNot(equals(b)));
    });

    test('length-prefixing prevents ("ab","c") / ("a","bc") collision', () {
      // Without length-prefixing, naive concatenation of namespace+key would
      // make these two contexts produce identical AAD bytes. This is the
      // exact collision the plan's length-prefix design decision guards
      // against (Phase 1).
      final a = const ValueContext('ab', 'c').toAad();
      final b = const ValueContext('a', 'bc').toAad();
      expect(a, isNot(equals(b)));
    });

    test('length-prefixing prevents a boundary-shifted collision across a '
        'longer run of characters', () {
      final a = const ValueContext('namespace', 'x').toAad();
      final b = const ValueContext('namespac', 'ex').toAad();
      expect(a, isNot(equals(b)));
    });

    test('empty namespace and empty key produce a valid, non-empty AAD', () {
      final aad = const ValueContext('', '').toAad();
      // domainByte(1) + lenPrefix(4) + '' + lenPrefix(4) + '' = 9 bytes.
      expect(aad.length, equals(9));
      expect(aad[0], equals(0x01));
    });

    test('handles non-ASCII (UTF-8) namespace/key content', () {
      final aad = const ValueContext('café', 'clé-日本語').toAad();
      // Just confirm it round-trips deterministically and doesn't throw —
      // the exact byte length depends on UTF-8 encoding of the multi-byte
      // characters, not asserted here.
      final again = const ValueContext('café', 'clé-日本語').toAad();
      expect(aad, equals(again));
    });

    test('returns a Uint8List', () {
      expect(const ValueContext('ns', 'k').toAad(), isA<Uint8List>());
    });
  });

  group('ValueContext equality and hashCode', () {
    test('two contexts with the same namespace/key are equal', () {
      expect(
        const ValueContext('tasks', 'k1'),
        equals(const ValueContext('tasks', 'k1')),
      );
    });

    test('hashCode matches for equal contexts', () {
      expect(
        const ValueContext('tasks', 'k1').hashCode,
        equals(const ValueContext('tasks', 'k1').hashCode),
      );
    });

    test('contexts with different namespaces are not equal', () {
      expect(
        const ValueContext('tasks', 'k1'),
        isNot(equals(const ValueContext('notes', 'k1'))),
      );
    });

    test('contexts with different keys are not equal', () {
      expect(
        const ValueContext('tasks', 'k1'),
        isNot(equals(const ValueContext('tasks', 'k2'))),
      );
    });

    test('toString includes namespace and key', () {
      final s = const ValueContext('tasks', 'k1').toString();
      expect(s, contains('tasks'));
      expect(s, contains('k1'));
    });
  });

  group('Named constructors', () {
    test('ValueContext.meta uses the same literal as MetaStore.kNamespace', () {
      // The doc comment on ValueContext.meta promises this literal is
      // mirrored from MetaStore.kNamespace (not imported, to avoid a cycle) —
      // this test is the guard against the two literals drifting apart.
      final viaMeta = ValueContext.meta('some-name');
      expect(viaMeta.namespace, equals(MetaStore.kNamespace));
      expect(viaMeta.key, equals('some-name'));
    });

    test('ValueContext.vaultBlob binds the sha256 as the key', () {
      final ctx = ValueContext.vaultBlob('a' * 64);
      expect(ctx.key, equals('a' * 64));
    });

    test('ValueContext.vaultExtract binds the path as the key', () {
      final ctx = ValueContext.vaultExtract('extract/text.txt');
      expect(ctx.key, equals('extract/text.txt'));
    });

    test('ValueContext.vaultManifestName binds the sha256 as the key', () {
      final ctx = ValueContext.vaultManifestName('b' * 64);
      expect(ctx.key, equals('b' * 64));
    });

    test(
      'ValueContext.vaultManifestName uses a DISTINCT namespace literal from '
      'ValueContext.vaultBlob for the same sha256 (Q5 — prevents an AAD '
      'collision that would let the two ciphertexts be swapped)',
      () {
        final sha256 = 'c' * 64;
        final blobCtx = ValueContext.vaultBlob(sha256);
        final manifestCtx = ValueContext.vaultManifestName(sha256);
        expect(blobCtx.namespace, isNot(equals(manifestCtx.namespace)));
        expect(blobCtx.toAad(), isNot(equals(manifestCtx.toAad())));
      },
    );

    test('ValueContext.vaultExtract uses a distinct namespace literal from '
        'ValueContext.vaultBlob', () {
      final blobCtx = ValueContext.vaultBlob('d' * 64);
      final extractCtx = ValueContext.vaultExtract('d' * 64);
      expect(blobCtx.namespace, isNot(equals(extractCtx.namespace)));
    });

    test('ValueContext.vaultCorpus is sugar over the base constructor — equal '
        'to a plain ValueContext with the same (namespace, key)', () {
      final viaCorpus = ValueContext.vaultCorpus(
        r'$$vault:fts:abc',
        'sentinel',
      );
      final viaBase = const ValueContext(r'$$vault:fts:abc', 'sentinel');
      expect(viaCorpus, equals(viaBase));
      expect(viaCorpus.toAad(), equals(viaBase.toAad()));
    });

    test('each named constructor is const-constructible', () {
      // Compile-time check: these must all be usable in const contexts.
      const a = ValueContext.meta('n');
      const b = ValueContext.vaultBlob('sha');
      const c = ValueContext.vaultExtract('path');
      const d = ValueContext.vaultManifestName('sha');
      const e = ValueContext.vaultCorpus('ns', 'key');
      expect([a, b, c, d, e], hasLength(5));
    });
  });
}
