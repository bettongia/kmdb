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

// ignore_for_file: avoid_print — this is a demonstration, not production code.

/// Demonstrates wiring `kmdb_flutter` into a Flutter app:
///
/// 1. Calling `KmdbFlutter.initialize()` in `main()` to register native
///    AES-256-GCM / Argon2id acceleration via `cryptography_flutter`.
/// 2. Provisioning an encrypted database with a passphrase. Every unlock —
///    passphrase, recovery code, or (once enrolled) biometric — is an
///    authenticated unwrap; there is no DEK session cache to configure. See
///    `EncryptionConfig.biometric` and `KmdbDatabase.enableBiometricUnlock`
///    in `kmdb` for the biometric-unlock path this package's native
///    `BiometricKekProvider` implementation feeds.
///
/// This example does not include a real `StorageAdapter` — replace
/// `_buildAdapter()` with the appropriate platform adapter from `kmdb`.
library;

import 'package:flutter/material.dart';
import 'package:kmdb/kmdb.dart';
import 'package:kmdb_flutter/kmdb_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register native crypto acceleration (hardware AES-GCM + Argon2id on iOS /
  // Android). Safe to call multiple times — subsequent calls are no-ops.
  KmdbFlutter.initialize();

  runApp(const KmdbFlutterExampleApp());
}

/// Minimal example app that opens an encrypted KMDB database.
class KmdbFlutterExampleApp extends StatefulWidget {
  const KmdbFlutterExampleApp({super.key});

  @override
  State<KmdbFlutterExampleApp> createState() => _KmdbFlutterExampleAppState();
}

class _KmdbFlutterExampleAppState extends State<KmdbFlutterExampleApp> {
  String _status = 'Tap the button to open the database';

  Future<void> _openDatabase() async {
    setState(() => _status = 'Opening database...');

    try {
      // In a real app, use a platform-appropriate path from path_provider and
      // a StorageAdapter from `kmdb` (e.g. StorageAdapterNative).
      //
      // This example just shows the wiring; it will throw because
      // `_buildAdapter()` is a stub.
      //
      // Provision a new encrypted database (createResult generates the DEK,
      // wraps it under both the passphrase and a one-time recovery code, and
      // persists the wrapped copies to enc:blob).
      final encryptionResult = await EncryptionConfig.createResult(
        passphrase: 'demo-passphrase',
      );

      print('Recovery code (store safely): ${encryptionResult.recoveryCode}');

      // ignore: unused_local_variable — real code would use `db`
      final db = await KmdbDatabase.open(
        path: '/tmp/demo.db',
        adapter: _buildAdapter(),
        encryptionConfig: encryptionResult.config,
      );

      setState(() => _status = 'Database opened successfully');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  /// Returns a placeholder adapter for illustration.
  ///
  /// Replace this with your platform-specific adapter:
  ///
  /// ```dart
  /// StorageAdapterNative(Directory('/path/to/db'))
  /// ```
  StorageAdapter _buildAdapter() {
    throw UnimplementedError(
      'Replace _buildAdapter() with a real StorageAdapter from kmdb.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'kmdb_flutter example',
      home: Scaffold(
        appBar: AppBar(title: const Text('kmdb_flutter Example')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _openDatabase,
                child: const Text('Open Encrypted Database'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
