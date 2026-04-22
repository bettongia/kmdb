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

import 'command.dart';

/// Creates or verifies a KMDB database at the given path.
///
/// Because the CLI opens the database before dispatching any command, running
/// `init` is sufficient to create the database directory and assign the
/// device identity. Running `init` against an existing database is harmless —
/// it reports the same result but sets `created` to `false`.
///
/// Output fields:
/// - `path` — absolute path of the database directory.
/// - `deviceId` — stable 8-character hex device identity.
/// - `created` — `true` if the database was freshly created this session,
///   `false` if an existing database was reopened.
///
/// Usage: `kmdb <db> init`
final class InitCommand extends CliCommand {
  const InitCommand();

  @override
  String get name => 'init';

  @override
  String get description =>
      'Create a new database or verify an existing one. '
      'Outputs path, deviceId, and whether the database was created.';

  @override
  String get usage => 'init';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final info = await ctx.store.storeInfo();
    ctx.writeValue({
      'path': info.dbDir,
      'deviceId': info.deviceId,
      'created': ctx.dbCreated,
    });
    return true;
  }
}
