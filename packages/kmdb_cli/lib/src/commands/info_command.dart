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

/// Displays identifying information about the database instance.
///
/// Usage: `kmdb <db> info`
final class InfoCommand extends CliCommand {
  const InfoCommand();

  @override
  String get name => 'info';

  @override
  String get description => 'Show database identity and clock information.';

  @override
  String get usage => 'info';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    final i = await ctx.store.storeInfo();
    ctx.writeValue({
      'dbDir': i.dbDir,
      'deviceId': i.deviceId,
      'hlc': i.currentHlc,
    });
    return true;
  }
}
