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

import '../sync_context.dart';
import '../sync_storage_adapter.dart';
import 'sync_artifact_class.dart';
import 'sync_auth_envelope.dart';
import 'sync_authenticator.dart';

/// A [SyncStorageAdapter] decorator that transparently authenticates every
/// artefact against an untrusted provider (0.10.01 WI-4 T1, design
/// question Q2).
///
/// Wraps any inner [SyncStorageAdapter] — precedent: `QuotaAwareAdapter` /
/// `GatedSyncAdapter` — and is constructed once at the adapter-wiring point
/// (e.g. `kmdb_cli`'s `adapterFor`). Because [SyncEngine],
/// [ConsolidationCoordinator], and [HighwaterMark] all reach the sync folder
/// exclusively through the [SyncStorageAdapter] they were constructed with,
/// wrapping the adapter once at construction time covers every one of their
/// call sites automatically — no changes are needed inside those classes to
/// apply the envelope; they only need to react to the [SyncAuthException]
/// this decorator throws (see `docs/spec/32_sync_authentication.md`'s
/// per-site rejection-policy table).
///
/// ## Method coverage
///
/// - [upload] — prepends the envelope via [SyncAuthEnvelope.wrap].
/// - [download] — verifies and strips via [SyncAuthEnvelope.unwrap]; throws
///   [SyncAuthException] on a bad or missing MAC. This is distinct from a
///   `null` return, which still means "file removed between list and
///   download" exactly as it does on the undecorated adapter.
/// - [compareAndSwap] — envelopes `newBytes` before delegating (this is how
///   the consolidation lease gets authenticated).
/// - [getEtag] — delegates unchanged. The stored object is the *enveloped*
///   bytes, so the ETag already reflects envelope content — no double
///   accounting needed.
/// - [list] — delegates unchanged. **Filenames are never enveloped** — only
///   file *contents* are. This is what keeps `SstableInfo.parse` on a remote
///   listing unaffected by sync authentication.
///
/// ## Artefact classification
///
/// Classifies a remote path into one of the three [SyncArtifactClass]
/// values this decorator ever sees, by suffix — every path this class is
/// ever asked to process is constructed internally by [SyncEngine] /
/// [ConsolidationCoordinator] / [HighwaterMark] using forward-slash-only
/// logical paths (never OS paths), so string-suffix matching is exact and
/// correct here, unlike a local filesystem path:
///
/// - `*.sst` → [SyncArtifactClass.sstable]
/// - `*.hwm` → [SyncArtifactClass.hwm]
/// - `*.consolidation-lease` → [SyncArtifactClass.lease]
///
/// The three vault artefact classes are never classified here — vault sync
/// uses raw `dart:io` `File` I/O and never reaches this decorator; see
/// `LocalDirectoryVaultAdapter`'s manual threading instead.
final class SyncAuthenticatingAdapter implements SyncStorageAdapter {
  /// Creates a [SyncAuthenticatingAdapter] wrapping [_delegate], using
  /// [_authenticator] to compute and verify every artefact's MAC.
  SyncAuthenticatingAdapter(this._delegate, this._authenticator);

  final SyncStorageAdapter _delegate;
  final SyncAuthenticator _authenticator;

  @override
  Future<List<String>> list(
    String remoteDir, {
    String? extension,
    SyncContext? ctx,
  }) => _delegate.list(remoteDir, extension: extension, ctx: ctx);

  @override
  Future<Uint8List?> download(String remotePath, {SyncContext? ctx}) async {
    final bytes = await _delegate.download(remotePath, ctx: ctx);
    if (bytes == null) return null; // removed between list and download
    return SyncAuthEnvelope.unwrap(
      bytes,
      _authenticator,
      artifactClass: classifyPath(remotePath),
      relativePath: remotePath,
    );
  }

  @override
  Future<void> upload(
    String remotePath,
    Uint8List bytes, {
    SyncContext? ctx,
  }) async {
    final enveloped = await SyncAuthEnvelope.wrap(
      bytes,
      _authenticator,
      artifactClass: classifyPath(remotePath),
      relativePath: remotePath,
    );
    await _delegate.upload(remotePath, enveloped, ctx: ctx);
  }

  @override
  Future<void> delete(String remotePath, {SyncContext? ctx}) =>
      _delegate.delete(remotePath, ctx: ctx);

  @override
  Future<bool> compareAndSwap(
    String path,
    Uint8List newBytes, {
    String? ifMatchEtag,
    SyncContext? ctx,
  }) async {
    final enveloped = await SyncAuthEnvelope.wrap(
      newBytes,
      _authenticator,
      artifactClass: classifyPath(path),
      relativePath: path,
    );
    return _delegate.compareAndSwap(
      path,
      enveloped,
      ifMatchEtag: ifMatchEtag,
      ctx: ctx,
    );
  }

  @override
  Future<String?> getEtag(String path, {SyncContext? ctx}) =>
      _delegate.getEtag(path, ctx: ctx);

  @override
  bool get providesAtomicCas => _delegate.providesAtomicCas;

  /// Classifies [path] into the [SyncArtifactClass] this decorator applies —
  /// see the class doc comment for the exhaustive suffix rules.
  ///
  /// Throws [ArgumentError] for a path shape this decorator has never been
  /// asked to authenticate. This is defensive: every real call site
  /// (`SyncEngine`, `ConsolidationCoordinator`, `HighwaterMark`) only ever
  /// constructs `.sst`, `.hwm`, or `.consolidation-lease` paths, so reaching
  /// this branch indicates a new, unaccounted-for artefact shape was wired
  /// through this adapter without updating its classification — silently
  /// guessing a class would be a worse failure mode than a loud error.
  static SyncArtifactClass classifyPath(String path) {
    if (path.endsWith('.sst')) return SyncArtifactClass.sstable;
    if (path.endsWith('.hwm')) return SyncArtifactClass.hwm;
    if (path.endsWith('.consolidation-lease')) return SyncArtifactClass.lease;
    throw ArgumentError.value(
      path,
      'path',
      'SyncAuthenticatingAdapter cannot classify this remote path into a '
          'known SyncArtifactClass',
    );
  }
}
