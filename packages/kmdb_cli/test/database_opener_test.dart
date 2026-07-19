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

/// Production-path integration tests for [DatabaseOpener]'s vault wiring
/// (WI-12, Phase A).
///
/// `kmdb_cli`'s own vault command test suites (e.g.
/// `test/commands/vault/vault_search_commands_test.dart`,
/// `test/commands/vault/insert_import_test.dart`) universally open the
/// database via `KmdbDatabase.open()` directly, injecting a `_TestVaultStore`
/// double. That pattern never exercises `DatabaseOpener.open()` itself — the
/// CLI's actual, production entry point — so it could not have caught the
/// original WI-12 gap (`DatabaseOpener.open()` never passed `vaultStore:` to
/// `KmdbDatabase.open()`, leaving every vault command dead in production).
///
/// This file closes that hole: every test here opens the database through
/// [DatabaseOpener.open] against a real, on-disk [StorageAdapterNative]
/// directory — the exact code path `bin/kmdb.dart` uses — with no test
/// double standing in for vault storage.
library;

import 'dart:convert' show utf8;
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_cli/src/commands/command.dart';
import 'package:kmdb_cli/src/commands/insert_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_reindex_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_search_command.dart';
import 'package:kmdb_cli/src/commands/vault/vault_status_command.dart';
import 'package:kmdb_cli/src/database_opener.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Builds a [CommandContext] backed by [db].
CommandContext _ctx(KmdbDatabase db, {StringBuffer? out, StringBuffer? err}) =>
    CommandContext(
      db: db,
      out: out ?? StringBuffer(),
      err: err ?? StringBuffer(),
    );

/// Waits until vault indexing has settled (no pending/in-flight work).
Future<VaultIndexingStatus> _waitForIndexingComplete(KmdbDatabase db) => db
    .watchVaultIndexingStatus()
    .firstWhere((status) => status.isComplete)
    .timeout(const Duration(seconds: 30));

/// Ingests [bytes] into the vault and links it to a fresh document in
/// [collection] by inserting a document whose `file` field holds the
/// resulting `kmdb-vault://` URI.
///
/// Inserting through the public [KmdbCollection.insert] API (rather than
/// reaching for `KvStoreImpl.writeBatchInternal`, an `@internal` member of
/// `package:kmdb` not meant for cross-package use) is enough:
/// `KmdbDatabase.open` registers [VaultRefInterceptor] as a write augmentor
/// whenever a [VaultStore] is supplied, so the normal document write path
/// establishes both the `$vault` ref count and the `$vault:docref:` entry
/// that [KmdbCollection.searchVault] scopes candidates by — exactly what
/// [DatabaseOpener.open]'s unconditional [VaultStore] wiring is meant to
/// enable in production.
Future<VaultRef> _ingestAndLink(
  KmdbDatabase db,
  String collection,
  Uint8List bytes, {
  required String originalName,
  required String mediaType,
  required String hlcTimestamp,
}) async {
  final ref = await db.vaultStore!.ingest(
    bytes: bytes,
    hlcTimestamp: hlcTimestamp,
    originalName: originalName,
    explicitMediaType: mediaType,
  );

  final col = db.rawCollection(collection);
  await col.insert({'label': originalName, 'file': ref.uri});

  return ref;
}

void main() {
  late io.Directory tmp;
  var dbCounter = 0;

  setUp(() {
    tmp = io.Directory.systemTemp.createTempSync('kmdb_dbopener_test_');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup; leftover temp dirs don't fail the test run.
    }
  });

  /// Returns a fresh, unique database path under [tmp].
  String nextDbPath() => p.join(tmp.path, 'db${dbCounter++}');

  group('DatabaseOpener — vault wiring (Q5)', () {
    test(
      'constructs a non-null VaultStore for every opened database',
      () async {
        final (db, created) = await DatabaseOpener.open(
          nextDbPath(),
          KmdbConfig.empty(),
        );
        addTearDown(db.close);
        expect(created, isTrue);
        expect(db.vaultStore, isNotNull);
      },
    );

    test(
      'configures vault search (vaultSearchManager non-null) by default',
      () async {
        final (db, _) = await DatabaseOpener.open(
          nextDbPath(),
          KmdbConfig.empty(),
        );
        addTearDown(db.close);
        expect(db.vaultSearchManager, isNotNull);
      },
    );

    test(
      'open() stays fast when no vault directory exists yet on disk '
      '(VaultRecovery/VaultGc construction is cheap on a fresh database)',
      () async {
        // VaultRecovery/VaultGc construction now runs on every CLI open, not
        // just vault commands (reviewer's risk note). Both only ever call
        // StorageAdapter.listFiles/listFilesRecursive, which short-circuit on
        // a single directory-exists() check rather than walking the
        // filesystem when the target directory is absent — confirmed by
        // reading storage_adapter_native.dart. This asserts that behaviour
        // end-to-end: opening a brand-new database (no vault/ directory has
        // ever been created) must not measurably slow down `open()`.
        final stopwatch = Stopwatch()..start();
        final (db, _) = await DatabaseOpener.open(
          nextDbPath(),
          KmdbConfig.empty(),
        );
        stopwatch.stop();
        addTearDown(db.close);

        // Generous ceiling — this is a regression guard against an
        // accidental O(existing-data) scan being introduced, not a tight
        // performance assertion (CI machines vary).
        expect(stopwatch.elapsedMilliseconds, lessThan(5000));
      },
    );

    test(
      'insert --import succeeds against a DatabaseOpener-opened database '
      '(previously failed with "Vault is not available for this database")',
      () async {
        final (db, _) = await DatabaseOpener.open(
          nextDbPath(),
          KmdbConfig.empty(),
        );
        addTearDown(db.close);

        // A package with no vault URIs is enough to exercise the guard this
        // test is about — InsertCommand's first check is `ctx.vaultStore ==
        // null`, which fires before any vault-URI-specific logic.
        final packageBytes = VaultPackage.write(
          documentJson: {'n': 'x'},
          attachments: [],
        );
        final pkgPath = p.join(tmp.path, 'import.kvlt');
        io.File(pkgPath).writeAsBytesSync(packageBytes);

        final ctx = _ctx(db);
        final ok = await InsertCommand().execute(
          ctx,
          ['col'],
          {'import': pkgPath},
        );

        expect(ok, isTrue, reason: ctx.err.toString());
        expect(ctx.err.toString(), isNot(contains('Vault is not available')));
      },
    );
  });

  group('DatabaseOpener — vault search/status/reindex commands (Phase A)', () {
    test('empty vault: search/status/reindex all succeed with no-data '
        'messaging (no longer "Vault search is not configured")', () async {
      final (db, _) = await DatabaseOpener.open(
        nextDbPath(),
        KmdbConfig.empty(),
      );
      addTearDown(db.close);

      final searchOut = StringBuffer();
      final searchErr = StringBuffer();
      final searchOk = await const VaultSearchCommand().execute(
        _ctx(db, out: searchOut, err: searchErr),
        ['anything'],
        {'collection': 'docs'},
      );
      expect(searchOk, isTrue, reason: searchErr.toString());
      expect(searchErr.toString(), isNot(contains('not configured')));
      expect(searchOut.toString(), contains('No vault search results'));

      final statusOut = StringBuffer();
      final statusErr = StringBuffer();
      final statusOk = await const VaultStatusCommand().execute(
        _ctx(db, out: statusOut, err: statusErr),
        [],
        {},
      );
      expect(statusOk, isTrue, reason: statusErr.toString());
      expect(statusErr.toString(), isNot(contains('not configured')));
      expect(statusOut.toString(), contains('Total blobs:'));

      final reindexOut = StringBuffer();
      final reindexErr = StringBuffer();
      final reindexOk = await const VaultReindexCommand().execute(
        _ctx(db, out: reindexOut, err: reindexErr),
        [],
        {},
      );
      expect(reindexOk, isTrue, reason: reindexErr.toString());
      expect(reindexErr.toString(), isNot(contains('not configured')));
    });

    test('lexical hits over plain-text, HTML, Markdown, and PDF vault blobs '
        '(one fixture per default-registered extractor)', () async {
      final (db, _) = await DatabaseOpener.open(
        nextDbPath(),
        KmdbConfig.empty(),
      );
      addTearDown(db.close);

      const collection = 'docs';

      // PlainTextExtractor (auto-prepended by VaultSearchConfig itself).
      await _ingestAndLink(
        db,
        collection,
        Uint8List.fromList(
          utf8.encode('the plaintextmarker fox jumps over the lazy dog'),
        ),
        originalName: 'note.txt',
        mediaType: 'text/plain',
        hlcTimestamp: '0000000000000001',
      );

      // HtmlTextExtractor.
      await _ingestAndLink(
        db,
        collection,
        Uint8List.fromList(
          utf8.encode(
            '<html><body><p>htmlmarker appears in this paragraph</p>'
            '</body></html>',
          ),
        ),
        originalName: 'page.html',
        mediaType: 'text/html',
        hlcTimestamp: '0000000000000002',
      );

      // MarkdownTextExtractor.
      await _ingestAndLink(
        db,
        collection,
        Uint8List.fromList(
          utf8.encode('# Heading\n\nmarkdownmarker body text follows.'),
        ),
        originalName: 'doc.md',
        mediaType: 'text/markdown',
        hlcTimestamp: '0000000000000003',
      );

      // PdfTextExtractor — real fixture PDF containing distinctive,
      // non-stopword Greek-letter placeholder text ("alpha beta gamma
      // delta epsilon zeta ..."). See test/fixtures/README.md for why
      // kmdb_extractor_pdf's more obvious "01_basic.pdf" (text: "hello")
      // fixture doesn't work here — "hello" is an English stop word.
      final pdfBytes = await io.File(
        'test/fixtures/multi_column.pdf',
      ).readAsBytes();
      await _ingestAndLink(
        db,
        collection,
        pdfBytes,
        originalName: 'multi_column.pdf',
        mediaType: 'application/pdf',
        hlcTimestamp: '0000000000000004',
      );

      final status = await _waitForIndexingComplete(db);
      expect(
        status.indexed,
        equals(4),
        reason:
            'all four blobs (plain/HTML/Markdown/PDF) should have reached '
            'indexed status: $status',
      );
      expect(status.failed, equals(0));
      expect(status.unsupported, equals(0));

      Future<void> expectHit(String query) async {
        final out = StringBuffer();
        final err = StringBuffer();
        final ok = await const VaultSearchCommand().execute(
          _ctx(db, out: out, err: err),
          [query],
          {'collection': collection, 'mode': 'lexical'},
        );
        expect(ok, isTrue, reason: err.toString());
        expect(
          out.toString(),
          isNot(contains('No vault search results')),
          reason:
              'expected a lexical hit for "$query" but got no results:\n'
              '${out.toString()}',
        );
      }

      await expectHit('plaintextmarker');
      await expectHit('htmlmarker');
      await expectHit('markdownmarker');
      await expectHit('gamma');
    });

    test('vault status warns about stub (not-yet-downloaded) blobs and reports '
        'status.stub > 0', () async {
      final (db, _) = await DatabaseOpener.open(
        nextDbPath(),
        KmdbConfig.empty(),
      );
      addTearDown(db.close);

      // A stub is a manifest-only hash directory with no blob content —
      // the state a device is in for an object a peer has referenced but
      // this device has not yet downloaded. Per VaultStore.createStub's
      // producer-side contract, a stub may only be created once a positive
      // `$vault` reference already exists on this device — establish that
      // first via the same interceptor path _ingestAndLink uses, then swap
      // in a manifest-only stub in place of the real (fully-ingested) blob.
      final bytes = Uint8List.fromList(utf8.encode('stub source content'));
      final sha256 = VaultStore.computeSha256(bytes);
      final col = db.rawCollection('docs');

      // Establish a positive $vault ref via the public write path — see
      // _ingestAndLink's doc comment for why this (rather than
      // KvStoreImpl.writeBatchInternal, an @internal member) is the right
      // way to do this from outside package:kmdb.
      final ref = VaultRef('kmdb-vault://sha256/$sha256');
      await col.insert({'label': 'stub-source', 'file': ref.uri});

      final manifest = VaultManifest(
        sha256: sha256,
        size: bytes.length,
        crc32c: 'deadbeef',
        mediaType: 'text/plain',
        originalName: 'stub.txt',
        createdAt: '2026-07-14T00:00:00Z',
      );
      await db.vaultStore!.createStub(manifest, kvStore: db.store);

      final statusOut = StringBuffer();
      final statusErr = StringBuffer();
      final statusOk = await const VaultStatusCommand().execute(
        _ctx(db, out: statusOut, err: statusErr),
        [],
        {},
      );
      expect(statusOk, isTrue, reason: statusErr.toString());
      expect(statusOut.toString(), contains('Stub (not downloaded): 1'));

      // VaultSearchCommand prints the same stub warning to stderr.
      final searchOut = StringBuffer();
      final searchErr = StringBuffer();
      await const VaultSearchCommand().execute(
        _ctx(db, out: searchOut, err: searchErr),
        ['anything'],
        {'collection': 'docs'},
      );
      expect(
        searchErr.toString(),
        contains('not yet downloaded on this device'),
      );
    });
  });
}
