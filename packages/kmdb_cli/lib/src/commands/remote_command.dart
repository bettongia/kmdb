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

import 'package:googleapis_auth/auth_io.dart';
import 'package:kmdb/kmdb.dart'
    show PairingCode, SecretStore, SyncSetKey, dbScopedSecretKey;
import 'package:kmdb/kmdb_config.dart';
import 'package:kmdb_google_drive/kmdb_google_drive.dart' show kDriveFileScope;

import '../config/secret_store/directory_secret_store.dart';
import '../config/sync_auth_key_store.dart';
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
/// kmdb <db> remote pair show <name>
/// kmdb <db> remote pair import <name> <code>
/// ```
///
/// The first positional argument is the subcommand. For `add`, `remove`, and
/// `pair show`/`pair import`, the second positional argument is the remote
/// name.
///
/// ## Sync authentication (0.10.01 WI-4 T1)
///
/// `remote add` mints a fresh 256-bit sync-set key for the new remote
/// automatically — every artefact this device uploads to that remote is
/// authenticated (`SyncAuthEnvelope`) with it, and every artefact downloaded
/// is verified against it. A second device joining the same remote must
/// **also** run its own `remote add` (to configure its own connection
/// details — path, Drive credentials, etc.) and then
/// `remote pair import <name> <code>` using a code printed by
/// `remote pair show <name>` on an already-enrolled device, so both devices
/// share the same key. Without this, the two devices' artefacts fail
/// authentication for each other — see `SyncAuthException`.
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
      '       remote list\n'
      '       remote pair show <name>\n'
      '       remote pair import <name> <code>';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags, {
    // Injectable secret store, used by tests to avoid exercising the real
    // permission-hardened filesystem store. Not part of the
    // `CliCommand.execute` contract — an override method may add extra
    // *optional* parameters beyond its superclass signature, so callers that
    // go through the `CliCommand` interface (e.g. `cli_runner.dart`) are
    // unaffected and simply omit it, defaulting to null (the real store).
    SecretStore? secretStoreOverride,
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
          secretStoreOverride: secretStoreOverride,
        );
      case 'remove':
        return _remove(
          ctx,
          args.sublist(1),
          secretStoreOverride: secretStoreOverride,
        );
      case 'list':
        return _list(ctx);
      case 'pair':
        return _pair(
          ctx,
          args.sublist(1),
          secretStoreOverride: secretStoreOverride,
        );
      default:
        ctx.writeError(
          "remote: unknown subcommand '$subcommand'. "
          'Expected: add, remove, list, pair.',
        );
        return false;
    }
  }

  // ── add ────────────────────────────────────────────────────────────────────

  Future<bool> _add(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags, {
    SecretStore? secretStoreOverride,
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
          secretStoreOverride: secretStoreOverride,
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

    // Mint a fresh sync-set key for this remote (0.10.01 WI-4 T1, Q-C: one
    // key per remote). This is what makes a single-device `remote add`
    // "just work" without an explicit pairing step — pairing is only needed
    // when a *second* device joins the same remote (see `remote pair`).
    // Minted unconditionally, including for `--force` re-adds: re-adding an
    // existing remote is a re-provisioning event, and R-5's design already
    // treats "the sync folder's authentication key changed" as something
    // every device must re-pair for, not something a silent key reuse could
    // paper over.
    await mintSyncAuthKey(
      dbDir: dbDir,
      remoteName: name,
      secretStoreOverride: secretStoreOverride,
    );

    ctx.out.writeln("Remote '$name' added (type: $type).");
    return true;
  }

  // ── remove ─────────────────────────────────────────────────────────────────

  Future<bool> _remove(
    CommandContext ctx,
    List<String> args, {
    SecretStore? secretStoreOverride,
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
    // orphaned in the secret store with no config entry pointing at it.
    if (removedRemote case GoogleDriveRemoteConfig(:final credentialsPath)) {
      final store = secretStoreOverride ?? DirectorySecretStore.forPlatform();
      await store.delete(dbScopedSecretKey(dbDir, credentialsPath));
    }

    // Delete the sync-authentication key too — every remote has one
    // (minted by `remote add`), regardless of type, so this cleanup is
    // unconditional rather than gated on a specific `RemoteConfig` subtype.
    await deleteSyncAuthKey(
      dbDir: dbDir,
      remoteName: name,
      secretStoreOverride: secretStoreOverride,
    );

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

  // ── pair ───────────────────────────────────────────────────────────────────

  /// Dispatches `remote pair show`/`remote pair import` (0.10.01 WI-4 T1).
  Future<bool> _pair(
    CommandContext ctx,
    List<String> args, {
    SecretStore? secretStoreOverride,
  }) async {
    if (args.isEmpty) {
      ctx.writeError(
        'remote pair: subcommand required (show, import).\n'
        'Usage: remote pair show <name>\n'
        '       remote pair import <name> <code>',
      );
      return false;
    }
    final dbDir = (await ctx.store.storeInfo()).dbDir;
    final subcommand = args[0];
    switch (subcommand) {
      case 'show':
        return _pairShow(
          ctx,
          args.sublist(1),
          dbDir,
          secretStoreOverride: secretStoreOverride,
        );
      case 'import':
        return _pairImport(
          ctx,
          args.sublist(1),
          dbDir,
          secretStoreOverride: secretStoreOverride,
        );
      default:
        ctx.writeError(
          "remote pair: unknown subcommand '$subcommand'. "
          'Expected: show, import.',
        );
        return false;
    }
  }

  /// Prints the pairing code for an already-enrolled remote, so a second
  /// device can `remote pair import` it.
  Future<bool> _pairShow(
    CommandContext ctx,
    List<String> args,
    String dbDir, {
    SecretStore? secretStoreOverride,
  }) async {
    if (args.isEmpty) {
      ctx.writeError('remote pair show: remote name required.');
      return false;
    }
    final name = args[0];

    final key = await loadSyncAuthKey(
      dbDir: dbDir,
      remoteName: name,
      secretStoreOverride: secretStoreOverride,
    );
    if (key == null) {
      ctx.writeError(
        "remote pair show: remote '$name' has no sync-authentication key. "
        "Run 'remote add $name ...' first (it mints a key automatically), "
        "or check the remote name with 'remote list'.",
      );
      return false;
    }

    ctx.out.writeln(await PairingCode.encode(key));
    return true;
  }

  /// Installs a pairing code's key as the sync-authentication key for an
  /// already-configured remote, so this device shares the same key as the
  /// device that ran `remote pair show`.
  ///
  /// The remote must already exist in this device's own `config.json` —
  /// the pairing code carries only the shared key material, never
  /// connection details (path, Drive folder/credentials), so this device
  /// must have separately run its own `remote add` for [args]`[0]` first.
  Future<bool> _pairImport(
    CommandContext ctx,
    List<String> args,
    String dbDir, {
    SecretStore? secretStoreOverride,
  }) async {
    if (args.length < 2) {
      ctx.writeError(
        'remote pair import: remote name and pairing code required.\n'
        'Usage: remote pair import <name> <code>',
      );
      return false;
    }
    final name = args[0];
    final code = args[1];

    final KmdbConfig config;
    try {
      config = await KmdbConfig.forDatabase(dbDir);
    } on FormatException catch (e) {
      ctx.writeError(e.message);
      return false;
    }
    if (!config.remotes.containsKey(name)) {
      ctx.writeError(
        "remote pair import: no remote named '$name' is configured on "
        "this device. Run 'remote add $name --type <type> ...' first "
        '(with this device\'s own connection details), then re-run this '
        'command.',
      );
      return false;
    }

    final SyncSetKey key;
    try {
      key = await PairingCode.decode(code);
    } on FormatException catch (e) {
      ctx.writeError('remote pair import: invalid pairing code: ${e.message}');
      return false;
    }

    await importSyncAuthKey(
      dbDir: dbDir,
      remoteName: name,
      key: key,
      secretStoreOverride: secretStoreOverride,
    );
    ctx.out.writeln(
      "Remote '$name' enrolled with the shared sync-authentication key.",
    );
    return true;
  }

  // ── Google Drive OAuth helpers ─────────────────────────────────────────────

  /// Runs the local-server OAuth redirect flow for Google Drive.
  ///
  /// Opens the user's browser to the Google consent page, starts a transient
  /// HTTP server on `localhost` to capture the callback, and writes the
  /// resulting [AccessCredentials] (plus the client ID) to the
  /// permission-hardened secret store, under
  /// `dbScopedSecretKey(dbDir, credentialsPath)`.
  ///
  /// [secretStoreOverride] — an injectable [SecretStore]; defaults to `null`,
  /// in which case [DirectorySecretStore.forPlatform] resolves the real store
  /// rooted at the per-user profile config directory.
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
    SecretStore? secretStoreOverride,
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
    // future refresh calls can re-use it. Routed through the secret store so
    // the write is permission-hardened (chmod 700 dir / 600 file on POSIX)
    // rather than landing at the process's default umask.
    final credentials = authClient.credentials;
    final store = secretStoreOverride ?? DirectorySecretStore.forPlatform();
    try {
      await store.write(
        dbScopedSecretKey(dbDir, credentialsPath),
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              ...credentials.toJson(),
              'client_id': clientId,
              'client_secret': clientSecret,
            }),
          ),
        ),
      );
    } catch (e) {
      ctx.writeError('Failed to save Google Drive credentials: $e');
      authClient.close();
      return false;
    }

    authClient.close();
    ctx.out.writeln('Google Drive authorisation successful.');
    return true;
    // coverage:ignore-end
  }
}
