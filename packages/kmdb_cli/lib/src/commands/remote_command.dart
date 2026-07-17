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

import 'package:googleapis_auth/auth_io.dart';
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_google_drive/kmdb_google_drive.dart' show kDriveFileScope;

import '../config/credential_store.dart';
import 'command.dart';

/// Manages named sync remotes for a KMDB database.
///
/// Remotes are stored in `{dbDir}/local/config.json` and are used by the
/// `push`, `pull`, and `sync` commands.
///
/// ## Subcommands
///
/// ```
/// kmdb <db> remote add <name> --type local --path <path> [--force]
/// kmdb <db> remote add <name> --type google-drive --folder <name>
///           --client-id <id> --client-secret <secret>
///           [--credentials <file>] [--force]
/// kmdb <db> remote remove <name>
/// kmdb <db> remote list
/// ```
///
/// The first positional argument is the subcommand. For `add` and `remove`,
/// the second positional argument is the remote name.
final class RemoteCommand extends CliCommand {
  /// Creates a [RemoteCommand].
  const RemoteCommand();

  @override
  String get name => 'remote';

  @override
  String get description => 'Manage named sync remotes (add, remove, list).';

  @override
  String get usage =>
      'remote add <name> --type local --path <path> [--force]\n'
      '       remote add <name> --type google-drive --folder <folder-name>\n'
      '                 --client-id <oauth-client-id> --client-secret <secret>\n'
      '                 [--credentials <file>] [--force]\n'
      '       remote remove <name>\n'
      '       remote list';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags, {
    // Injectable credential store, used by tests to avoid exercising the
    // real permission-hardened filesystem store. Not part of the
    // `CliCommand.execute` contract — an override method may add extra
    // *optional* parameters beyond its superclass signature, so callers that
    // go through the `CliCommand` interface (e.g. `cli_runner.dart`) are
    // unaffected and simply omit it, defaulting to null (the real store).
    CredentialStore? credentialStoreOverride,
  }) async {
    if (args.isEmpty) {
      ctx.writeError(
        'remote: subcommand required (add, remove, list).\n'
        'Usage: $usage',
      );
      return false;
    }

    final subcommand = args[0];
    switch (subcommand) {
      case 'add':
        return _add(
          ctx,
          args.sublist(1),
          flags,
          credentialStoreOverride: credentialStoreOverride,
        );
      case 'remove':
        return _remove(
          ctx,
          args.sublist(1),
          credentialStoreOverride: credentialStoreOverride,
        );
      case 'list':
        return _list(ctx);
      default:
        ctx.writeError(
          "remote: unknown subcommand '$subcommand'. "
          'Expected: add, remove, list.',
        );
        return false;
    }
  }

  // ── add ────────────────────────────────────────────────────────────────────

  Future<bool> _add(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags, {
    CredentialStore? credentialStoreOverride,
  }) async {
    if (args.isEmpty) {
      ctx.writeError('remote add: remote name required.');
      return false;
    }
    final name = args[0];

    final type = (flags['type'] as String?) ?? 'local';
    final force = flags['force'] == true;
    final dbDir = (await ctx.store.storeInfo()).dbDir;

    final RemoteConfig remote;
    switch (type) {
      case 'local':
        final path = flags['path'] as String?;
        if (path == null) {
          ctx.writeError("remote add: --path is required for type 'local'.");
          return false;
        }
        remote = LocalRemoteConfig(path: path);

      case 'google-drive':
        // Validate required flags.
        final folder = flags['folder'] as String?;
        if (folder == null) {
          ctx.writeError(
            "remote add: --folder is required for type 'google-drive'.",
          );
          return false;
        }
        final clientId = flags['client-id'] as String?;
        if (clientId == null) {
          ctx.writeError(
            "remote add: --client-id is required for type 'google-drive'.",
          );
          return false;
        }
        // coverage:ignore-start
        final clientSecret = (flags['client-secret'] as String?) ?? '';
        final credPath =
            (flags['credentials'] as String?) ?? 'google_credentials.json';
        // coverage:ignore-end

        // Run the local-server OAuth redirect flow (opens a browser, captures
        // the OAuth callback on localhost, persists the resulting credentials).
        // coverage:ignore-start
        final authorised = await _authoriseGoogleDrive(
          ctx,
          dbDir: dbDir,
          clientId: clientId,
          clientSecret: clientSecret,
          credentialsPath: credPath,
          credentialStoreOverride: credentialStoreOverride,
        );
        if (!authorised) return false;

        remote = GoogleDriveRemoteConfig(
          syncRoot: folder,
          credentialsPath: credPath,
        );
      // coverage:ignore-end

      default:
        ctx.writeError(
          "remote add: unknown type '$type'. "
          'Supported types: local, google-drive.',
        );
        return false;
    }

    final KmdbConfig config;
    try {
      config = await KmdbConfig.forDatabase(dbDir);
    } on FormatException catch (e) {
      ctx.writeError(e.message);
      return false;
    }

    try {
      config.addRemote(name, remote, force: force);
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    }

    try {
      await config.save();
    } catch (e) {
      // coverage:ignore-start
      ctx.writeError('remote add: failed to save config: $e');
      return false;
      // coverage:ignore-end
    }

    ctx.out.writeln("Remote '$name' added (type: $type).");
    return true;
  }

  // ── remove ─────────────────────────────────────────────────────────────────

  Future<bool> _remove(
    CommandContext ctx,
    List<String> args, {
    CredentialStore? credentialStoreOverride,
  }) async {
    if (args.isEmpty) {
      ctx.writeError('remote remove: remote name required.');
      return false;
    }
    final name = args[0];
    final dbDir = (await ctx.store.storeInfo()).dbDir;

    final KmdbConfig config;
    try {
      config = await KmdbConfig.forDatabase(dbDir);
    } on FormatException catch (e) {
      ctx.writeError(e.message);
      return false;
    }

    // Look up the remote *before* removing it from the config, so a
    // GoogleDriveRemoteConfig's credentialsPath is still available afterwards
    // to delete the stored credentials file.
    final removedRemote = config.remotes[name];

    try {
      config.removeRemote(name);
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    }

    try {
      await config.save();
    } catch (e) {
      // coverage:ignore-start
      ctx.writeError('remote remove: failed to save config: $e');
      return false;
      // coverage:ignore-end
    }

    // Closes the leak where `remote remove` deleted the config.json entry
    // but left the credentials file behind: a stale, still-valid OAuth token
    // orphaned in {dbDir}/local/ with no config entry pointing at it.
    if (removedRemote case GoogleDriveRemoteConfig(:final credentialsPath)) {
      final store =
          credentialStoreOverride ?? CredentialStore.forPlatform(dbDir: dbDir);
      await store.delete(credentialsPath);
    }

    ctx.out.writeln("Remote '$name' removed.");
    return true;
  }

  // ── list ───────────────────────────────────────────────────────────────────

  Future<bool> _list(CommandContext ctx) async {
    final dbDir = (await ctx.store.storeInfo()).dbDir;

    final KmdbConfig config;
    try {
      config = await KmdbConfig.forDatabase(dbDir);
    } on FormatException catch (e) {
      ctx.writeError(e.message);
      return false;
    }

    if (config.remotes.isEmpty) {
      ctx.out.writeln('No remotes configured.');
      return true;
    }

    // Print one line per remote: name, type, and the key identifying field.
    for (final entry in config.remotes.entries) {
      final rname = entry.key;
      final remote = entry.value;
      switch (remote) {
        case LocalRemoteConfig(:final path):
          ctx.out.writeln('$rname\tlocal\t$path');
        case GoogleDriveRemoteConfig(:final syncRoot):
          ctx.out.writeln('$rname\tgoogle-drive\t$syncRoot');
      }
    }
    return true;
  }

  // ── Google Drive OAuth helpers ─────────────────────────────────────────────

  /// Runs the local-server OAuth redirect flow for Google Drive.
  ///
  /// Opens the user's browser to the Google consent page, starts a transient
  /// HTTP server on `localhost` to capture the callback, and writes the
  /// resulting [AccessCredentials] (plus the client ID) to the
  /// permission-hardened credential store at `{dbDir}/local/{credentialsPath}`.
  ///
  /// [credentialStoreOverride] — an injectable [CredentialStore]; defaults to
  /// `null`, in which case [CredentialStore.forPlatform] resolves the real
  /// store rooted at [dbDir].
  ///
  /// Returns `true` on success, `false` if the flow fails.
  // Requires a real browser and live Google OAuth endpoint; untestable.
  // coverage:ignore-start
  Future<bool> _authoriseGoogleDrive(
    CommandContext ctx, {
    required String dbDir,
    required String clientId,
    required String clientSecret,
    required String credentialsPath,
    CredentialStore? credentialStoreOverride,
  }) async {
    ctx.out.writeln(
      '\nStarting Google Drive authorisation flow...\n'
      'A browser window will open.  Please sign in and grant KMDB access.\n',
    );

    AutoRefreshingAuthClient? authClient;
    try {
      authClient = await clientViaUserConsent(
        ClientId(clientId, clientSecret),
        [kDriveFileScope],
        (url) => ctx.out.writeln(
          'Please visit the following URL to authorise KMDB:\n\n  $url\n',
        ),
      );
    } catch (e) {
      ctx.writeError('Google Drive authorisation failed: $e');
      return false;
    }

    // Persist the credentials for future use, including the client ID so
    // future refresh calls can re-use it. Routed through the credential
    // store so the write is permission-hardened (chmod 700 dir / 600 file
    // on POSIX) rather than landing at the process's default umask.
    final credentials = authClient.credentials;
    final store =
        credentialStoreOverride ?? CredentialStore.forPlatform(dbDir: dbDir);
    try {
      await store.write(
        credentialsPath,
        jsonEncode({
          ...credentials.toJson(),
          'client_id': clientId,
          'client_secret': clientSecret,
        }),
      );
    } catch (e) {
      ctx.writeError(
        'Failed to save Google Drive credentials to '
        '$dbDir/local/$credentialsPath: $e',
      );
      authClient.close();
      return false;
    }

    authClient.close();
    ctx.out.writeln('Google Drive authorisation successful.');
    return true;
    // coverage:ignore-end
  }
}
