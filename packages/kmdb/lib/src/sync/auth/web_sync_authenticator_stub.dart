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
// Stub for platforms where dart:js_interop / WebCrypto is unavailable
// (native). WebSyncAuthenticator requires the browser's Web Crypto API and
// IndexedDB and cannot be used on these platforms — use
// DefaultSyncAuthenticator instead.

import 'dart:typed_data';

import 'sync_artifact_class.dart';
import 'sync_authenticator.dart';

/// Unsupported stub of `WebSyncAuthenticator` for native platforms.
///
/// The real implementation requires `dart:js_interop`/WebCrypto and
/// IndexedDB and is therefore unavailable outside a browser. All members
/// throw [UnsupportedError]. Native hosts use [DefaultSyncAuthenticator]
/// instead.
final class WebSyncAuthenticator implements SyncAuthenticator {
  WebSyncAuthenticator._();

  /// Always throws [UnsupportedError].
  static Future<WebSyncAuthenticator> importKey(Uint8List rootKeyBytes) =>
      throw UnsupportedError(
        'WebSyncAuthenticator is not supported outside a browser. '
        'Use DefaultSyncAuthenticator instead.',
      );

  /// Always throws [UnsupportedError].
  static Future<WebSyncAuthenticator?> loadPersisted(String keyId) =>
      throw UnsupportedError(
        'WebSyncAuthenticator is not supported outside a browser.',
      );

  /// Always throws [UnsupportedError].
  Future<void> persist(String keyId) => throw UnsupportedError(
    'WebSyncAuthenticator is not supported outside a browser.',
  );

  /// Always throws [UnsupportedError].
  bool get isExtractable => throw UnsupportedError(
    'WebSyncAuthenticator is not supported outside a browser.',
  );

  @override
  Future<Uint8List> mac(SyncArtifactClass artifactClass, Uint8List message) =>
      throw UnsupportedError(
        'WebSyncAuthenticator is not supported outside a browser.',
      );

  @override
  Future<bool> verify(
    SyncArtifactClass artifactClass,
    Uint8List message,
    Uint8List mac,
  ) => throw UnsupportedError(
    'WebSyncAuthenticator is not supported outside a browser.',
  );
}
