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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kmdb/kmdb.dart';

import '../../db/app_database.dart';
import 'project_list_screen.dart';

/// Screen 1 of 6 — "Unlock/Create".
///
/// Demonstrates the Integration Guide's encryption bootstrap section:
/// passphrase entry, the create-vs-unlock branch, one-time recovery-code
/// display, recovery-code unlock, and the [EncryptionError.badCredentials]
/// fault path.
class UnlockScreen extends StatefulWidget {
  /// Creates the [UnlockScreen] for the database at [dbPath].
  const UnlockScreen({required this.dbPath, super.key});

  /// Filesystem path of the database to create or unlock.
  final String dbPath;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _passphraseController = TextEditingController();
  final _recoveryCodeController = TextEditingController();
  bool _useRecoveryCode = false;
  bool _loading = false;
  String? _errorMessage;

  bool get _databaseExists => File('${widget.dbPath}/CURRENT').existsSync();

  @override
  void dispose() {
    _passphraseController.dispose();
    _recoveryCodeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final KmdbDatabase db;
      String? recoveryCodeToShow;

      if (!_databaseExists) {
        // Create-vs-unlock branch: no CURRENT file yet, so provision a new
        // encrypted database. `createResult` returns both the config to pass
        // to `AppDatabase.open` and the one-time 16-word recovery code.
        final setup = await EncryptionConfig.createResult(
          passphrase: _passphraseController.text,
        );
        db = await AppDatabase.open(
          path: widget.dbPath,
          encryptionConfig: setup.config,
        );
        recoveryCodeToShow = setup.recoveryCode;
      } else if (_useRecoveryCode) {
        db = await AppDatabase.open(
          path: widget.dbPath,
          encryptionConfig: EncryptionConfig(
            recoveryCode: _recoveryCodeController.text,
          ),
        );
      } else {
        db = await AppDatabase.open(
          path: widget.dbPath,
          encryptionConfig: EncryptionConfig(
            passphrase: _passphraseController.text,
          ),
        );
      }

      if (!mounted) return;

      if (recoveryCodeToShow != null) {
        await _showRecoveryCodeDialog(recoveryCodeToShow);
      }

      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ProjectListScreen(db: db)),
      );
    } on EncryptionError catch (e) {
      // The screen-reader-reachable error path (spec §31 fault handling):
      // wrong passphrase/recovery code surfaces as `badCredentials`, and the
      // open() call already released the database lock, so retrying here is
      // safe.
      setState(() {
        _errorMessage = switch (e.code) {
          EncryptionErrorCode.badCredentials =>
            'Incorrect passphrase or recovery code. Please try again.',
          _ => 'Could not open the database: ${e.message}',
        };
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showRecoveryCodeDialog(String recoveryCode) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Save your recovery code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This 16-word recovery code is shown only once. Store it '
              'somewhere safe — it is the only way to unlock this database '
              'if you forget your passphrase.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              recoveryCode,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("I've saved it, continue"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final creating = !_databaseExists;
    return Scaffold(
      appBar: AppBar(title: const Text('kmdb Example To-Do')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  creating ? 'Create your database' : 'Unlock your database',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (!creating)
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Passphrase')),
                      ButtonSegment(value: true, label: Text('Recovery code')),
                    ],
                    selected: {_useRecoveryCode},
                    onSelectionChanged: (s) =>
                        setState(() => _useRecoveryCode = s.first),
                  ),
                const SizedBox(height: 16),
                if (creating || !_useRecoveryCode)
                  TextField(
                    controller: _passphraseController,
                    obscureText: true,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Passphrase',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submit(),
                  )
                else
                  TextField(
                    controller: _recoveryCodeController,
                    decoration: const InputDecoration(
                      labelText: 'Recovery code (16 words)',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  // Semantics(liveRegion: true) makes this announced by
                  // screen readers as soon as it appears, not only if the
                  // user happens to navigate onto it.
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(creating ? 'Create' : 'Unlock'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
