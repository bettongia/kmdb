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

import 'command.dart';

/// Rebuilds all stale vector (`$vec:`) search indexes in the foreground.
///
/// ## Usage
///
/// ```
/// kmdb <db> reindex
/// ```
///
/// ## Description
///
/// Iterates every declared vector index definition and rebuilds any that are
/// in `stale` or `undefined` state by running inference over the entire
/// collection. This is a synchronous foreground operation — it blocks until
/// all indexes are rebuilt.
///
/// This command is **vec-only** — it does not touch FTS (BM25) indexes.
///
/// `reindex` is one of the command tokens `cli_runner.dart` gates real
/// embedding-model construction on (WI-12 Phase B, Q6) — running this
/// command against a database with `embeddingModel` configured always loads
/// a real model first, regardless of whether any `vecIndex` is registered
/// yet, so [CommandContext.db]'s [KmdbDatabase.vecManager] reflects genuine
/// index state here, not a stub.
///
/// If no embedding model is configured in `local/config.json`, the command
/// prints an informational message and exits with code 0 without attempting
/// to load one. If a model *is* configured but no `vecIndex` has been
/// registered (`search create --semantic`), [KmdbDatabase.reindex] itself
/// reports zero rebuilt indexes — there's nothing to rebuild yet, not an
/// error.
///
/// ## When to use
///
/// Run `kmdb reindex` after changing the `embeddingModel.modelId` in
/// `local/config.json` to force an immediate rebuild rather than waiting for
/// the first `search` query to trigger it lazily.
final class ReindexCommand extends CliCommand {
  /// Creates a [ReindexCommand].
  const ReindexCommand();

  @override
  String get name => 'reindex';

  @override
  String get description =>
      r'Rebuild all stale vector ($vec:) search indexes in the foreground.';

  @override
  String get usage => 'reindex';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    // When no embedding model is configured there are no vector indexes to
    // rebuild. Print an informational message and exit 0 (not an error).
    // config.embeddingModel is checked directly (not ctx.db.vecManager)
    // because a model with no vecIndexes registered yet is a different,
    // non-error case — ctx.db.reindex() below already handles it correctly
    // by reporting zero rebuilt indexes.
    if (ctx.config.embeddingModel == null) {
      ctx.out.writeln(
        'No embedding model configured — no vector indexes to rebuild.\n'
        'Add an embeddingModel to local/config.json and run reindex again '
        'to build vector indexes (a real model is loaded automatically for '
        'this command).',
      );
      return true;
    }

    ctx.out.writeln('Rebuilding stale vector indexes…');

    final int rebuilt;
    try {
      rebuilt = await ctx.db.reindex();
    } catch (e) {
      ctx.writeError('reindex: failed: $e');
      return false;
    }

    if (rebuilt == 0) {
      ctx.out.writeln('No stale vector indexes found — nothing to rebuild.');
    } else {
      ctx.out.writeln(
        'Rebuilt $rebuilt vector index${rebuilt == 1 ? '' : 'es'}.',
      );
    }
    return true;
  }
}
