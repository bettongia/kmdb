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

// ignore_for_file: avoid_print

/// Example: indexing and searching a PDF file's content via KMDB vault search.
///
/// Opens a native, on-disk [KmdbDatabase] with vault search enabled and
/// [PdfTextExtractor] registered for `application/pdf` blobs, ingests a PDF
/// file supplied as a command-line argument, waits for indexing to complete,
/// and runs a [KmdbCollection.searchVault] query against it.
///
/// ## Usage
///
/// ```bash
/// dart run example/pdf_extractor_example.dart /path/to/document.pdf "some query"
/// ```
///
/// If no path is supplied, this example ingests one of its own test fixtures
/// so it can be run with no arguments.
///
/// ## `_NativeVaultStore` — a note on native filesystem enumeration
///
/// `VaultStore.listFilesRecursive` — used by
/// [KmdbDatabase.vaultIndexingStatus] and vault recovery/GC sweeps to
/// enumerate known blobs — defaults to returning an empty list; the class
/// doc calls this out as a "v1 stopgap" requiring an override "in a subclass
/// or test double to provide native filesystem traversal" for any real
/// (non-memory) backing store. Without an override, `vaultIndexingStatus()`
/// always reports zero known blobs even though ingestion and indexing
/// otherwise work normally. `_NativeVaultStore` below shows the minimal
/// override real applications need until a native default ships upstream.
library;

import 'dart:io';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_pdf/kmdb_extractor_pdf.dart';

/// A [VaultStore] that can enumerate files on a real filesystem.
///
/// See the library-level doc comment for why this override is currently
/// necessary for any non-memory-backed [VaultStore].
final class _NativeVaultStore extends VaultStore {
  _NativeVaultStore({required super.adapter, required super.dbDir});

  @override
  Future<List<String>> listFilesRecursive(String dirPath) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];
    final prefixLength = dirPath.endsWith('/')
        ? dirPath.length
        : dirPath.length + 1;
    return [
      await for (final entity in dir.list(recursive: true))
        if (entity is File) entity.path.substring(prefixLength),
    ];
  }
}

Future<void> main(List<String> args) async {
  final pdfPath = args.isNotEmpty
      ? args[0]
      : 'test/fixtures/arxiv/2312.17524v1.pdf';
  final query = args.length > 1 ? args[1] : 'Distributed File Systems';

  final pdfFile = File(pdfPath);
  if (!pdfFile.existsSync()) {
    stderr.writeln('PDF file not found: $pdfPath');
    exit(1);
  }

  // Use a fresh temporary directory for this example's database.
  final dbDir = Directory.systemTemp.createTempSync('kmdb_extractor_pdf_');
  print('Opening database at ${dbDir.path} ...');

  try {
    final adapter = StorageAdapterNative();
    final vaultStore = _NativeVaultStore(adapter: adapter, dbDir: dbDir.path);

    final db = await KmdbDatabase.open(
      path: dbDir.path,
      adapter: adapter,
      vaultStore: vaultStore,
      // PdfTextExtractor is the only extractor most applications need to add
      // — PlainTextExtractor (text/plain) is always included automatically.
      vaultSearch: VaultSearchConfig(extractors: [PdfTextExtractor()]),
    );

    try {
      print('Ingesting $pdfPath into the vault ...');
      final bytes = await pdfFile.readAsBytes();
      await vaultStore.ingest(
        bytes: bytes,
        hlcTimestamp: DateTime.now().millisecondsSinceEpoch
            .toRadixString(16)
            .padLeft(16, '0'),
        originalName: pdfFile.uri.pathSegments.last,
        explicitMediaType: 'application/pdf',
      );

      // Ingestion alone auto-queues extraction and indexing — poll the
      // point-in-time status until the newly-ingested blob is accounted for
      // and indexing has settled.
      print('Waiting for vault indexing to complete ...');
      var status = await db.vaultIndexingStatus();
      while (status.total == 0 || !status.isComplete) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        status = await db.vaultIndexingStatus();
      }
      print('Indexing status: $status');

      // A real application would also insert a document whose fields
      // reference the ingested blob via its VaultRef.uri, e.g.:
      //
      //   final collection = db.rawCollection('papers');
      //   await collection.insert({'title': '...', 'pdf': ref.uri});
      //
      // so that searchVault() results resolve back to application documents
      // (see VaultSearchConfig's own doc comment for this pattern). This
      // example queries an empty collection to keep the example runnable
      // with no other setup — hits will be empty here since no document
      // references the ingested blob.
      final collection = db.rawCollection('papers');
      final result = await collection.searchVault(query);
      print(
        'searchVault("$query") → ${result.hits.length} hit(s) '
        '(searched: ${result.metadata.searched}).',
      );
    } finally {
      await db.close();
    }
  } finally {
    dbDir.deleteSync(recursive: true);
  }
}
