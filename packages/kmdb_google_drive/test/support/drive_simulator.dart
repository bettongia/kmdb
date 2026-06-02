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

import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:kmdb/kmdb_test_cloud_support.dart'
    show CloudProfile, QuotaProfile;
import 'package:kmdb/kmdb.dart' show SyncContext, SyncStorageAdapter;
import 'package:kmdb_google_drive/kmdb_google_drive.dart'
    show GoogleDriveAdapter, kGoogleDriveProfile;
import 'package:kmdb_harness/kmdb_harness.dart' show QuotaAwareAdapter;

// ── Simulator file store ───────────────────────────────────────────────────

/// A file entry in the Drive simulator's in-memory store.
final class SimFile {
  /// Creates a [SimFile].
  SimFile({
    required this.id,
    required this.name,
    required this.parentId,
    required this.content,
    required this.mimeType,
    required this.createdTime,
    required this.etag,
  });

  /// Drive file ID.
  final String id;

  /// File name (not unique within a folder).
  final String name;

  /// Parent folder ID; `null` for files at the My Drive root.
  final String? parentId;

  /// MIME type.
  final String mimeType;

  /// Creation timestamp.
  final DateTime createdTime;

  /// File content bytes.
  Uint8List content;

  /// Current ETag (changes on every update).
  String etag;

  /// Whether this entry represents a Drive folder.
  bool get isFolder => mimeType == 'application/vnd.google-apps.folder';

  bool _deleted = false;

  /// Whether this file has been deleted.
  bool get isDeleted => _deleted;

  /// Marks this file as deleted (soft-delete for test assertions).
  void markDeleted() => _deleted = true;
}

/// In-memory behavioural Drive API simulator.
///
/// Implements the Google Drive v3 REST API as a fake [http.Client].  The real
/// [GoogleDriveAdapter] code runs against this client unchanged, providing full
/// adapter coverage without network access.
///
/// ## Behaviours modelled
///
/// - `Files.list` — parent filtering, name filtering, trashed filtering,
///   pagination.
/// - `Files.get` — metadata and media download.
/// - `Files.create` — folder creation (metadata-only) and resumable upload.
/// - `Files.update` — resumable upload; with `If-Match` CAS.
/// - `Files.delete`
/// - Metadata GET with `ETag` response header.
/// - Resumable upload sessions (initiate → PUT).
/// - **Duplicate names** — Drive allows multiple files with the same name;
///   both create operations succeed, matching real Drive behaviour.
/// - **Non-atomic create-if-absent** — reflects [kGoogleDriveProfile]
///   `atomicConditionalCreate == false`.
/// - **Atomic update-if-match** — `If-Match` on a known file ID; 412 on mismatch.
/// - **Rate limiting** — optional 429 injection controlled by [QuotaProfile].
final class DriveSimulator extends http.BaseClient {
  /// Creates a [DriveSimulator].
  ///
  /// [profile] — the [CloudProfile] used to configure the simulator.
  ///
  /// [enableRateLimiting] — if `true`, 429 responses are injected once the
  /// simulated ops/minute quota is exceeded.  Defaults to `false`.
  DriveSimulator({
    CloudProfile profile = kGoogleDriveProfile,
    bool enableRateLimiting = false,
  }) : _profile = profile,
       _enableRateLimiting = enableRateLimiting;

  final CloudProfile _profile;
  final bool _enableRateLimiting;

  // ── Internal state ─────────────────────────────────────────────────────

  final Map<String, SimFile> _files = {}; // id → SimFile
  int _nextId = 1;
  int _opCount = 0;
  final Stopwatch _minuteStart = Stopwatch()..start();

  // Active resumable sessions: sessionToken → session state.
  final Map<String, _ResumableSession> _sessions = {};

  // ── Public introspection ───────────────────────────────────────────────

  /// Number of non-deleted files in the simulator.
  int get fileCount => _files.values.where((f) => !f.isDeleted).length;

  /// Returns a snapshot of all non-deleted files (for test assertions).
  Iterable<SimFile> get allFiles => _files.values.where((f) => !f.isDeleted);

  // ── http.BaseClient interface ───────────────────────────────────────────

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _opCount++;

    // Rate limit injection.
    if (_enableRateLimiting) {
      final maxOps = _profile.quota.maxOpsPerMinute;
      if (maxOps != null) {
        if (_minuteStart.elapsed > const Duration(minutes: 1)) {
          _opCount = 1;
          _minuteStart.reset();
        }
        if (_opCount > maxOps) {
          return _textResponse(
            429,
            '{"error":{"code":429,"message":"Rate limit exceeded"}}',
          );
        }
      }
    }

    final uri = request.url;
    final method = request.method.toUpperCase();
    final path = uri.path;
    final query = uri.queryParameters;

    // ── Resumable upload data transfer (PUT to session URI) ─────────────
    if (method == 'PUT' && path.startsWith('/sim-resumable/')) {
      return _handleResumableUpload(request, path);
    }

    // ── Resumable upload initiation ─────────────────────────────────────
    if (query['uploadType'] == 'resumable') {
      return _handleResumableInitiate(request, method, path, query);
    }

    // ── Standard REST operations ─────────────────────────────────────────
    final fileIdRegex = RegExp(r'^/drive/v3/files/([^/?]+)$');
    final fileIdMatch = fileIdRegex.firstMatch(path);

    if (method == 'GET' && path == '/drive/v3/files') {
      return _handleListFiles(query);
    }
    if (method == 'GET' && fileIdMatch != null) {
      final fileId = fileIdMatch.group(1)!;
      return query['alt'] == 'media'
          ? _handleDownloadFile(fileId)
          : _handleGetMetadata(fileId);
    }
    if (method == 'POST' && path == '/drive/v3/files') {
      return _handleCreateMetadataOnly(request);
    }
    if (method == 'DELETE' && fileIdMatch != null) {
      return _handleDelete(fileIdMatch.group(1)!);
    }

    return _textResponse(
      404,
      '{"error":{"code":404,"message":"Not found: $path"}}',
    );
  }

  // ── Request handlers ────────────────────────────────────────────────────

  Future<http.StreamedResponse> _handleListFiles(
    Map<String, String> query,
  ) async {
    final q = query['q'] ?? '';
    final pageSize = int.tryParse(query['pageSize'] ?? '100') ?? 100;

    final matching =
        _files.values.where((f) => !f.isDeleted && _matchesQuery(f, q)).toList()
          ..sort((a, b) => a.id.compareTo(b.id));

    final page = matching.take(pageSize).toList();
    return _jsonResponse({'files': page.map(_fileToJson).toList()});
  }

  Future<http.StreamedResponse> _handleDownloadFile(String fileId) async {
    final file = _files[fileId];
    if (file == null || file.isDeleted) {
      return _notFound();
    }
    return http.StreamedResponse(
      Stream.value(file.content),
      200,
      headers: {
        'content-type': file.mimeType,
        'content-length': '${file.content.length}',
        'etag': '"${file.etag}"',
      },
    );
  }

  Future<http.StreamedResponse> _handleGetMetadata(String fileId) async {
    final file = _files[fileId];
    if (file == null || file.isDeleted) return _notFound();
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(_fileToJson(file)))),
      200,
      headers: {
        'content-type': 'application/json; charset=UTF-8',
        'etag': '"${file.etag}"',
      },
    );
  }

  Future<http.StreamedResponse> _handleCreateMetadataOnly(
    http.BaseRequest request,
  ) async {
    final meta = await _bodyAsJson(request);
    final name = meta['name'] as String? ?? '';
    final mimeType = meta['mimeType'] as String? ?? 'application/octet-stream';
    final parents = (meta['parents'] as List?)?.cast<String>();
    final parentId = parents?.firstOrNull;

    final id = _newId();
    final etag = _computeEtag(id, Uint8List(0));
    _files[id] = SimFile(
      id: id,
      name: name,
      parentId: parentId,
      content: Uint8List(0),
      mimeType: mimeType,
      createdTime: DateTime.now(),
      etag: etag,
    );
    return _jsonResponse({'id': id, 'name': name});
  }

  Future<http.StreamedResponse> _handleDelete(String fileId) async {
    final file = _files[fileId];
    if (file == null || file.isDeleted) return _notFound();
    file.markDeleted();
    return _textResponse(204, '');
  }

  Future<http.StreamedResponse> _handleResumableInitiate(
    http.BaseRequest request,
    String method,
    String path,
    Map<String, String> query,
  ) async {
    final ifMatchRaw = request.headers['if-match'];
    final ifMatchEtag = ifMatchRaw?.replaceAll('"', '');

    // Determine if this is an update (path has file ID) or a create.
    final updateMatch = RegExp(
      r'^/upload/drive/v3/files/([^/?]+)$',
    ).firstMatch(path);
    final existingFileId = updateMatch?.group(1);

    // Validate If-Match for updates.
    if (ifMatchEtag != null && existingFileId != null) {
      final existing = _files[existingFileId];
      if (existing == null || existing.isDeleted) return _notFound();
      if (existing.etag != ifMatchEtag) {
        return _textResponse(
          412,
          '{"error":{"code":412,"message":"Precondition Failed"}}',
        );
      }
    }

    // Parse request metadata.
    Map<String, dynamic> meta = {};
    try {
      final body = await _bodyAsString(request);
      if (body.isNotEmpty) meta = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {}

    final token = 'session-${_newId()}';
    _sessions[token] = _ResumableSession(
      existingFileId: existingFileId,
      parentId: (meta['parents'] as List?)?.cast<String>().firstOrNull,
      name: meta['name'] as String?,
      mimeType: meta['mimeType'] as String? ?? 'application/octet-stream',
      ifMatchEtag: ifMatchEtag,
    );

    final sessionUri = 'https://www.googleapis.com/sim-resumable/$token';
    return http.StreamedResponse(
      Stream.value(const <int>[]),
      200,
      headers: {'location': sessionUri},
    );
  }

  Future<http.StreamedResponse> _handleResumableUpload(
    http.BaseRequest request,
    String path,
  ) async {
    final token = path.replaceFirst('/sim-resumable/', '');
    final session = _sessions.remove(token);
    if (session == null) {
      return _textResponse(
        404,
        '{"error":{"code":404,"message":"Session not found"}}',
      );
    }

    final bytes = await _bodyAsBytes(request);
    final String fileId;
    final String etag;

    if (session.existingFileId != null) {
      // Update existing file.
      final existing = _files[session.existingFileId!];
      if (existing == null || existing.isDeleted) return _notFound();
      if (session.ifMatchEtag != null && existing.etag != session.ifMatchEtag) {
        return _textResponse(412, '{"error":{"code":412}}');
      }
      fileId = session.existingFileId!;
      etag = _computeEtag(fileId, bytes);
      existing.content = bytes;
      existing.etag = etag;
    } else {
      // Create new file.
      fileId = _newId();
      etag = _computeEtag(fileId, bytes);
      _files[fileId] = SimFile(
        id: fileId,
        name: session.name ?? '',
        parentId: session.parentId,
        content: bytes,
        mimeType: session.mimeType,
        createdTime: DateTime.now(),
        etag: etag,
      );
    }

    return _jsonResponse({'id': fileId, 'etag': '"$etag"'});
  }

  // ── Query parsing ──────────────────────────────────────────────────────

  /// Matches [file] against a simplified Drive query expression.
  ///
  /// Supports: `'id' in parents`, `'root' in parents`, `name = 'x'`,
  /// `trashed = false/true`, `mimeType = 'x'`, `mimeType != 'x'`,
  /// and `and` conjunctions.
  bool _matchesQuery(SimFile file, String query) {
    final clauses = query.split(' and ').map((c) => c.trim());
    return clauses.every((clause) => _matchesClause(file, clause));
  }

  bool _matchesClause(SimFile file, String clause) {
    if (clause.isEmpty) return true;

    // `'id' in parents` — specific parent ID.
    final parentMatch = RegExp(r"'([^']+)' in parents").firstMatch(clause);
    if (parentMatch != null) {
      final parentId = parentMatch.group(1)!;
      if (parentId == 'root') return file.parentId == null;
      return file.parentId == parentId;
    }

    // `name = 'x'`
    final nameEq = RegExp(r"name\s*=\s*'([^']*)'").firstMatch(clause);
    if (nameEq != null) return file.name == nameEq.group(1);

    // `trashed = false/true`
    if (clause.contains('trashed = false')) return !file.isDeleted;
    if (clause.contains('trashed = true')) return file.isDeleted;

    // `mimeType = 'x'`
    final mimeEq = RegExp(r"mimeType\s*=\s*'([^']*)'").firstMatch(clause);
    if (mimeEq != null) return file.mimeType == mimeEq.group(1);

    // `mimeType != 'x'`
    final mimeNe = RegExp(r"mimeType\s*!=\s*'([^']*)'").firstMatch(clause);
    if (mimeNe != null) return file.mimeType != mimeNe.group(1);

    return true; // Unknown clause — permissive for test scenarios.
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  String _newId() => 'sim-${_nextId++}';

  /// Computes an ETag for [content].
  ///
  /// The simulator uses a simple content hash.  Real Drive ETags are
  /// server-assigned version tokens (not content hashes), but a content hash
  /// satisfies the conformance requirements:
  /// - stable for same content (same bytes → same ETag)
  /// - changes when content changes
  /// - unique enough for CAS correctness in deterministic test scenarios
  ///
  /// Note: for distinguishing two files with *identical* bytes (where Drive
  /// would assign different ETags), the simulator is slightly more optimistic
  /// than real Drive.  This is acceptable for test coverage purposes.
  static String _computeEtag(String id, Uint8List content) {
    // Content hash: deterministic for same bytes, changes on modification.
    var h = 0x811c9dc5; // FNV-1a offset basis.
    for (final b in content) {
      h ^= b;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }

  static Map<String, dynamic> _fileToJson(SimFile file) => {
    'id': file.id,
    'name': file.name,
    'mimeType': file.mimeType,
    'createdTime': file.createdTime.toIso8601String(),
    'trashed': file.isDeleted,
  };

  http.StreamedResponse _jsonResponse(Object body) => http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(body))),
    200,
    headers: {'content-type': 'application/json; charset=UTF-8'},
  );

  http.StreamedResponse _textResponse(int status, String body) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        status,
        headers: {'content-type': 'application/json; charset=UTF-8'},
      );

  http.StreamedResponse _notFound() =>
      _textResponse(404, '{"error":{"code":404,"message":"File not found"}}');

  Future<String> _bodyAsString(http.BaseRequest request) async {
    if (request is http.Request) return request.body;
    final chunks = await request.finalize().toList();
    return utf8.decode(chunks.expand((b) => b).toList());
  }

  Future<Uint8List> _bodyAsBytes(http.BaseRequest request) async {
    if (request is http.Request) return request.bodyBytes;
    final chunks = await request.finalize().toList();
    return Uint8List.fromList(chunks.expand((b) => b).toList());
  }

  Future<Map<String, dynamic>> _bodyAsJson(http.BaseRequest request) async {
    final str = await _bodyAsString(request);
    if (str.isEmpty) return {};
    return jsonDecode(str) as Map<String, dynamic>;
  }
}

/// Internal state for a resumable upload session.
final class _ResumableSession {
  const _ResumableSession({
    this.existingFileId,
    this.parentId,
    this.name,
    required this.mimeType,
    this.ifMatchEtag,
  });

  final String? existingFileId;
  final String? parentId;
  final String? name;
  final String mimeType;
  final String? ifMatchEtag;
}

// ── SimulatorQuotaAdapter ──────────────────────────────────────────────────

/// Wraps a [GoogleDriveAdapter] (over a [DriveSimulator]) and adds
/// [QuotaAwareAdapter] for `kmdb_harness` integration.
///
/// The [safeOperationThreshold] is derived from the [CloudProfile]'s
/// `quota.maxOpsPerMinute` — allowing 10 minutes of operations at that rate.
///
/// Lives in the **test tree** and depends on `kmdb_harness`.
/// The production [GoogleDriveAdapter] does NOT implement [QuotaAwareAdapter].
final class SimulatorQuotaAdapter
    implements SyncStorageAdapter, QuotaAwareAdapter {
  /// Creates a [SimulatorQuotaAdapter].
  ///
  /// [adapter] — the underlying [GoogleDriveAdapter] to delegate to.
  /// [quotaProfile] — the quota profile from [CloudProfile].
  SimulatorQuotaAdapter({
    required GoogleDriveAdapter adapter,
    required QuotaProfile quotaProfile,
  }) : _adapter = adapter,
       _quotaProfile = quotaProfile;

  final GoogleDriveAdapter _adapter;
  final QuotaProfile _quotaProfile;

  @override
  int get safeOperationThreshold {
    final maxOps = _quotaProfile.maxOpsPerMinute;
    if (maxOps == null) return 1000000;
    return maxOps * 10; // Allow 10 min of ops at the declared rate.
  }

  // ── Delegate all SyncStorageAdapter methods ──────────────────────────

  @override
  bool get providesAtomicCas => _adapter.providesAtomicCas;

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) => _adapter.list(remoteDir, extension: extension, ctx: ctx);

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) =>
      _adapter.download(remotePath, ctx: ctx);

  @override
  Future<void> upload(String remotePath, Uint8List bytes, {SyncContext? ctx}) =>
      _adapter.upload(remotePath, bytes, ctx: ctx);

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) =>
      _adapter.delete(remotePath, ctx: ctx);

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) => _adapter.compareAndSwap(
    path,
    newBytes,
    ifMatchEtag: ifMatchEtag,
    ctx: ctx,
  );

  @override
  Future<String?> getEtag(String remotePath, {SyncContext? ctx}) =>
      _adapter.getEtag(remotePath, ctx: ctx);
}

// ── Factory helpers ────────────────────────────────────────────────────────

/// Creates a [GoogleDriveAdapter] wired to [simulator] via a fake [AuthClient].
///
/// All HTTP traffic from the adapter (both the generated `googleapis` `DriveApi`
/// client and raw `_authClient.send(...)` calls) is routed through
/// [simulator] rather than the network.
GoogleDriveAdapter adapterOverSimulator(
  DriveSimulator simulator, {
  String syncRoot = '__sim_test__',
}) {
  final fakeClient = _SimulatorAuthClient(simulator);
  return GoogleDriveAdapter(fakeClient, syncRoot: syncRoot);
}

/// A fake [AuthClient] that routes all HTTP traffic through a [DriveSimulator].
///
/// This is the seam below `googleapis` and raw HTTP requests: both the
/// generated `DriveApi` client and direct `_authClient.send(...)` calls in
/// [GoogleDriveAdapter] are intercepted here.
final class _SimulatorAuthClient extends http.BaseClient implements AuthClient {
  _SimulatorAuthClient(this._simulator);

  final DriveSimulator _simulator;

  @override
  AccessCredentials get credentials => AccessCredentials(
    AccessToken(
      'Bearer',
      'fake-token',
      DateTime.now().add(const Duration(hours: 1)).toUtc(),
    ),
    null,
    [],
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _simulator.send(request);
}
