// Copyright 2026 The KMDB Authors.
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

import 'package:uuid/uuid.dart';

import '../config/kmdb_config.dart';
import 'command.dart';

/// Assigns a fresh device identity to the database.
///
/// When a database directory is copied (e.g. for staging or testing) both
/// the original and the copy share the same device ID. This prevents sync
/// from working correctly because the sync engine cannot distinguish between
/// SSTables produced by two physically separate databases.
///
/// This command:
///
/// 1. Reads the current device ID from the open store.
/// 2. Generates a new random 8-character hex device ID.
/// 3. Renames all local SSTables from `{oldId}-...` to `{newId}-...`.
/// 4. Updates the device ID record in `$meta`.
/// 5. Outputs `{ "oldDeviceId": "…", "newDeviceId": "…" }` as JSON.
///
/// ## Remote warning
///
/// If the database has configured sync remotes (in `{dbDir}/local/config.json`)
/// the command prints a warning to stderr: the remote's
/// `highwater/{oldDeviceId}.hwm` file must be deleted manually, otherwise the
/// remote will re-send data the device has already seen.
///
/// ## Usage
///
/// ```bash
/// kmdb <db> new-device-id
/// ```
final class NewDeviceIdCommand extends CliCommand {
  /// Creates a [NewDeviceIdCommand].
  const NewDeviceIdCommand();

  @override
  String get name => 'new-device-id';

  @override
  bool get replVisible => false;

  @override
  String get description =>
      'Generate a new device identity for this database copy.';

  @override
  String get usage => 'new-device-id';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    // Read the current device ID before the reassign.
    final info = await ctx.store.storeInfo();
    final oldDeviceId = info.deviceId;

    // Generate a new random device ID using the same algorithm as DeviceId.load:
    // first 8 chars of a hyphen-stripped UUIDv4, which gives ~4 billion unique
    // values with negligible same-millisecond collision probability.
    final newDeviceId = const Uuid().v4().replaceAll('-', '').substring(0, 8);

    // Warn if configured remotes exist — their highwater mark files will be
    // orphaned until manually removed from the remote sync folder.
    final dbDir = info.dbDir;
    final KmdbConfig config;
    try {
      config = await KmdbConfig.load(dbDir);
    } on FormatException catch (e) {
      ctx.writeError('new-device-id: failed to load config: ${e.message}');
      return false;
    }

    if (config.remotes.isNotEmpty) {
      // Alert on stderr so the JSON output on stdout remains machine-parseable.
      ctx.err.writeln(
        'Warning: this database has ${config.remotes.length} configured '
        'remote(s). After syncing with the new device ID, delete the stale '
        'highwater mark file(s) from each remote sync folder:\n'
        '  highwater/$oldDeviceId.hwm',
      );
    }

    // Perform the rename — flushes the memtable, renames SSTables, and updates
    // $meta. Any crash before this point leaves the database unchanged.
    try {
      await ctx.store.reassignDeviceId(newDeviceId);
    } on ArgumentError catch (e) {
      ctx.writeError('new-device-id: $e');
      return false;
    }

    ctx.writeValue({'oldDeviceId': oldDeviceId, 'newDeviceId': newDeviceId});
    return true;
  }
}
