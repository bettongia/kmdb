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

// coverage:ignore-file
// This file is compiled only when `dart.library.js_interop` is available
// (i.e. on web targets). It must not import `dart:io`. Coverage is measured
// via the Chrome test lane (`make cicd_web`), not the VM `dart test` run
// `make coverage` instruments — see docs/spec/28_release_checklist.md.

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'sync_artifact_class.dart';
import 'sync_authenticator.dart';

/// Web [SyncAuthenticator] backed by a **non-extractable** WebCrypto
/// `CryptoKey`, persisted across sessions in IndexedDB (0.10.01 WI-4 Q4).
///
/// ## Why not [DefaultSyncAuthenticator] on web
///
/// [DefaultSyncAuthenticator] holds the sync-set root key as a plain
/// [Uint8List] in Dart-visible heap memory — on native hosts that is no
/// different from any other in-process secret, but a browser tab's script
/// heap is a uniquely hostile environment for long-lived key material: any
/// XSS vulnerability in the hosting web app (or a malicious/compromised
/// browser extension with content-script access) can read arbitrary
/// JavaScript-visible memory, including a Dart `Uint8List` compiled to a
/// JS `Uint8Array`. [WebSyncAuthenticator] instead imports the root key
/// into the browser's Web Crypto subsystem as a **non-extractable**
/// `CryptoKey` — once imported, the raw key bytes can never be read back
/// out by any script, including this one, even via `SubtleCrypto.exportKey`.
///
/// ## Import-only (this release)
///
/// Because a non-extractable key can never be exported, a device that
/// *imports* a key this way can never print a pairing code for a second
/// device — only a device holding the raw key bytes can do that. This makes
/// web an **import-only** platform for sync authentication today:
/// [importKey] is the only construction path. A future `generateKey`
/// factory — not implemented in this release — would accept an
/// `extractable` policy parameter (default `false`, matching this
/// implementation's constraint); "show pairing code" UX would then be
/// gated on [isExtractable] being `true`, which is structurally impossible
/// for any key created via [importKey] today. This is a deliberate,
/// documented forward-compat seam, not an oversight — see the plan's Q4
/// design record.
///
/// ## Persistence
///
/// A non-extractable `CryptoKey` is still structured-cloneable — the
/// browser can store the *opaque key handle* (never the underlying bytes)
/// in IndexedDB and hand back a live, usable `CryptoKey` on a later page
/// load. [persist] and [loadPersisted] do exactly this, keyed by a
/// caller-supplied [keyId] (analogous to `kmdb_cli`'s `dbScopedSecretKey`
/// scoping — the host application chooses an identifier that scopes the key
/// to one remote).
///
/// ## Derivation
///
/// [importKey] imports the raw root key bytes as an HKDF *base key*
/// (`usages: ['deriveKey']`), immediately discarding the Dart-visible copy.
/// Each [SyncArtifactClass] sub-key is then derived on demand via
/// `SubtleCrypto.deriveKey` with algorithm `HKDF` (empty salt,
/// `artifactClass.hkdfInfo` as the `info` parameter — the same domain-
/// separation labels [DefaultSyncAuthenticator] uses), producing another
/// non-extractable `CryptoKey` usable only for `HMAC`-SHA256 `sign`/`verify`.
/// Sub-keys are memoized in-memory for the lifetime of this instance (they
/// are cheap to re-derive, so they are not persisted independently — only
/// the base key is).
final class WebSyncAuthenticator implements SyncAuthenticator {
  WebSyncAuthenticator._(this._baseKey);

  /// The non-extractable HKDF base `CryptoKey`, imported from raw root-key
  /// bytes that are no longer retained anywhere in this object.
  final web.CryptoKey _baseKey;

  /// Memoized, lazily-derived per-artefact-class sub-keys.
  final Map<SyncArtifactClass, Future<web.CryptoKey>> _subKeys = {};

  /// IndexedDB database name used for [persist]/[loadPersisted].
  static const String _kDbName = 'kmdb-sync-auth';

  /// IndexedDB schema version. Bump and add an `onupgradeneeded` migration
  /// branch if the object-store shape ever changes.
  static const int _kDbVersion = 1;

  /// IndexedDB object store name holding one `CryptoKey` per `keyId`.
  static const String _kStoreName = 'baseKeys';

  /// Imports [rootKeyBytes] (32 bytes) as a non-extractable WebCrypto HKDF
  /// base key.
  ///
  /// The raw bytes exist in JS-visible memory only for the duration of this
  /// call (inside `SubtleCrypto.importKey`) and are not retained by the
  /// returned [WebSyncAuthenticator] — see the class doc comment.
  ///
  /// Throws [ArgumentError] if [rootKeyBytes] is not exactly 32 bytes.
  static Future<WebSyncAuthenticator> importKey(Uint8List rootKeyBytes) async {
    if (rootKeyBytes.length != 32) {
      throw ArgumentError.value(
        rootKeyBytes.length,
        'rootKeyBytes.length',
        'Sync-auth root key must be exactly 32 bytes',
      );
    }
    final baseKey = await _importHkdfBaseKey(rootKeyBytes);
    return WebSyncAuthenticator._(baseKey);
  }

  /// Whether the underlying base key is extractable.
  ///
  /// Always `false` for a [WebSyncAuthenticator] constructed via
  /// [importKey] — see the class doc comment's "Import-only" section. A
  /// host application can use this getter to gate a future "show pairing
  /// code" affordance once key origination is implemented.
  bool get isExtractable => _baseKey.extractable;

  Future<web.CryptoKey> _subKeyFor(SyncArtifactClass artifactClass) {
    return _subKeys.putIfAbsent(artifactClass, () async {
      final algorithm =
          <String, Object>{
                'name': 'HKDF',
                'hash': 'SHA-256',
                // No salt material — mirrors DefaultSyncAuthenticator's
                // `nonce: const <int>[]` (HKDF permits an empty/absent salt).
                'salt': Uint8List(0).toJS,
                'info': Uint8List.fromList(artifactClass.hkdfInfo).toJS,
              }.jsify()!
              as JSObject;
      final derivedKeyType =
          <String, Object>{
                'name': 'HMAC',
                'hash': 'SHA-256',
                'length': 256,
              }.jsify()!
              as JSObject;
      final result = await web.window.crypto.subtle
          .deriveKey(
            algorithm,
            _baseKey,
            derivedKeyType,
            false, // non-extractable
            _jsStringArray(const ['sign', 'verify']),
          )
          .toDart;
      return result! as web.CryptoKey;
    });
  }

  @override
  Future<Uint8List> mac(
    SyncArtifactClass artifactClass,
    Uint8List message,
  ) async {
    final subKey = await _subKeyFor(artifactClass);
    final signature = await web.window.crypto.subtle
        .sign('HMAC'.toJS, subKey, message.toJS)
        .toDart;
    final buffer = (signature! as JSArrayBuffer).toDart;
    // Truncate to 16 bytes (128 bits), matching DefaultSyncAuthenticator and
    // AesGcmEncryptionProvider.indexToken's truncation.
    return buffer.asUint8List().sublist(0, 16);
  }

  @override
  Future<bool> verify(
    SyncArtifactClass artifactClass,
    Uint8List message,
    Uint8List mac,
  ) async {
    // SubtleCrypto.verify expects the full HMAC-SHA256 signature length; we
    // only carry a 16-byte truncated MAC on the wire (SyncAuthEnvelope), so
    // verification is done by recomputing our own truncated MAC and
    // comparing — the browser has no primitive for "verify a truncated
    // HMAC" directly. This mirrors DefaultSyncAuthenticator.verify exactly.
    if (mac.length != 16) return false;
    final expected = await this.mac(artifactClass, message);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= expected[i] ^ mac[i];
    }
    return diff == 0;
  }

  // ── Persistence (IndexedDB) ────────────────────────────────────────────────

  /// Persists this authenticator's base key under [keyId], so a later page
  /// load can recover it via [loadPersisted] without needing to re-import
  /// the raw key bytes.
  Future<void> persist(String keyId) async {
    final db = await _openDb();
    try {
      final completer = Completer<void>();
      final store = db
          .transaction(_jsStringArray([_kStoreName]), 'readwrite')
          .objectStore(_kStoreName);
      final request = store.put(_baseKey, keyId.toJS);
      request.onsuccess = ((web.Event _) => completer.complete()).toJS;
      request.onerror = ((web.Event _) => completer.completeError(
        StateError('IndexedDB put failed for "$keyId": ${request.error}'),
      )).toJS;
      await completer.future;
    } finally {
      db.close();
    }
  }

  /// Loads a previously-[persist]ed base key for [keyId].
  ///
  /// Returns `null` if no key has been persisted under [keyId] on this
  /// origin.
  static Future<WebSyncAuthenticator?> loadPersisted(String keyId) async {
    final db = await _openDb();
    try {
      final completer = Completer<web.CryptoKey?>();
      final store = db
          .transaction(_jsStringArray([_kStoreName]), 'readonly')
          .objectStore(_kStoreName);
      final request = store.get(keyId.toJS);
      request.onsuccess = ((web.Event _) {
        final result = request.result;
        completer.complete(result == null ? null : result as web.CryptoKey);
      }).toJS;
      request.onerror = ((web.Event _) => completer.completeError(
        StateError('IndexedDB get failed for "$keyId": ${request.error}'),
      )).toJS;
      final baseKey = await completer.future;
      if (baseKey == null) return null;
      return WebSyncAuthenticator._(baseKey);
    } finally {
      db.close();
    }
  }

  static Future<web.IDBDatabase> _openDb() {
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_kDbName, _kDbVersion);
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result! as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_kStoreName)) {
        db.createObjectStore(_kStoreName);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      completer.complete(request.result! as web.IDBDatabase);
    }).toJS;
    request.onerror = ((web.Event _) {
      completer.completeError(
        StateError('Failed to open IndexedDB "$_kDbName": ${request.error}'),
      );
    }).toJS;
    return completer.future;
  }

  static Future<web.CryptoKey> _importHkdfBaseKey(Uint8List rawKey) async {
    final result = await web.window.crypto.subtle
        .importKey(
          'raw',
          rawKey.toJS,
          'HKDF'.toJS,
          false, // non-extractable
          _jsStringArray(const ['deriveKey']),
        )
        .toDart;
    return result;
  }

  static JSArray<JSString> _jsStringArray(List<String> values) =>
      values.map((v) => v.toJS).toList().toJS;
}
