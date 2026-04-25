// Copyright 2026 The KMDB Authors.
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

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';

/// Reads and parses a KVLT vault package from [packagePath] or [packageBytes].
///
/// Returns the parsed [VaultPackageContents] or `null` on error (writes the
/// error to [errSink]).
VaultPackageContents? readVaultPackage({
  required String? packagePath,
  required Uint8List? packageBytes,
  required StringSink errSink,
}) {
  Uint8List bytes;
  if (packageBytes != null) {
    bytes = packageBytes;
  } else if (packagePath != null) {
    try {
      bytes = io.File(packagePath).readAsBytesSync();
    } on io.IOException catch (e) {
      errSink.writeln('Error: Cannot read package file "$packagePath": $e');
      return null;
    }
  } else {
    // coverage:ignore-start
    // Read from stdin synchronously.
    final chunks = <int>[];
    int byte;
    // Read raw stdin bytes.
    try {
      while ((byte = io.stdin.readByteSync()) != -1) {
        chunks.add(byte);
      }
    } on io.StdinException {
      // stdin closed.
    }
    bytes = Uint8List.fromList(chunks);
    // coverage:ignore-end
  }

  try {
    return VaultPackage.read(bytes);
  } on FormatException catch (e) {
    errSink.writeln('Error: Invalid vault package: ${e.message}');
    return null;
  }
}

/// Ingests all [attachments] from a vault package into [vaultStore], returning
/// the set of ingested SHA-256 hashes.
///
/// Returns `null` and writes to [errSink] if any attachment fails to ingest.
Future<Set<String>?> ingestVaultAttachments({
  required VaultStore vaultStore,
  required List<VaultAttachment> attachments,
  required String hlcTimestamp,
  required StringSink errSink,
}) async {
  final hashes = <String>{};
  for (final att in attachments) {
    try {
      final ref = await vaultStore.ingest(
        bytes: att.bytes,
        hlcTimestamp: hlcTimestamp,
        originalName: att.uploadManifest?.originalName ?? 'blob',
      );
      hashes.add(ref.sha256);
    } on VaultCrcMismatchException catch (e) {
      errSink.writeln('Error: $e');
      return null;
    } catch (e) {
      errSink.writeln('Error: Failed to ingest vault attachment: $e');
      return null;
    }
  }
  return hashes;
}

/// Writes vault ref-count increments for each vault URI in [doc] into [batch].
///
/// This performs the same ref-count adjustment that [VaultRefInterceptor] does
/// in the Query Layer — used by CLI commands that bypass KmdbCollection.
///
/// Note: this CLI-level adjustment does not handle un-tombstoning (if a
/// previously zero-ref object is re-referenced, its tombstone is not removed).
/// This is an acceptable limitation for CLI import workflows.
Future<void> applyVaultRefCounts({
  required Map<String, dynamic> doc,
  required Map<String, dynamic>? oldDoc,
  required KvStoreImpl store,
  required VaultStore vaultStore,
  required WriteBatch batch,
}) async {
  final gc = VaultGc(store: vaultStore, kvStore: store);
  final interceptor = VaultRefInterceptor(kvStore: store, gc: gc);
  await interceptor.interceptWrite(
    batch: batch,
    namespace: '',
    docKey: '',
    oldDoc: oldDoc,
    newDoc: doc,
  );
}

/// Reads all vault URI strings from [doc] by recursively scanning all values.
///
/// Returns a set of SHA-256 hashes referenced by vault URIs in the document.
Set<String> extractVaultUrisFromDoc(Map<String, dynamic> doc) {
  final result = <String>{};
  _scan(doc, result);
  return result;
}

void _scan(dynamic value, Set<String> result) {
  if (value is String && VaultRef.isVaultUri(value)) {
    result.add(VaultRef(value).sha256);
  } else if (value is Map<String, dynamic>) {
    for (final v in value.values) {
      _scan(v, result);
    }
  } else if (value is List<dynamic>) {
    for (final item in value) {
      _scan(item, result);
    }
  }
}

/// Reads the current vault ref count for [sha256] from [store].
///
/// Returns 0 if no entry exists.
Future<int> readVaultRefCount(KvStoreImpl store, String sha256) async {
  final bytes = await store.get(kVaultNamespace, sha256);
  if (bytes == null) return 0;
  final decoded = ValueCodec.decode(bytes);
  final count = decoded['refCount'];
  return count is int ? count : 0;
}
