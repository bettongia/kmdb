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
import 'insert_command.dart';

/// Deprecated alias for [InsertCommand].
///
/// The `put` command was renamed to `insert` because `put` implies upsert
/// semantics (HTTP PUT), whereas this command always generates a new UUIDv7
/// key and ignores any `_id` in the payload — which is insert semantics.
///
/// Using `put` prints a deprecation warning to stderr and delegates to
/// [InsertCommand]. Update any scripts to use `insert` instead.
///
/// Usage: `kmdb <db> put <collection> [--value <json>] [--file <path>]`
final class PutCommand implements CliCommand {
  const PutCommand();

  @override
  String get name => 'put';

  @override
  String get description =>
      'Deprecated — use `insert` instead. '
      'Insert one or more documents.';

  @override
  String get usage => 'put <collection> [--value <json>] [--file <path>]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    // Emit deprecation warning to stderr before delegating.
    ctx.err.writeln('Warning: `put` is deprecated, use `insert` instead.');
    return const InsertCommand().execute(ctx, args, flags);
  }
}
