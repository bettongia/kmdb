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

import 'dart:typed_data';

/// A single file stored in a [SharedCloudBackend].
///
/// Carries the raw bytes, a monotonically-incrementing version used as the
/// ETag, and a monotonic global write-sequence number assigned at commit time.
/// The write-sequence is the basis of the visibility model: front-ends
/// (e.g. [CloudSemanticsAdapter]) expose only entries whose [writeSeq] is
/// at or below their current visibility cursor.
final class StoredFile {
  /// Creates a [StoredFile].
  const StoredFile({
    required this.bytes,
    required this.version,
    required this.writeSeq,
    required this.writerDeviceId,
  });

  /// Raw file content.
  final Uint8List bytes;

  /// Monotonically-incrementing version counter used as the ETag string.
  ///
  /// Every successful write (upload, successful compareAndSwap) increments
  /// this counter. The string form is `version.toString()`.
  final int version;

  /// Global write-sequence number assigned at the moment of commit.
  ///
  /// The backend's [SharedCloudBackend.nextWriteSeq] is the source. When a
  /// [CloudSemanticsAdapter] has a visibility cursor at `seqHigh`, only files
  /// whose [writeSeq] is `<= seqHigh` are considered visible to that front-end.
  final int writeSeq;

  /// The device-ID string of the writer, for diagnostic purposes.
  final String writerDeviceId;

  /// Returns a copy with an incremented [version] and a new [writeSeq].
  StoredFile updated({
    required Uint8List bytes,
    required int newWriteSeq,
    required String writerDeviceId,
  }) => StoredFile(
    bytes: bytes,
    version: version + 1,
    writeSeq: newWriteSeq,
    writerDeviceId: writerDeviceId,
  );
}

/// The canonical, strongly-consistent backing store for the cloud simulation.
///
/// [SharedCloudBackend] is the single source of truth shared by all front-end
/// adapters ([SharedBackendAdapter], [CloudSemanticsAdapter]). It is
/// **strongly consistent internally** — the file map is the ground truth and
/// every write is immediately reflected in subsequent reads from the same
/// backend object.
///
/// Per-front-end weakening (propagation delay, out-of-order visibility) is
/// applied on top by the front-end adapter decorators; the backend itself
/// never withholds data.
///
/// ## Write-sequence model
///
/// Every committed write increments [nextWriteSeq] and stamps the resulting
/// [StoredFile] with that sequence number. The sequence is strictly monotonic.
/// Front-ends that implement eventual consistency track a per-observer
/// *visibility cursor* — the highest `writeSeq` whose files are currently
/// visible to that observer. Once the cursor advances past a write's
/// [StoredFile.writeSeq], the write becomes permanently visible.
///
/// ## ETag semantics
///
/// The ETag for a file is the string representation of [StoredFile.version].
/// Every successful write increments the version; the [compareAndSwap]
/// implementation is **truly atomic** (the check and update run in the same
/// synchronous step, with no await between them) so it is safe to pass
/// `expectAtomicCas: true` in the conformance suite for a
/// [SharedBackendAdapter] wrapping this backend.
///
/// ## Example
///
/// ```dart
/// final backend = SharedCloudBackend();
/// final adapter = SharedBackendAdapter(backend, deviceId: 'device0');
/// await adapter.upload('sstables/foo.sst', bytes);
/// ```
final class SharedCloudBackend {
  /// Creates an empty [SharedCloudBackend].
  SharedCloudBackend();

  /// Internal file map: remote path → stored file.
  final Map<String, StoredFile> _files = {};

  /// Global write-sequence counter; incremented before each committed write.
  int _writeSeq = 0;

  /// The most recently assigned write-sequence number.
  ///
  /// All writes committed so far have a [StoredFile.writeSeq] at or below
  /// this value. A front-end with `visibilityCursor == currentWriteSeq`
  /// sees all committed writes.
  int get currentWriteSeq => _writeSeq;

  /// Allocates and returns the next write-sequence number.
  ///
  /// Call once per committed write (upload, successful CAS).
  int _nextWriteSeq() => ++_writeSeq;

  // ── File operations ────────────────────────────────────────────────────────

  /// Returns the [StoredFile] at [path], or `null` if absent.
  StoredFile? getFile(String path) => _files[path];

  /// Returns all paths whose prefix matches [prefix].
  ///
  /// The prefix is matched verbatim against stored keys.
  List<String> listPaths(String prefix) =>
      _files.keys.where((p) => p.startsWith(prefix)).toList();

  /// Unconditionally writes [bytes] to [path] under a new write-sequence.
  ///
  /// Returns the resulting [StoredFile].
  StoredFile write(String path, Uint8List bytes, {String writerDeviceId = ''}) {
    final seq = _nextWriteSeq();
    final existing = _files[path];
    final file = existing == null
        ? StoredFile(
            bytes: Uint8List.fromList(bytes),
            version: 1,
            writeSeq: seq,
            writerDeviceId: writerDeviceId,
          )
        : existing.updated(
            bytes: Uint8List.fromList(bytes),
            newWriteSeq: seq,
            writerDeviceId: writerDeviceId,
          );
    _files[path] = file;
    return file;
  }

  /// Conditionally writes [bytes] to [path] using compare-and-swap semantics.
  ///
  /// This is a **truly atomic** operation: no `await` between check and write.
  ///
  /// When [ifMatchEtag] is `null`:
  ///   - succeeds only if the file does not exist (if-none-match: * semantics).
  ///
  /// When [ifMatchEtag] is non-null:
  ///   - succeeds only if the file exists and its current ETag matches.
  ///
  /// Returns the resulting [StoredFile] on success, or `null` on failure
  /// (ETag mismatch or precondition not met).
  StoredFile? compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    String writerDeviceId = '',
  }) {
    final existing = _files[path];

    if (ifMatchEtag == null) {
      // if-none-match: * — succeed only if file does NOT exist.
      if (existing != null) return null;
      final file = write(path, newBytes, writerDeviceId: writerDeviceId);
      return file;
    }

    // ifMatchEtag provided — check that current ETag matches.
    if (existing == null) return null;
    if (existing.version.toString() != ifMatchEtag) return null;
    return write(path, newBytes, writerDeviceId: writerDeviceId);
  }

  /// Removes the file at [path]. No-op if absent.
  void delete(String path) {
    _files.remove(path);
  }

  /// Returns the current ETag for [path], or `null` if absent.
  String? getEtag(String path) {
    final file = _files[path];
    if (file == null) return null;
    return file.version.toString();
  }

  /// Returns the number of files currently stored (useful for assertions).
  int get fileCount => _files.length;

  /// Returns `true` if a file exists at [path].
  bool containsFile(String path) => _files.containsKey(path);

  /// Removes all files and resets the write-sequence counter.
  ///
  /// Useful in test tearDown to reset backend state between tests.
  void clear() {
    _files.clear();
    _writeSeq = 0;
  }

  /// Returns all [StoredFile] entries with [StoredFile.writeSeq] up to and
  /// including [seqHigh], keyed by path.
  ///
  /// Used by [CloudSemanticsAdapter.visibleWriteSeq] and
  /// [ReconciliationAgent.visibleExpectedStateFor] to determine which writes
  /// are visible to a particular front-end.
  Map<String, StoredFile> filesVisibleUpTo(int seqHigh) {
    final result = <String, StoredFile>{};
    for (final entry in _files.entries) {
      if (entry.value.writeSeq <= seqHigh) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }
}
