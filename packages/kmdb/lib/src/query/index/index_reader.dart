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

import '../../encryption/encryption_provider.dart';
import '../../engine/kvstore/kv_store.dart';
import 'index_definition.dart';
import 'index_writer.dart';

/// Reads document keys from a secondary index (spec §16).
///
/// Uses the **namespace-per-value** storage scheme implemented by
/// [IndexWriter]: all document keys for a given field value are stored within
/// a dedicated system namespace
/// `$$index:{ns}:{path}:{token}` with their 32-character document
/// keys as the entry keys.
///
/// An equality lookup is therefore a full scan of that namespace — no key
/// range bounds required.
abstract final class IndexReader {
  IndexReader._();

  /// Returns all document keys that have [value] in the [definition]'s field.
  ///
  /// Scans the dedicated index namespace for [value] and collects every key,
  /// which is the 32-character document key. Returns an empty list if no
  /// documents match, or if [value] is not indexable (null, Map, List).
  ///
  /// [encryption] must match what was used when the index was written, so
  /// that the same namespace token is reconstructed (Gap 2).
  static Future<List<String>> lookupByValue({
    required KvStore store,
    required IndexDefinition definition,
    required Object? value,
    EncryptionProvider? encryption,
  }) async {
    if (value == null) return const [];
    final ns = await IndexWriter.indexNamespaceForValue(
      definition,
      value,
      encryption: encryption,
    );
    if (ns == null) return const [];

    final docKeys = <String>[];
    await for (final entry in store.scan(ns)) {
      docKeys.add(entry.key);
    }
    return docKeys;
  }
}
