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

/// Forces a full re-extraction and re-indexing of all vault blobs.
///
/// Queues every known vault blob (including those already indexed) as
/// `pending`, resetting their extraction status. Indexing proceeds
/// asynchronously after the command returns — use `vault status` to monitor
/// progress.
///
/// Useful after changing the embedding model (`embeddingModel` in
/// `local/config.json`) to invalidate vector indexes without waiting for the
/// model-version check on the next database open.
///
/// Usage:
/// ```
/// kmdb <db> vault reindex
/// ```
final class VaultReindexCommand extends CliCommand {
  /// Creates a [VaultReindexCommand].
  const VaultReindexCommand();

  @override
  String get name => 'reindex';

  @override
  String get description =>
      'Force full re-extraction and re-indexing of all vault blobs. '
      'Indexing proceeds asynchronously after this command returns.';

  @override
  String get usage => 'vault reindex';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (ctx.vaultStore == null) {
      ctx.writeError('Vault is not available for this database.');
      return false;
    }

    // Verify vault search is configured.
    if (ctx.db.vaultSearchManager == null) {
      ctx.writeError(
        'Vault search is not configured for this database. '
        'Open the database with vaultSearch: VaultSearchConfig() to enable it.',
      );
      return false;
    }

    final int queued;
    try {
      queued = await ctx.db.reindexVault();
    } catch (e) {
      ctx.writeError('vault reindex: $e');
      return false;
    }

    if (queued == 0) {
      ctx.out.writeln(
        'No vault blobs to re-index — vault is empty or no blobs are indexed.',
      );
    } else {
      ctx.out.writeln(
        'Queued $queued vault blob${queued == 1 ? '' : 's'} for re-extraction '
        'and re-indexing.',
      );
      ctx.out.writeln(
        'Indexing proceeds asynchronously. '
        'Run "vault status" to monitor progress.',
      );
    }

    return true;
  }
}
