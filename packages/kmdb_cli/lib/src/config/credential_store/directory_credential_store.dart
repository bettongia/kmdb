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

import 'dart:io';

import '../credential_store.dart';

/// A permission-hardened, per-database-directory [CredentialStore].
///
/// Stores each credential as a plain file at `{dbDir}/local/{account}` —
/// the same location the Google Drive OAuth blob has always lived at — but,
/// on POSIX platforms, hardens both the file and its containing `local/`
/// directory with owner-only permissions and hard-refuses to read a
/// credential whose permissions have since been loosened. This mirrors the
/// model OpenSSH (`~/.ssh`) and `gcloud` (`~/.config/gcloud`) both use in
/// production for exactly this class of secret, rather than integrating
/// with an OS-native keychain (see `docs/roadmap/9_99.md` for that deferred
/// option).
///
/// ## Permission model
///
/// **Platform gate:** every POSIX-permission behaviour below is gated on
/// `!Platform.isWindows`, not `Platform.isLinux || Platform.isMacOS` — the
/// narrower check would silently disable enforcement on other Unix
/// platforms (e.g. FreeBSD). On Windows, [write] and [read] perform no
/// `chmod`/`stat` calls at all; permission enforcement instead relies on
/// the default NTFS ACL inheritance from the user's profile directory
/// (owner + Administrators/SYSTEM only) — the same free ride `gcloud`
/// relies on for `%APPDATA%\gcloud`.
///
/// **Primitives:** `dart:io` has no `chmod`/`setPermissions` API on `File`
/// or `FileSystemEntity`, so permission *setting* shells out via
/// `Process.run('chmod', ...)`. Permission *inspection* uses
/// `FileSystemEntity.stat()` → `FileStat.mode`, whose low 9 bits are the
/// POSIX permission bits.
///
/// **Write ordering:** to close the exposure window created by
/// `dart:io` having no create-at-mode primitive (`File.writeAsString`
/// always creates at the process umask, typically world-readable), [write]
/// chmods the *directory* to `700` **before** writing the file — this
/// means the file is never reachable by path by another user, even during
/// the brief window before the file itself is chmod'd to `600`. The full
/// order is: ensure `local/` exists → `chmod 700` the directory → write the
/// file → `chmod 600` the file. If either `chmod` subprocess is missing or
/// exits non-zero, the write fails with a [StateError] — a secret is never
/// left written at loose permissions (on file-chmod failure, the
/// just-written file is deleted on a best-effort basis before the error
/// propagates).
///
/// **Shared directory:** `{dbDir}/local/` is not credential-owned — it also
/// holds `config.json` (written by `KmdbConfig.save()` at the process
/// umask). Only the credential write path ever tightens it to `700`. This
/// is an intentional, benign side effect: the owner retains full access to
/// everything else in `local/`. Both the directory and the file are
/// checked on [read] (not file-only, as SSH does) because the file check
/// alone cannot detect a `local/` that regressed to a looser mode after
/// being widened by some other process.
///
/// **Refuse predicate:** [read] throws [CredentialPermissionException] when
/// `(fileMode & 0x1FF & 0o077 != 0) || (dirMode & 0x1FF & 0o077 != 0)` —
/// i.e. any group or world permission bit set on either the file or its
/// parent directory.
///
/// **Account key:** [account] is used directly as the filename within
/// `{dbDir}/local/` — no encoding transform is needed. Unlike a single
/// global OS keychain, a directory scoped to one `dbDir` cannot collide
/// across databases, so two `google-drive` remotes on the same database
/// with distinct `--credentials` values simply address distinct files.
final class DirectoryCredentialStore implements CredentialStore {
  /// Creates a [DirectoryCredentialStore] rooted at `{dbDir}/local/`.
  DirectoryCredentialStore({required this.dbDir});

  /// The local database directory. Credentials are stored under
  /// `{dbDir}/local/`.
  final String dbDir;

  /// The permission bits enforced on the containing `local/` directory
  /// (owner: read/write/execute; group/world: none).
  static const int _dirMode = 0x1C0; // 0o700

  /// The permission bits enforced on each credential file (owner:
  /// read/write; group/world: none).
  static const int _fileMode = 0x180; // 0o600

  /// Mask isolating the standard POSIX permission bits (rwxrwxrwx) from the
  /// higher bits `FileStat.mode` may also carry (e.g. file-type bits).
  static const int _permMask = 0x1FF; // 0o777

  /// Mask isolating the group/world permission bits — any bit set here
  /// means the entity is readable, writable, or executable by someone other
  /// than the owner.
  static const int _groupWorldMask = 0x3F; // 0o077

  String get _localDirPath => [dbDir, 'local'].join(Platform.pathSeparator);

  String _accountPath(String account) =>
      [_localDirPath, account].join(Platform.pathSeparator);

  @override
  Future<void> write(String account, String secretJson) async {
    final localDir = Directory(_localDirPath);
    await localDir.create(recursive: true);

    // Directory-first chmod ordering closes the exposure window: dart:io
    // cannot create a file at a restrictive mode directly, so tightening
    // the parent directory to owner-only *before* the file is written means
    // the file is never reachable by path by another user, even during the
    // brief interval before the file itself is chmod'd.
    if (!Platform.isWindows) {
      await _chmod(localDir.path, '700');
    }

    final file = File(_accountPath(account));
    await file.writeAsString(secretJson);

    if (!Platform.isWindows) {
      try {
        await _chmod(file.path, '600');
        // coverage:ignore-start
      } catch (_) {
        // Never leave a secret written at loose permissions: remove the
        // file we just wrote (best-effort) before propagating the error.
        // Untestable portably in the automated suite: triggering a real
        // chmod-on-an-existing-file failure requires an environment-specific
        // condition (immutable file flag, read-only bind mount, missing
        // chmod binary) that cannot be reproduced deterministically in CI —
        // see _chmod's own doc comment.
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Ignore cleanup failures; the original chmod error is what
          // matters to the caller.
        }
        rethrow;
      }
      // coverage:ignore-end
    }
  }

  @override
  Future<String?> read(String account) async {
    final file = File(_accountPath(account));
    if (!await file.exists()) return null;

    if (!Platform.isWindows) {
      final fileStat = await file.stat();
      final fileMode = fileStat.mode & _permMask;
      if (fileMode & _groupWorldMask != 0) {
        throw CredentialPermissionException(
          path: file.path,
          actualMode: fileMode,
          expectedMode: _fileMode,
        );
      }

      final dirStat = await Directory(_localDirPath).stat();
      final dirMode = dirStat.mode & _permMask;
      if (dirMode & _groupWorldMask != 0) {
        throw CredentialPermissionException(
          path: _localDirPath,
          actualMode: dirMode,
          expectedMode: _dirMode,
        );
      }
    }

    return file.readAsString();
  }

  @override
  Future<void> delete(String account) async {
    final file = File(_accountPath(account));
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Runs `chmod [mode] [path]` and throws [StateError] if the subprocess
  /// is unavailable or exits non-zero.
  ///
  /// There is no in-process alternative: `dart:io` exposes no
  /// `chmod`/`setPermissions` API, so setting POSIX permissions always
  /// requires shelling out.
  Future<void> _chmod(String path, String mode) async {
    final ProcessResult result;
    try {
      result = await Process.run('chmod', [mode, path]);
      // coverage:ignore-start
      //
      // Both branches below are genuine defensive code — write() must never
      // leave a secret at loose permissions if chmod fails — but neither is
      // portably/deterministically triggerable in the automated suite: the
      // ProcessException branch requires an environment with no "chmod" on
      // PATH, and the non-zero-exit branch requires an environment-specific
      // filesystem condition (e.g. an immutable file flag or a read-only
      // bind mount) on a path this method has just successfully created or
      // written to moments earlier.
    } on ProcessException catch (e) {
      throw StateError(
        'Failed to set permissions on $path: the "chmod" command is not '
        'available ($e). Credentials cannot be safely stored without '
        'permission enforcement.',
      );
    }
    if (result.exitCode != 0) {
      throw StateError(
        'Failed to set permissions on $path: chmod exited with '
        '${result.exitCode}: ${result.stderr}',
      );
    }
    // coverage:ignore-end
  }
}
