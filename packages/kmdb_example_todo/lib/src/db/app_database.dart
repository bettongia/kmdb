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

import 'package:kmdb/kmdb.dart';
import 'package:kmdb_extractor_html/kmdb_extractor_html.dart';
import 'package:kmdb_extractor_markdown/kmdb_extractor_markdown.dart';

import 'schemas.dart';

/// Opens the app's [KmdbDatabase], wiring every subsystem the Integration
/// Guide demonstrates: secondary indexes, full-text search, vault content
/// search, JSON Schema admission, and encryption.
///
/// See the Integration Guide's "Open and close a database" section for the
/// full walk-through of each parameter below.
abstract final class AppDatabase {
  /// Opens (or creates) the database at [path].
  ///
  /// [encryptionConfig] selects the create-vs-unlock branch:
  ///
  /// - `null` opens (or creates) a **plaintext** database.
  /// - `EncryptionConfig(passphrase: ...)` or `EncryptionConfig(recoveryCode:
  ///   ...)` unlocks an **existing encrypted** database.
  /// - `(await EncryptionConfig.createResult(passphrase: ...)).config`
  ///   provisions a **new encrypted** database — see the "Unlock/Create"
  ///   screen (`lib/src/ui/screens/unlock_screen.dart`) for where that
  ///   create-vs-unlock decision is actually made in this app.
  ///
  /// Throws [EncryptionError] if [encryptionConfig] mismatches the
  /// database's actual encryption state (e.g. a wrong passphrase, or opening
  /// an encrypted database with `encryptionConfig: null`) — see the guide's
  /// "Handle faults" section.
  ///
  /// Calls [KmdbDatabase.ensureDeviceId] before returning: every SSTable this
  /// device flushes must carry a stable device ID for sync and consolidation
  /// to work correctly (spec §4), and the default `'00000000'` sentinel
  /// device ID `KmdbDatabase.open` otherwise uses is only meaningful for
  /// tests that never sync.
  ///
  /// [adapter] defaults to [StorageAdapterNative] — the real filesystem. Data
  /// -layer tests that don't exercise vault or sync (CRUD, schema admission,
  /// secondary indexes) may pass a [MemoryStorageAdapter] instead for speed;
  /// vault and sync tests should keep the real default, since those
  /// subsystems' crash-safety depends on genuine filesystem semantics (see
  /// CLAUDE.md's note on why in-memory adapters hide a class of durability
  /// bugs).
  static Future<KmdbDatabase> open({
    required String path,
    EncryptionConfig? encryptionConfig,
    StorageAdapter? adapter,
  }) async {
    final resolvedAdapter = adapter ?? StorageAdapterNative();
    await resolvedAdapter.createDirectory(path);

    // A VaultStore is constructed unconditionally so every screen can attach
    // files to a task — vault ref counting and GC then run automatically
    // for every KmdbCollection write that references a `kmdb-vault://` URI
    // (see AttachmentRepository and VaultRefInterceptor).
    final vaultStore = VaultStore(dbDir: path, adapter: resolvedAdapter);

    final db = await KmdbDatabase.open(
      path: path,
      adapter: resolvedAdapter,
      encryptionConfig: encryptionConfig,
      schemas: AppSchemas.all,
      // Secondary indexes power the project -> tasks and task -> comments
      // listings (spec §16). Both are built lazily on first query.
      indexes: [
        IndexDefinition('tasks', 'projectId'),
        IndexDefinition('taskComments', 'taskId'),
      ],
      // Field-level lexical (BM25) search over task title/description and
      // comment bodies (spec §21). `KmdbCollection.search()` demoes
      // `SearchMode.lexical` explicitly — see the Search screen — rather
      // than semantic/hybrid, which would need an ONNX embedding model and
      // its native-asset weight for a v1 desktop guide that doesn't need it.
      ftsIndexes: [
        FtsIndexDefinition(collection: 'tasks', field: 'title'),
        FtsIndexDefinition(collection: 'tasks', field: 'description'),
        FtsIndexDefinition(collection: 'taskComments', field: 'body'),
      ],
      vaultStore: vaultStore,
      // Attachment-*content* search (spec §24 "Vault Search") — a separate
      // index from the field FTS above, searching the extracted text of
      // attached files rather than task/comment fields. Pure-Dart extractors
      // only: HtmlTextExtractor and MarkdownTextExtractor. PdfTextExtractor
      // (native, kmdb_extractor_pdf) is deliberately left out of v1 — see
      // the guide's "Going further" callout.
      vaultSearch: VaultSearchConfig(
        extractors: [HtmlTextExtractor(), MarkdownTextExtractor()],
      ),
    );

    await db.ensureDeviceId();
    return db;
  }
}
