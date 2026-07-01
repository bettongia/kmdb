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

/// Displays vault search indexing status as a summary table.
///
/// Shows counts for each indexing lifecycle state: total blobs known to this
/// device, indexed, pending, currently extracting, failed, unsupported media
/// type, and stub (not yet downloaded).
///
/// When [VaultIndexingStatus.stub] > 0, a warning is printed: search results
/// may be silently incomplete because stub blobs are excluded from indexing
/// and therefore from `vault search` results.
///
/// Usage:
/// ```
/// kmdb <db> vault status
/// ```
final class VaultStatusCommand extends CliCommand {
  /// Creates a [VaultStatusCommand].
  const VaultStatusCommand();

  @override
  String get name => 'status';

  @override
  String get description =>
      'Display vault search indexing status (counts per lifecycle state).';

  @override
  String get usage => 'vault status';

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

    // Retrieve indexing status.
    try {
      final status = await ctx.db.vaultIndexingStatus();

      // Print a structured status table.
      ctx.out.writeln('Vault search indexing status:');
      ctx.out.writeln('');
      ctx.out.writeln('  Total blobs:       ${status.total}');
      ctx.out.writeln('  Indexed:           ${status.indexed}');
      ctx.out.writeln('  Pending:           ${status.pending}');
      ctx.out.writeln('  Extracting:        ${status.extracting}');
      ctx.out.writeln('  Failed:            ${status.failed}');
      ctx.out.writeln('  Unsupported type:  ${status.unsupported}');
      ctx.out.writeln('  Stub (not downloaded): ${status.stub}');
      ctx.out.writeln('');

      // Status summary line.
      if (status.total == 0) {
        ctx.out.writeln('  Status: no vault blobs on this device.');
      } else if (status.isSearchComplete) {
        ctx.out.writeln(
          '  Status: complete — all blobs indexed and downloaded.',
        );
      } else if (status.isComplete && status.stub > 0) {
        ctx.out.writeln(
          '  Status: locally complete — but ${status.stub} stub '
          'blob${status.stub == 1 ? '' : 's'} not yet downloaded. '
          'Search results may be incomplete.',
        );
      } else if (status.pending > 0 || status.extracting > 0) {
        final remaining = status.pending + status.extracting;
        ctx.out.writeln(
          '  Status: in progress — $remaining blob${remaining == 1 ? '' : 's'} '
          'still queued or extracting.',
        );
      } else if (status.failed > 0) {
        ctx.out.writeln(
          '  Status: ${status.failed} blob${status.failed == 1 ? '' : 's'} '
          'failed extraction. Run "vault reindex" to retry.',
        );
      } else {
        ctx.out.writeln('  Status: idle.');
      }

      // Stub warning.
      if (status.stub > 0) {
        ctx.err.writeln(
          'Warning: ${status.stub} vault blob${status.stub == 1 ? '' : 's'} '
          'not yet downloaded — "vault search" results may be incomplete. '
          'Configure a sync remote and run "pull" to hydrate missing blobs.',
        );
      }
    } catch (e) {
      ctx.writeError('vault status: $e');
      return false;
    }

    return true;
  }
}
