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

import 'package:kmdb/kmdb.dart';

import '../command.dart';

/// Searches vault blob content for a query string.
///
/// Results are limited to blobs that have been downloaded and indexed on this
/// device. When [VaultIndexingStatus.stub] > 0, search results may be silently
/// incomplete (stub blobs are not included).
///
/// Usage:
/// ```
/// kmdb <db> vault search <query> --collection <name>
/// kmdb <db> vault search <query> --collection <name> --mode lexical --limit 20
/// ```
final class VaultSearchCommand extends CliCommand {
  /// Creates a [VaultSearchCommand].
  const VaultSearchCommand();

  @override
  String get name => 'search';

  @override
  String get description =>
      'Search vault blob content for a query. '
      'Requires --collection. '
      'Results are limited to indexed blobs on this device.';

  @override
  String get usage => 'vault search <query> --collection <name>';

  @override
  void configureArgParser(ArgParser parser) {
    parser
      ..addOption(
        'collection',
        abbr: 'c',
        valueHelp: 'name',
        help: 'Collection name to search vault blobs for (required)',
      )
      ..addOption(
        'mode',
        valueHelp: 'auto|lexical|semantic',
        help: 'Search mode (default: auto)',
        allowed: ['auto', 'lexical', 'semantic'],
      )
      ..addOption(
        'limit',
        valueHelp: 'n',
        help: 'Maximum hits to return (default: 10)',
      )
      ..addOption(
        'offset',
        valueHelp: 'n',
        help: 'Number of top results to skip (default: 0)',
      );
  }

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (ctx.vaultStore == null) {
      ctx.writeError(
        'Vault is not available for this database. '
        'Vault search requires a vault store configured at database open time.',
      );
      return false;
    }

    // Validate --collection flag.
    final collection = (flags['collection'] as String?)?.trim();
    if (collection == null || collection.isEmpty) {
      ctx.writeError(
        'vault search requires --collection <name>.\nUsage: $usage',
      );
      return false;
    }

    // Validate positional query argument.
    if (args.isEmpty) {
      ctx.writeError('vault search requires a query argument.\nUsage: $usage');
      return false;
    }
    final query = args.join(' ');

    // Parse --mode (default: auto).
    final modeStr = (flags['mode'] as String?)?.trim() ?? 'auto';
    final SearchMode mode;
    switch (modeStr) {
      case 'lexical':
        mode = SearchMode.lexical;
      case 'semantic':
        mode = SearchMode.semantic;
      default:
        mode = SearchMode.auto;
    }

    // Parse --limit and --offset.
    final limit = _parseInt(flags['limit']) ?? 10;
    final offset = _parseInt(flags['offset']) ?? 0;

    if (limit < 1) {
      ctx.writeError('vault search: --limit must be >= 1.');
      return false;
    }
    if (offset < 0) {
      ctx.writeError('vault search: --offset must be >= 0.');
      return false;
    }

    // Check whether vault search is configured.
    final manager = ctx.db.vaultSearchManager;
    if (manager == null) {
      ctx.writeError(
        'Vault search is not configured for this database. '
        'Open the database with vaultSearch: VaultSearchConfig() to enable it.',
      );
      return false;
    }

    // Perform the vault content search via searchVault().
    // The collection is opened as raw (untyped Map) so the CLI does not need
    // schema knowledge; documents are decoded as Map<String, dynamic>.
    final col = ctx.rawCollection(collection);

    final VaultSearchResult<Map<String, dynamic>> result;
    try {
      result = await col.searchVault(
        query,
        mode: mode,
        limit: limit,
        offset: offset,
      );
    } catch (e) {
      ctx.writeError('vault search: $e');
      return false;
    }

    // Warn when stub blobs may have been skipped.
    final status = await ctx.db.vaultIndexingStatus();
    if (status.stub > 0) {
      ctx.err.writeln(
        'Warning: ${status.stub} vault blob${status.stub == 1 ? '' : 's'} '
        'not yet downloaded on this device — search results may be incomplete.',
      );
    }

    final hits = result.hits;
    if (hits.isEmpty) {
      ctx.out.writeln(
        'No vault search results for "${_truncate(query, 60)}" '
        'in $collection.',
      );
      return true;
    }

    // Print a table of hits: rank, score, snippet, doc id.
    ctx.out.writeln(
      'Vault search results for "${_truncate(query, 60)}" in $collection '
      '(${result.metadata.total} total, showing ${hits.length}):',
    );
    ctx.out.writeln('');

    for (final hit in hits) {
      final snip = _truncate(hit.chunkContext.snippet, 200);
      ctx.out.writeln(
        '[${hit.rank}] score=${hit.score.toStringAsFixed(4)} '
        'id=${hit.id}',
      );
      ctx.out.writeln(
        '    field: ${hit.chunkContext.fieldPath}  '
        'chunk: ${hit.chunkContext.chunkIndex + 1}/${hit.chunkContext.totalChunks}',
      );
      ctx.out.writeln('    "$snip"');
      ctx.out.writeln('');
    }

    return true;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Parses [value] as a positive integer. Returns `null` for `null` input;
  /// returns `-1` for unparseable input (callers must guard against it).
  static int? _parseInt(Object? value) {
    if (value == null) return null;
    return int.tryParse(value.toString().trim());
  }

  /// Truncates [s] to at most [maxLen] characters, appending `'…'` when cut.
  static String _truncate(String s, int maxLen) {
    if (s.length <= maxLen) return s;
    return '${s.substring(0, maxLen)}…';
  }
}
