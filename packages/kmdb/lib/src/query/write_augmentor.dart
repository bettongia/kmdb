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

import '../engine/kvstore/kv_store.dart';

/// Layer 2 of the formal write pipeline: write-batch augmentation.
///
/// A [WriteAugmentor] is called after all [WriteValidator]s pass and before the
/// [WriteBatch] is committed. Augmentors add extra entries to the batch for
/// their own concern (secondary index entries, FTS postings, vector embeddings,
/// vault ref counts). Because all augmentor writes land in the same atomic
/// [WriteBatch] as the document write, the system is always consistent.
///
/// ## Implementing an augmentor
///
/// ```dart
/// final class AuditLogAugmentor implements WriteAugmentor {
///   @override
///   Future<void> interceptWrite({
///     required WriteBatch batch,
///     required String namespace,
///     required String docKey,
///     required Map<String, dynamic>? newDoc,
///     required Map<String, dynamic>? oldDoc,
///   }) async {
///     final entry = {'ns': namespace, 'key': docKey, 'at': DateTime.now().toIso8601String()};
///     batch.put('\$audit', docKey, ValueCodec.encode(entry));
///   }
/// }
/// ```
///
/// See also:
/// - [WriteValidator] — Layer 1: validates before any I/O.
abstract interface class WriteAugmentor {
  /// Adds entries to [batch] for this augmentor's concern.
  ///
  /// [newDoc] is `null` for deletes; [oldDoc] is `null` for new inserts.
  /// Both may be non-null for updates (the merged result and the previous
  /// value respectively).
  ///
  /// Runs after all validators pass and before [WriteBatch] is committed.
  /// Must not throw unless the augmentation itself fails — a thrown exception
  /// aborts the entire write.
  Future<void> interceptWrite({
    required WriteBatch batch,
    required String namespace,
    required String docKey,
    required Map<String, dynamic>? newDoc,
    required Map<String, dynamic>? oldDoc,
  });
}
