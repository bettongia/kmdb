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

import '../command.dart';
import 'vault_export_command.dart';
import 'vault_get_command.dart';
import 'vault_reindex_command.dart';
import 'vault_search_command.dart';
import 'vault_status_command.dart';

/// Container command that groups all `vault` sub-commands.
///
/// Dispatches to sub-commands based on the first positional argument:
///
/// - `vault get <uri>` — fetch a vault object and write to stdout or file.
/// - `vault export <uri> --output <path>` — write a vault object to a file.
/// - `vault search <query> --collection <name>` — search vault blob content.
/// - `vault reindex` — queue all vault blobs for re-extraction and indexing.
/// - `vault status` — display vault search indexing status.
///
/// `vault help` (or bare `vault` with no args at all — the two are
/// equivalent) prints a name/usage/description summary of every sub-command
/// without requiring an open vault store, since it describes usage rather
/// than touching vault state. Every other sub-command requires
/// [CommandContext.vaultStore] to be non-null; reports an error if the
/// database was opened without a vault store.
///
/// Usage: `kmdb <db> vault <sub-command> [args...]`
final class VaultCommand extends CliCommand {
  const VaultCommand();

  static const _subCommands = <String, CliCommand>{
    'get': VaultGetCommand(),
    'export': VaultExportCommand(),
    'search': VaultSearchCommand(),
    'reindex': VaultReindexCommand(),
    'status': VaultStatusCommand(),
  };

  @override
  String get name => 'vault';

  @override
  String get description =>
      'Vault object operations. '
      'Sub-commands: get, export, search, reindex, status. '
      'Use "vault help" for details.';

  @override
  String get usage => 'vault <sub-command> [args...]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    // `vault help` (or bare `vault` with no args) is answered before the
    // vault-store guard below, since it describes usage rather than touching
    // vault state and should work even when the database has no vault
    // configured.
    if (args.isEmpty || args[0] == 'help') {
      ctx.out.writeln('Usage: $usage\n');
      for (final sub in _subCommands.values) {
        ctx.out.writeln('  ${sub.usage}\n    ${sub.description}');
      }
      return true;
    }

    // Guard: vault commands require an open vault store.
    if (ctx.vaultStore == null) {
      ctx.writeError(
        'Vault is not available for this database. '
        'Vault storage is initialised automatically when files are first '
        'ingested via "vault ingest" or "--import".',
      );
      return false;
    }

    final subName = args[0];
    final sub = _subCommands[subName];
    if (sub == null) {
      ctx.writeError(
        "Unknown vault sub-command '$subName'. "
        "Available sub-commands: ${_subCommands.keys.join(', ')}",
      );
      return false;
    }

    // Pass remaining positional args and all flags to the sub-command.
    return sub.execute(ctx, args.sublist(1), flags);
  }
}
