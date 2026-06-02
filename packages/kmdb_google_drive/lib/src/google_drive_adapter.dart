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

import 'dart:convert';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:kmdb/kmdb.dart';

import 'retry.dart';

/// The MIME type used to identify Drive folders.
const _folderMimeType = 'application/vnd.google-apps.folder';

/// The MIME type used for raw binary files (SSTables, HWM, lease).
const _binaryMimeType = 'application/octet-stream';

/// The `fields` projection used for list responses.
///
/// Requests `id`, `name`, `createdTime`, `mimeType`, and `trashed` for each
/// file — enough for filtering, duplicate-name resolution, and cache population.
const _listFields =
    'nextPageToken, files(id, name, createdTime, mimeType, trashed)';

/// Google Drive REST API sync adapter for KMDB.
///
/// Implements [SyncStorageAdapter] on top of the Google Drive v3 API using an
/// authenticated [AuthClient] from `package:googleapis_auth`.
///
/// ## Sync folder layout
///
/// ```
/// {syncRoot}/                   ← Drive folder, created on first use
///   highwater/                  ← subfolder
///     {deviceId}.hwm
///   sstables/                   ← subfolder
///     *.sst
///   .consolidation-lease
/// ```
///
/// ## ETag strategy
///
/// Drive exposes an `ETag` response header on individual file metadata
/// requests (`GET /drive/v3/files/{id}?alt=json`).  This adapter retrieves
/// it via raw HTTP so the `If-Match` CAS update also uses the same header.
/// The ETag is an opaque string from Drive's perspective; we never parse it.
///
/// ## Folder-ID caching
///
/// Folder IDs are cached in memory to avoid repeated `Files.list` calls.
/// Drive allows multiple files with the same name in a folder.  When this
/// occurs the adapter applies the deterministic resolution rule:
/// **oldest `createdTime`, tie-broken by lexicographically-lowest file ID**.
/// The cache always binds to the deterministically-chosen ID, never to
/// whichever entry happens to be listed first.
///
/// ## Conditional writes (CAS)
///
/// - **Update-if-match** (`ifMatchEtag != null`): uses a raw HTTP PATCH with
///   an `If-Match: <etag>` header.  Drive returns `412 Precondition Failed` on
///   mismatch — exactly one winner.  This IS atomic.
/// - **Create-if-absent** (`ifMatchEtag == null`): uses `Files.create`.  Drive
///   does NOT guarantee that only one concurrent creator wins — two callers can
///   each create a file with the same name and both succeed.  [providesAtomicCas]
///   returns `false` so [ConsolidationCoordinator] skips consolidation (H5).
///
/// ## Rate limiting
///
/// 429 / 503 responses are retried with exponential back-off and jitter.
/// Back-off respects the [CancellationToken] and [deadline] parameters on
/// [upload] / [compareAndSwap].  The back-off configuration can be overridden
/// via the [retryConfig] constructor parameter.
///
/// ## Thread safety
///
/// The adapter is **not** thread-safe and must be called from a single isolate.
final class GoogleDriveAdapter implements SyncStorageAdapter {
  /// Creates a [GoogleDriveAdapter].
  ///
  /// [authClient] — authenticated HTTP client from `package:googleapis_auth`.
  /// The adapter uses it both for the `googleapis` generated client and for
  /// raw HTTP requests (ETag retrieval, CAS update).
  ///
  /// [syncRoot] — name of the top-level Drive folder to create/use.
  ///
  /// [retryConfig] — back-off configuration; defaults to
  /// [RetryConfig.defaultConfig].
  GoogleDriveAdapter(
    AuthClient authClient, {
    required String syncRoot,
    RetryConfig retryConfig = RetryConfig.defaultConfig,
  }) : _authClient = authClient,
       _syncRoot = syncRoot,
       _retryConfig = retryConfig,
       _driveApi = drive.DriveApi(authClient);

  final AuthClient _authClient;
  final String _syncRoot;
  final RetryConfig _retryConfig;
  final drive.DriveApi _driveApi;

  /// In-memory cache of `{key → Drive file ID}` for resolved files/folders.
  ///
  /// Regular file entries are keyed by their full logical path, e.g.
  /// `'highwater/device-1.hwm'` or `'.consolidation-lease'`.
  ///
  /// Folder entries are keyed by `__folder__:{folderPath}` where [folderPath]
  /// is relative to [_syncRoot], e.g. `__folder__:` (empty = sync root),
  /// `__folder__:highwater`, `__folder__:sstables`.
  final Map<String, String> _idCache = {};

  // ── SyncStorageAdapter ─────────────────────────────────────────────────────

  /// Drive does NOT provide an atomic create-if-absent guarantee when using
  /// name-keyed files.  Two concurrent `Files.create` calls with the same name
  /// both succeed, producing distinct Drive files.
  ///
  /// Conditional **update** on a known file ID IS atomic (via `If-Match`), but
  /// the first-time create (when `ifMatchEtag == null`) is not.  This
  /// declaration causes [ConsolidationCoordinator] to skip consolidation,
  /// which is the correct loss-free posture under Drive (H5).
  @override
  bool get providesAtomicCas => false;

  @override
  Future<List<String>> list(String remoteDir, {String? extension}) async {
    return retryWithBackoff(
      () => _list(remoteDir, extension: extension),
      config: _retryConfig,
    );
  }

  @override
  Future<Uint8List?> download(String remotePath) async {
    return retryWithBackoff(() => _download(remotePath), config: _retryConfig);
  }

  @override
  Future<void> upload(
    String remotePath,
    Uint8List bytes, {
    CancellationToken? cancellationToken,
    DateTime? deadline,
  }) async {
    return retryWithBackoff(
      () => _upload(remotePath, bytes),
      config: _retryConfig,
      cancellationToken: cancellationToken,
      deadline: deadline,
    );
  }

  @override
  Future<void> delete(String remotePath) async {
    return retryWithBackoff(() => _delete(remotePath), config: _retryConfig);
  }

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    CancellationToken? cancellationToken,
    DateTime? deadline,
  }) async {
    if (ifMatchEtag != null) {
      // Update-if-match: atomic via If-Match header on a known file ID.
      return retryWithBackoff(
        () => _casUpdate(path, newBytes, ifMatchEtag),
        config: _retryConfig,
        cancellationToken: cancellationToken,
        deadline: deadline,
      );
    } else {
      // Create-if-absent: NOT exclusive on Drive (see providesAtomicCas).
      // We check for existence first as a best-effort guard, but this is not
      // atomic — two concurrent callers may both observe absence and both create.
      return retryWithBackoff(
        () => _casCreate(path, newBytes),
        config: _retryConfig,
        cancellationToken: cancellationToken,
        deadline: deadline,
      );
    }
  }

  @override
  Future<String?> getEtag(String remotePath) async {
    return retryWithBackoff(
      () => _getEtagViaHttp(remotePath),
      config: _retryConfig,
    );
  }

  // ── Internal implementation ────────────────────────────────────────────────

  /// Lists files in [remoteDir], optionally filtered by [extension].
  ///
  /// Resolves the Drive folder ID for [remoteDir] (cached after first call),
  /// pages through `Files.list`, and returns bare filenames (no path prefix).
  Future<List<String>> _list(String remoteDir, {String? extension}) async {
    final folderId = await _resolveFolderIdOrNull(remoteDir);
    if (folderId == null) return [];

    final results = <String>[];
    String? pageToken;

    do {
      final query =
          "'$folderId' in parents and trashed = false and mimeType != '$_folderMimeType'";
      final page = await _driveApi.files.list(
        q: query,
        pageToken: pageToken,
        pageSize: 1000,
        $fields: _listFields,
      );
      for (final file in page.files ?? []) {
        final name = file.name;
        if (name == null) continue;
        if (extension != null && !name.endsWith(extension)) continue;
        results.add(name);
      }
      pageToken = page.nextPageToken;
    } while (pageToken != null);

    return results;
  }

  /// Downloads the file at [remotePath] and returns its bytes, or `null` if
  /// absent.
  Future<Uint8List?> _download(String remotePath) async {
    final fileId = await _resolveFileIdOrNull(remotePath);
    if (fileId == null) return null;

    // Use raw HTTP GET with alt=media to download file content.
    final uri = Uri.parse(
      'https://www.googleapis.com/drive/v3/files/$fileId?alt=media',
    );
    final response = await _authClient.get(uri);

    if (response.statusCode == 404) {
      _idCache.remove(remotePath);
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Drive download failed with status ${response.statusCode} for path $remotePath',
      );
    }

    return response.bodyBytes;
  }

  /// Uploads [bytes] to [remotePath] using the resumable upload protocol.
  ///
  /// All uploads use the resumable upload protocol for uniformity (as decided
  /// in the plan — no size threshold).  If [remotePath] already exists, the
  /// file is updated in place; otherwise a new file is created.
  Future<void> _upload(String remotePath, Uint8List bytes) async {
    final existingFileId = await _resolveFileIdOrNull(remotePath);

    final parentDirPath = _dirOf(remotePath);
    final fileName = _nameOf(remotePath);

    if (existingFileId != null) {
      // Update existing file via resumable upload.
      final fileId = await _resumableUpdate(existingFileId, bytes);
      _idCache[remotePath] = fileId;
    } else {
      // Create new file via resumable upload.
      final parentId = await _ensureFolderExists(parentDirPath);
      final fileId = await _resumableCreate(fileName, parentId, bytes);
      _idCache[remotePath] = fileId;
    }
  }

  /// Deletes the file at [remotePath].  No-op if absent.
  Future<void> _delete(String remotePath) async {
    final fileId = await _resolveFileIdOrNull(remotePath);
    if (fileId == null) return; // Already absent.

    try {
      await _driveApi.files.delete(fileId);
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 404) return; // Concurrently deleted — idempotent.
      rethrow;
    } finally {
      _idCache.remove(remotePath);
    }
  }

  /// CAS update: writes [newBytes] to [path] if the current ETag matches
  /// [ifMatchEtag].
  ///
  /// Sends a raw HTTP PATCH with `If-Match: <etag>` to initiate a resumable
  /// upload session.  Drive returns `412 Precondition Failed` on ETag mismatch.
  Future<bool> _casUpdate(
    String path,
    Uint8List newBytes,
    String ifMatchEtag,
  ) async {
    final fileId = await _resolveFileIdOrNull(path);
    if (fileId == null) {
      // File does not exist — update-if-match must return false.
      return false;
    }

    // Step 1: initiate the resumable upload session with If-Match header.
    // This is the point at which Drive enforces the ETag precondition.
    final initiateUri = Uri.parse(
      'https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=resumable',
    );
    final initiateRequest = http.Request('PATCH', initiateUri)
      ..headers.addAll({
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': _binaryMimeType,
        'X-Upload-Content-Length': '${newBytes.length}',
        'If-Match': ifMatchEtag,
      })
      ..body = jsonEncode({'mimeType': _binaryMimeType});

    final initiateStreamed = await _authClient.send(initiateRequest);
    final initiateResponse = await http.Response.fromStream(initiateStreamed);

    if (initiateResponse.statusCode == 412) {
      // ETag mismatch — another writer won the race.
      return false;
    }
    if (initiateResponse.statusCode == 404) {
      _idCache.remove(path);
      return false;
    }
    if (initiateResponse.statusCode < 200 ||
        initiateResponse.statusCode >= 300) {
      throw StateError(
        'Drive CAS update initiation failed with status '
        '${initiateResponse.statusCode} for path $path',
      );
    }

    // Step 2: upload the bytes to the session URI returned in the Location header.
    final sessionLocation = initiateResponse.headers['location'];
    if (sessionLocation == null) {
      throw StateError(
        'Drive CAS update: no Location header in initiate response for $path',
      );
    }
    final sessionUri = Uri.parse(sessionLocation);

    final uploadRequest = http.Request('PUT', sessionUri)
      ..headers.addAll({
        'Content-Type': _binaryMimeType,
        'Content-Length': '${newBytes.length}',
      })
      ..bodyBytes = newBytes;

    final uploadStreamed = await _authClient.send(uploadRequest);
    final uploadResponse = await http.Response.fromStream(uploadStreamed);

    if (uploadResponse.statusCode == 200 || uploadResponse.statusCode == 201) {
      // Parse the returned file metadata to update the cache.
      try {
        final json = jsonDecode(uploadResponse.body) as Map<String, dynamic>;
        final id = json['id'] as String?;
        if (id != null) _idCache[path] = id;
      } catch (_) {
        // Non-fatal: cache miss on next access is fine.
      }
      return true;
    }

    if (uploadResponse.statusCode == 412) return false;

    throw StateError(
      'Drive CAS update upload failed with status '
      '${uploadResponse.statusCode} for path $path',
    );
  }

  /// CAS create-if-absent: creates [path] with [newBytes] if no file with
  /// that name exists in the parent folder.
  ///
  /// **Not exclusive** — two concurrent callers may both observe absence and
  /// both succeed.  The caller must tolerate this (see [providesAtomicCas]).
  Future<bool> _casCreate(String path, Uint8List newBytes) async {
    // Check existence first (best-effort, not atomic).
    final existingId = await _resolveFileIdOrNull(path);
    if (existingId != null) return false;

    final parentDirPath = _dirOf(path);
    final fileName = _nameOf(path);
    final parentId = await _ensureFolderExists(parentDirPath);

    try {
      final fileId = await _resumableCreate(fileName, parentId, newBytes);
      _idCache[path] = fileId;
      return true;
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 409) return false;
      rethrow;
    }
  }

  /// Returns the current ETag for [remotePath] via a raw HTTP GET.
  ///
  /// The Drive API returns an `ETag` response header on metadata requests.
  /// We use this value as our opaque ETag token for CAS operations.
  Future<String?> _getEtagViaHttp(String remotePath) async {
    final fileId = await _resolveFileIdOrNull(remotePath);
    if (fileId == null) return null;

    // Metadata-only GET: fields=id to minimise response payload, but we
    // capture the ETag response header.
    final uri = Uri.parse(
      'https://www.googleapis.com/drive/v3/files/$fileId?fields=id',
    );
    final response = await _authClient.get(uri);

    if (response.statusCode == 404) {
      _idCache.remove(remotePath);
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Drive getEtag failed with status ${response.statusCode} '
        'for path $remotePath',
      );
    }

    // The ETag header is the canonical version token from Drive.
    return response.headers['etag'];
  }

  // ── Resumable upload helpers ──────────────────────────────────────────────

  /// Creates a new file via resumable upload and returns its Drive file ID.
  Future<String> _resumableCreate(
    String fileName,
    String parentId,
    Uint8List bytes,
  ) async {
    // Step 1: initiate the resumable upload session.
    final initiateUri = Uri.parse(
      'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id',
    );
    final metadata = jsonEncode({
      'name': fileName,
      'parents': [parentId],
      'mimeType': _binaryMimeType,
    });
    final initiateRequest = http.Request('POST', initiateUri)
      ..headers.addAll({
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': _binaryMimeType,
        'X-Upload-Content-Length': '${bytes.length}',
      })
      ..body = metadata;

    final initiateStreamed = await _authClient.send(initiateRequest);
    final initiateResponse = await http.Response.fromStream(initiateStreamed);

    if (initiateResponse.statusCode < 200 ||
        initiateResponse.statusCode >= 300) {
      throw StateError(
        'Drive resumable create initiation failed with status '
        '${initiateResponse.statusCode} for file $fileName',
      );
    }

    final sessionLocation = initiateResponse.headers['location'];
    if (sessionLocation == null) {
      throw StateError(
        'Drive resumable create: no Location header in initiate response '
        'for file $fileName',
      );
    }

    // Step 2: upload the bytes.
    return _uploadToSession(sessionLocation, bytes);
  }

  /// Updates an existing file via resumable upload and returns its Drive file ID.
  Future<String> _resumableUpdate(String fileId, Uint8List bytes) async {
    // Step 1: initiate the resumable update session.
    final initiateUri = Uri.parse(
      'https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=resumable&fields=id',
    );
    final initiateRequest = http.Request('PATCH', initiateUri)
      ..headers.addAll({
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': _binaryMimeType,
        'X-Upload-Content-Length': '${bytes.length}',
      })
      ..body = jsonEncode({'mimeType': _binaryMimeType});

    final initiateStreamed = await _authClient.send(initiateRequest);
    final initiateResponse = await http.Response.fromStream(initiateStreamed);

    if (initiateResponse.statusCode < 200 ||
        initiateResponse.statusCode >= 300) {
      throw StateError(
        'Drive resumable update initiation failed with status '
        '${initiateResponse.statusCode} for file ID $fileId',
      );
    }

    final sessionLocation = initiateResponse.headers['location'];
    if (sessionLocation == null) {
      throw StateError(
        'Drive resumable update: no Location header in initiate response '
        'for file ID $fileId',
      );
    }

    // Step 2: upload the bytes.
    return _uploadToSession(sessionLocation, bytes);
  }

  /// Uploads [bytes] to [sessionLocation] and returns the Drive file ID from
  /// the response metadata.
  Future<String> _uploadToSession(
    String sessionLocation,
    Uint8List bytes,
  ) async {
    final sessionUri = Uri.parse(sessionLocation);
    final uploadRequest = http.Request('PUT', sessionUri)
      ..headers.addAll({
        'Content-Type': _binaryMimeType,
        'Content-Length': '${bytes.length}',
      })
      ..bodyBytes = bytes;

    final uploadStreamed = await _authClient.send(uploadRequest);
    final uploadResponse = await http.Response.fromStream(uploadStreamed);

    if (uploadResponse.statusCode == 200 || uploadResponse.statusCode == 201) {
      final json = jsonDecode(uploadResponse.body) as Map<String, dynamic>;
      final id = json['id'] as String?;
      if (id == null) {
        throw StateError(
          'Drive upload response missing file ID: ${uploadResponse.body}',
        );
      }
      return id;
    }

    throw StateError(
      'Drive upload to session failed with status '
      '${uploadResponse.statusCode}: ${uploadResponse.body}',
    );
  }

  // ── Folder and file ID resolution ─────────────────────────────────────────

  /// Returns the Drive file ID for [remotePath], or `null` if absent.
  ///
  /// [remotePath] is a logical path like `'sstables/device-1.sst'` or
  /// `'.consolidation-lease'`.  The method splits it into a directory segment
  /// and a filename, resolves the directory's folder ID, and then searches for
  /// the file by name.
  ///
  /// When multiple files share the same name (Drive allows this), the
  /// deterministic rule is applied: oldest `createdTime`, tie-broken by
  /// lexicographically-lowest file ID.
  Future<String?> _resolveFileIdOrNull(String remotePath) async {
    // Check the cache first.
    if (_idCache.containsKey(remotePath)) return _idCache[remotePath];

    final dirPath = _dirOf(remotePath);
    final fileName = _nameOf(remotePath);

    final folderId = await _resolveFolderIdOrNull(dirPath);
    if (folderId == null) return null;

    final files = await _listByName(folderId, fileName, isFolder: false);
    if (files.isEmpty) return null;

    // Apply deterministic resolution: oldest createdTime, tie-break by lowest ID.
    final chosen = _deterministic(files);
    _idCache[remotePath] = chosen.id!;
    return chosen.id;
  }

  /// Resolves [folderPath] to a Drive folder ID, or `null` if the folder does
  /// not exist.
  ///
  /// [folderPath] is relative to the sync root: `''` for the root itself,
  /// `'highwater'`, `'sstables'`.
  Future<String?> _resolveFolderIdOrNull(String folderPath) async {
    final cacheKey = _folderCacheKey(folderPath);
    if (_idCache.containsKey(cacheKey)) return _idCache[cacheKey];

    if (folderPath.isEmpty) {
      // Resolve the sync root itself (child of 'root').
      final roots = await _listByName(null, _syncRoot, isFolder: true);
      if (roots.isEmpty) return null;
      final id = _deterministic(roots).id!;
      _idCache[cacheKey] = id;
      return id;
    }

    // Walk the path segments from the sync root.
    final segments = folderPath.split('/').where((s) => s.isNotEmpty).toList();
    String? parentId = await _resolveFolderIdOrNull('');
    if (parentId == null) return null;

    var currentPath = '';
    for (final segment in segments) {
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      final segCacheKey = _folderCacheKey(currentPath);
      if (_idCache.containsKey(segCacheKey)) {
        parentId = _idCache[segCacheKey];
        continue;
      }
      final folders = await _listByName(parentId, segment, isFolder: true);
      if (folders.isEmpty) return null;
      final id = _deterministic(folders).id!;
      _idCache[segCacheKey] = id;
      parentId = id;
    }
    return parentId;
  }

  /// Ensures the folder at [folderPath] (relative to the sync root) exists,
  /// creating it if necessary.  Returns the Drive folder ID.
  ///
  /// If multiple folders with the same name already exist (racy lazy-create),
  /// the deterministic rule (oldest `createdTime`, lowest file ID) is applied.
  Future<String> _ensureFolderExists(String folderPath) async {
    final cacheKey = _folderCacheKey(folderPath);
    if (_idCache.containsKey(cacheKey)) return _idCache[cacheKey]!;

    if (folderPath.isEmpty) {
      // Ensure/create the sync root folder (child of Drive 'root').
      final roots = await _listByName(null, _syncRoot, isFolder: true);
      if (roots.isNotEmpty) {
        final id = _deterministic(roots).id!;
        _idCache[cacheKey] = id;
        return id;
      }
      // Create the root folder (no parents → lands in My Drive root).
      final created = await _driveApi.files.create(
        drive.File()
          ..name = _syncRoot
          ..mimeType = _folderMimeType,
        $fields: 'id',
      );
      final id = created.id!;
      _idCache[cacheKey] = id;
      return id;
    }

    // Walk segments, creating each lazily.
    final segments = folderPath.split('/').where((s) => s.isNotEmpty).toList();
    String parentId = await _ensureFolderExists('');

    var currentPath = '';
    for (final segment in segments) {
      currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
      final segCacheKey = _folderCacheKey(currentPath);

      if (_idCache.containsKey(segCacheKey)) {
        parentId = _idCache[segCacheKey]!;
        continue;
      }

      final folders = await _listByName(parentId, segment, isFolder: true);
      if (folders.isNotEmpty) {
        final id = _deterministic(folders).id!;
        _idCache[segCacheKey] = id;
        parentId = id;
        continue;
      }

      // Create the subfolder.
      final created = await _driveApi.files.create(
        drive.File()
          ..name = segment
          ..parents = [parentId]
          ..mimeType = _folderMimeType,
        $fields: 'id',
      );
      final id = created.id!;
      _idCache[segCacheKey] = id;
      parentId = id;
    }

    _idCache[cacheKey] = parentId;
    return parentId;
  }

  /// Lists Drive files/folders with [name] under [parentId] (or at the user's
  /// My Drive root if [parentId] is `null`).
  Future<List<drive.File>> _listByName(
    String? parentId,
    String name, {
    required bool isFolder,
  }) async {
    final escapedName = name.replaceAll("'", "\\'");
    final mimeFilter = isFolder
        ? "mimeType = '$_folderMimeType'"
        : "mimeType != '$_folderMimeType'";
    final parentFilter = parentId != null
        ? "'$parentId' in parents"
        : "'root' in parents";
    final q =
        "$parentFilter and name = '$escapedName' and trashed = false and $mimeFilter";

    final results = <drive.File>[];
    String? pageToken;
    do {
      final page = await _driveApi.files.list(
        q: q,
        pageToken: pageToken,
        pageSize: 10,
        $fields: _listFields,
      );
      results.addAll(page.files ?? []);
      pageToken = page.nextPageToken;
    } while (pageToken != null);
    return results;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Returns the folder cache key for [folderPath].
  static String _folderCacheKey(String folderPath) => '__folder__:$folderPath';

  /// Applies the deterministic file-selection rule to [files]:
  /// choose the one with the oldest `createdTime`; on a tie, the
  /// lexicographically-lowest file ID.
  ///
  /// This rule is applied consistently whenever Drive returns multiple files
  /// with the same name in the same folder.  Binding the cache to this
  /// deterministically-chosen file prevents different devices from operating
  /// on different same-named files.
  static drive.File _deterministic(List<drive.File> files) {
    assert(files.isNotEmpty, '_deterministic called with empty list');
    return files.reduce((a, b) {
      final timeA = a.createdTime ?? DateTime.fromMillisecondsSinceEpoch(0);
      final timeB = b.createdTime ?? DateTime.fromMillisecondsSinceEpoch(0);
      final cmp = timeA.compareTo(timeB);
      if (cmp != 0) return cmp < 0 ? a : b;
      // Tie-break: lexicographically-lowest file ID.
      return (a.id ?? '').compareTo(b.id ?? '') <= 0 ? a : b;
    });
  }

  /// Returns the directory component of [path].
  ///
  /// `'sstables/foo.sst'` → `'sstables'`
  /// `'.consolidation-lease'` → `''`
  static String _dirOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  /// Returns the file name component of [path].
  ///
  /// `'sstables/foo.sst'` → `'foo.sst'`
  /// `'.consolidation-lease'` → `'.consolidation-lease'`
  static String _nameOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}
