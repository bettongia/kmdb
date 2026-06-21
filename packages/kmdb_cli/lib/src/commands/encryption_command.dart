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

import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';

import 'command.dart';

/// Container command that groups encryption-management sub-commands.
///
/// Dispatches to sub-commands based on the first positional argument:
/// - `encryption change-passphrase` — re-wrap the DEK under a new passphrase.
///
/// Usage: `kmdb <db> encryption <sub-command> [args...]`
final class EncryptionCommand extends CliCommand {
  const EncryptionCommand();

  static const _subCommands = <String, CliCommand>{
    'change-passphrase': _ChangePassphraseCommand(),
  };

  @override
  String get name => 'encryption';

  @override
  bool get replVisible => false;

  @override
  String get description =>
      'Encryption management commands. '
      'Sub-commands: change-passphrase. '
      'Use "kmdb help encryption" for details.';

  @override
  String get usage => 'encryption <sub-command> [args...]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError(
        'encryption requires a sub-command.\n'
        'Available sub-commands: ${_subCommands.keys.join(', ')}\n'
        'Usage: $usage',
      );
      return false;
    }

    final subName = args[0];
    final sub = _subCommands[subName];
    if (sub == null) {
      ctx.writeError(
        "Unknown encryption sub-command '$subName'. "
        'Available sub-commands: ${_subCommands.keys.join(', ')}',
      );
      return false;
    }

    return sub.execute(ctx, args.sublist(1), flags);
  }
}

/// Changes the passphrase on an encrypted database.
///
/// Re-wraps the existing DEK under a new passphrase KEK without changing the
/// DEK itself, so all existing data remains readable after the change. A new
/// Argon2id salt is generated; the recovery code is unchanged.
///
/// The current passphrase or recovery code must be supplied via the global
/// `--passphrase` / `--recovery-code` flag (which opens the database). The new
/// passphrase is read interactively from stdin (prompted on stderr so it is
/// never captured by `--output` redirection).
///
/// Usage: `kmdb --passphrase <current> <db> encryption change-passphrase`
final class _ChangePassphraseCommand extends CliCommand {
  const _ChangePassphraseCommand();

  // Metadata getters are never accessed by the dispatch path (sub.execute) and
  // are not exposed to the top-level CommandRunner builder because
  // _ChangePassphraseCommand is a private sub-command.
  // coverage:ignore-start
  @override
  String get name => 'change-passphrase';

  @override
  bool get replVisible => false;

  @override
  String get description =>
      'Change the passphrase of an encrypted database. '
      'Supply the current credentials via --passphrase or --recovery-code. '
      'The new passphrase is entered interactively.';

  @override
  String get usage => 'encryption change-passphrase';
  // coverage:ignore-end

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    // Guard: must be an encrypted database.
    if (ctx.db.encryption == null) {
      ctx.writeError(
        'encryption change-passphrase requires an encrypted database. '
        'Open with --passphrase or --recovery-code.',
      );
      return false;
    }

    // Prompt for the new passphrase on stderr (so it is not captured by
    // --output). Use dart:io directly because CommandContext.out may be
    // redirected to a file.
    // stdin interaction; not testable in automated tests
    // (blocking stdin.readLineSync in a non-tty isolate would hang).
    // coverage:ignore-start
    io.stderr.write('Enter new passphrase: ');
    final newPassphrase = _readPassword();

    if (newPassphrase == null || newPassphrase.isEmpty) {
      ctx.writeError('New passphrase must not be empty.');
      return false;
    }

    io.stderr.write('Confirm new passphrase: ');
    final confirmPassphrase = _readPassword();

    if (confirmPassphrase != newPassphrase) {
      ctx.writeError('Passphrases do not match.');
      return false;
    }

    // The current credentials were already verified at open time (the bootstrap
    // successfully derived the DEK). We need a currentConfig to unwrap the
    // existing blob in changePassphrase(). We re-use the same passphrase/
    // recovery code that was used at open time — it is no longer in memory
    // here, so we need the user to re-supply it.
    //
    // Design note: the global --passphrase flag is the "current" credential used
    // to open the DB. However, the EncryptionConfig was consumed by the
    // bootstrap and the passphrase is not stored in memory post-open (by
    // design). For change-passphrase, the user must re-supply the current
    // credential. We prompt interactively here.
    io.stderr.write('Confirm current passphrase (for re-key): ');
    final currentPassphrase = _readPassword();
    if (currentPassphrase == null || currentPassphrase.isEmpty) {
      ctx.writeError('Current passphrase must not be empty.');
      return false;
    }

    final currentConfig = EncryptionConfig(passphrase: currentPassphrase);

    try {
      await ctx.db.changePassphrase(
        currentConfig: currentConfig,
        newPassphrase: newPassphrase,
      );
    } on EncryptionError catch (e) {
      ctx.writeError('Failed to change passphrase: $e');
      return false;
    }

    ctx.writeValue({
      'status': 'ok',
      'message': 'Passphrase changed successfully.',
    });
    return true;
    // coverage:ignore-end
  }

  /// Reads a line from stdin, hiding echo if the terminal supports it.
  ///
  /// Returns `null` if stdin is closed or reading fails.
  // Requires interactive terminal for echo suppression.
  // coverage:ignore-start
  String? _readPassword() {
    // echoMode suppression requires dart:io and a real terminal.
    // In tests (non-tty stdin), we read normally.
    if (io.stdin.hasTerminal) {
      io.stdin.echoMode = false;
    }
    try {
      final line = io.stdin.readLineSync();
      return line;
    } finally {
      if (io.stdin.hasTerminal) {
        io.stdin.echoMode = true;
        io.stderr.writeln(''); // Move to next line after hidden input.
      }
    }
  }

  // coverage:ignore-end
}
