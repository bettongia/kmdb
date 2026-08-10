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
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart' show SecretStore, SecretPermissionException;
import 'package:path/path.dart' as p;

/// A permission-hardened, filesystem-backed [SecretStore].
///
/// Stores each secret as a plain file directly under [root], and, on POSIX
/// platforms, hardens both the file and [root] itself with owner-only
/// permissions, hard-refusing to read a secret whose permissions have since
/// been loosened. This mirrors the model OpenSSH (`~/.ssh`) and `gcloud`
/// (`~/.config/gcloud`) both use in production for exactly this class of
/// secret, rather than integrating with an OS-native keychain (see
/// `docs/roadmap/9_99.md` for that deferred option).
///
/// [DirectorySecretStore.forPlatform] resolves [root] to the per-user
/// profile config directory (`%APPDATA%\kmdb` on Windows, `~/.config/kmdb`
/// on POSIX) — the controlled location that closes review finding C-1. Any
/// other [root] may be supplied directly (e.g. for tests, or a caller with
/// its own rooting policy).
///
/// This is the direct successor to `kmdb_cli`'s former
/// `DirectoryCredentialStore`, which rooted at `{dbDir}/local/` — a location
/// not guaranteed to inherit restrictive ACLs the way the profile directory
/// is. The permission model below (chmod ordering, refuse predicate,
/// platform gate) is carried over unchanged; only the root and the
/// byte-vs-string payload type have changed.
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
/// `dart:io` having no create-at-mode primitive (`File.writeAsBytes`
/// always creates at the process umask, typically world-readable), [write]
/// chmods [root] to `700` **before** writing the file — this means the file
/// is never reachable by path by another user, even during the brief window
/// before the file itself is chmod'd to `600`. The full order is: ensure
/// [root] exists → `chmod 700` [root] → write the file → `chmod 600` the
/// file. If either `chmod` subprocess is missing or exits non-zero, the
/// write fails with a [StateError] — a secret is never left written at
/// loose permissions (on file-chmod failure, the just-written file is
/// deleted on a best-effort basis before the error propagates).
///
/// **Refuse predicate:** [read] throws [SecretPermissionException] when
/// `(fileMode & 0x1FF & 0o077 != 0) || (dirMode & 0x1FF & 0o077 != 0)` —
/// i.e. any group or world permission bit set on either the file or [root].
///
/// **Key:** [key] is used directly as the filename within [root] — no
/// encoding transform is needed. A store scoped to a single [root] cannot
/// have two distinct secrets collide on the same key, so distinct callers
/// simply address distinct keys.
final class DirectorySecretStore implements SecretStore {
  /// Creates a [DirectorySecretStore] rooted at [root].
  DirectorySecretStore({required this.root});

  /// Resolves the [SecretStore] appropriate for the current platform,
  /// rooted at the per-user profile config directory.
  ///
  /// - Windows: `%APPDATA%\kmdb` (falling back to
  ///   `%USERPROFILE%\AppData\Roaming\kmdb` if `APPDATA` is unset, which can
  ///   happen in minimal/CI environments).
  /// - POSIX: `~/.config/kmdb` (using the `HOME` environment variable; falls
  ///   back to `.` if unset).
  ///
  /// This is the controlled location review finding C-1 required: unlike
  /// the former `{dbDir}/local/`-rooted `DirectoryCredentialStore`, the
  /// profile directory reliably inherits the OS's restrictive per-user ACLs
  /// on Windows, where this store performs no `chmod`/`stat` enforcement of
  /// its own.
  factory DirectorySecretStore.forPlatform() =>
      DirectorySecretStore(root: _defaultRoot());

  /// The directory secrets are stored directly under.
  final String root;

  /// The permission bits enforced on [root] (owner: read/write/execute;
  /// group/world: none).
  static const int _dirMode = 0x1C0; // 0o700

  /// The permission bits enforced on each secret file (owner: read/write;
  /// group/world: none).
  static const int _fileMode = 0x180; // 0o600

  /// Mask isolating the standard POSIX permission bits (rwxrwxrwx) from the
  /// higher bits `FileStat.mode` may also carry (e.g. file-type bits).
  static const int _permMask = 0x1FF; // 0o777

  /// Mask isolating the group/world permission bits — any bit set here
  /// means the entity is readable, writable, or executable by someone other
  /// than the owner.
  static const int _groupWorldMask = 0x3F; // 0o077

  String _keyPath(String key) => p.join(root, key);

  @override
  Future<void> write(String key, Uint8List value) async {
    final rootDir = Directory(root);
    await rootDir.create(recursive: true);

    // Directory-first chmod ordering closes the exposure window: dart:io
    // cannot create a file at a restrictive mode directly, so tightening
    // root to owner-only *before* the file is written means the file is
    // never reachable by path by another user, even during the brief
    // interval before the file itself is chmod'd.
    if (!Platform.isWindows) {
      await _chmod(rootDir.path, '700');
    }

    final file = File(_keyPath(key));
    await file.writeAsBytes(value);

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
  Future<Uint8List?> read(String key) async {
    final file = File(_keyPath(key));
    if (!await file.exists()) return null;

    if (!Platform.isWindows) {
      final fileStat = await file.stat();
      final fileMode = fileStat.mode & _permMask;
      if (fileMode & _groupWorldMask != 0) {
        throw SecretPermissionException(
          path: file.path,
          actualMode: fileMode,
          expectedMode: _fileMode,
        );
      }

      final dirStat = await Directory(root).stat();
      final dirMode = dirStat.mode & _permMask;
      if (dirMode & _groupWorldMask != 0) {
        throw SecretPermissionException(
          path: root,
          actualMode: dirMode,
          expectedMode: _dirMode,
        );
      }
    }

    return file.readAsBytes();
  }

  @override
  Future<void> delete(String key) async {
    final file = File(_keyPath(key));
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<List<String>> list() async {
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return [];

    // Enumerate only regular files directly under root — a store that has
    // never been written to (root does not exist) returns empty above, and
    // any unexpected subdirectory is not a secret this store manages.
    final keys = <String>[];
    await for (final entity in rootDir.list()) {
      if (entity is File) {
        keys.add(p.basename(entity.path));
      }
    }
    return keys;
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
        'available ($e). Secrets cannot be safely stored without '
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

  /// Resolves the default profile-directory root — see
  /// [DirectorySecretStore.forPlatform].
  static String _defaultRoot() {
    // coverage:ignore-start
    // The whole Platform.isWindows branch is untestable on this automated
    // suite's macOS/Linux CI (Platform.isWindows is always false there) —
    // same class of gap as DirectoryCredentialStore's Windows-only test
    // group before it, which is skip:-guarded rather than fake-covered.
    // RC-24 in docs/spec/28_release_checklist.md covers the manual
    // real-Windows verification this cannot exercise.
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return p.join(appData, 'kmdb');
      }
      // APPDATA is unset only in unusual/minimal Windows environments.
      final userProfile = Platform.environment['USERPROFILE'] ?? '.';
      return p.join(userProfile, 'AppData', 'Roaming', 'kmdb');
    }
    // coverage:ignore-end
    final home = Platform.environment['HOME'] ?? '.';
    return p.join(home, '.config', 'kmdb');
  }
}
