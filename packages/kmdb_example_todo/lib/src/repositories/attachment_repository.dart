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

import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';

import '../models/task.dart';
import 'task_repository.dart';

/// Wraps [VaultStore] content-addressable ingestion and retrieval, plus the
/// bookkeeping of adding/removing a `kmdb-vault://` URI from a [Task]'s
/// [Task.attachmentUris].
///
/// ## Why ref-counting "just works"
///
/// [attach] and [detach] both go through [TaskRepository.update], which
/// writes the [Task] document through `KmdbCollection` — the same
/// `WriteBatch` that carries the document write also carries the
/// `VaultRefInterceptor`'s ref-count adjustment (increment on `attach`,
/// decrement on `detach`), because `AppDatabase.open` wired a [VaultStore].
/// There is no separate "commit the ref count" step to remember.
class AttachmentRepository {
  /// Creates an [AttachmentRepository] backed by [db]'s [VaultStore] and
  /// [taskRepository].
  ///
  /// Throws [StateError] if [db] was opened without a `vaultStore` (this app
  /// always supplies one — see `AppDatabase.open` — so this only signals a
  /// programming error, e.g. constructing this class against a bare test
  /// database that opted out of vault support).
  AttachmentRepository(KmdbDatabase db, this._taskRepository)
    : _db = db,
      _vaultStore = db.vaultStore ?? (throw StateError('db has no VaultStore'));

  final KmdbDatabase _db;
  final VaultStore _vaultStore;
  final TaskRepository _taskRepository;

  /// Ingests [bytes] into the vault, appends the resulting
  /// `kmdb-vault://sha256/<64hex>` URI to [task]'s [Task.attachmentUris], and
  /// writes the updated task. Returns the updated [Task].
  ///
  /// Ingesting identical bytes a second time (from this task or any other)
  /// dedupes to the same vault object — see [VaultStore.ingest]'s doc
  /// comment for the content-addressing / CRC32C-collision details.
  Future<Task> attach({
    required Task task,
    required Uint8List bytes,
    required String originalName,
  }) async {
    // The vault write path records the current HLC timestamp alongside the
    // ingested blob (used by consolidation/GC bookkeeping) — obtained from
    // the same KvStore the document write below will use.
    final info = await _db.store.storeInfo();
    final ref = await _vaultStore.ingest(
      bytes: bytes,
      hlcTimestamp: info.currentHlc,
      originalName: originalName,
    );

    final updated = task.copyWith(
      attachmentUris: [...task.attachmentUris, ref.uri],
    );
    await _taskRepository.update(updated);
    return updated;
  }

  /// Removes [uri] from [task]'s [Task.attachmentUris] and writes the
  /// updated task. Returns the updated [Task].
  ///
  /// This decrements the vault object's reference count; the underlying blob
  /// is only garbage-collected once its count reaches zero and no other
  /// document references it (spec §24).
  Future<Task> detach({required Task task, required String uri}) async {
    final updated = task.copyWith(
      attachmentUris: task.attachmentUris.where((u) => u != uri).toList(),
    );
    await _taskRepository.update(updated);
    return updated;
  }

  /// Retrieves the raw bytes for the vault object referenced by [uri].
  Future<Uint8List> getBlob(String uri) =>
      _vaultStore.getBytes(VaultRef(uri).sha256);
}
