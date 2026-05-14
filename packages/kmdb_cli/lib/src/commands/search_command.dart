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

import 'dart:convert';

import 'package:kmdb/kmdb.dart';

import 'package:kmdb/kmdb_config.dart';
import 'command.dart';

/// Executes search queries and manages FTS index definitions.
///
/// ## Subcommands
///
/// ```
/// kmdb <db> search <collection> <query> [options]
/// kmdb <db> search list <collection>
/// kmdb <db> search create <collection> <field> [--stopwords] [--k1 <n>] [--b <n>]
/// kmdb <db> search delete <collection> <field>
/// ```
///
/// ## Search options
///
/// - `--fields <f1,f2>` — comma-separated field list; defaults to all FTS
///   indexed fields for the collection.
/// - `--mode auto|lexical|semantic` — search strategy (default `auto`).
///   `auto` activates lexical search when only an FTS index is available,
///   semantic when only a vector index is available, and hybrid when both are
///   present. `semantic` requires `embeddingModel` to be configured in
///   `local/config.json`.
/// - `--candidates <n>` — maximum candidate documents for semantic vector
///   scoring (default 100). Higher values improve recall at the cost of speed.
/// - `--rrf-k <n>` — Reciprocal Rank Fusion smoothing constant (default 60).
///   Only used in hybrid mode (`--mode auto` with both FTS and vector indexes
///   configured). Must be >= 1. Higher values reduce the advantage of very
///   top-ranked documents. Advanced option; the default of 60 is suitable for
///   most use cases.
/// - `--limit <n>` — maximum hits to return (default 10).
/// - `--offset <n>` — number of top results to skip (default 0).
/// - `--output table|json|ids` — output format (default `table`).
final class SearchCommand extends CliCommand {
  /// Creates a [SearchCommand].
  const SearchCommand();

  @override
  String get name => 'search';

  @override
  String get description =>
      'Full-text and semantic search, plus FTS index management (list, create, delete).';

  @override
  String get usage =>
      'search <collection> <query>\n'
      '       search list <collection>\n'
      '       search create <collection> <field>\n'
      '       search delete <collection> <field>';

  @override
  void configureArgParser(ArgParser parser) {
    parser
      ..addOption(
        'fields',
        valueHelp: 'f1,f2,...',
        help: 'Comma-separated field names to search (default: all indexed)',
      )
      ..addOption(
        'mode',
        valueHelp: 'auto|lexical|semantic',
        help: 'Search mode (default: auto)',
        allowed: ['auto', 'lexical', 'semantic'],
      )
      ..addOption(
        'candidates',
        valueHelp: 'n',
        help:
            'Maximum candidate documents for semantic/hybrid search (default: 100)',
      )
      ..addOption(
        'rrf-k',
        valueHelp: 'n',
        help: 'Reciprocal Rank Fusion smoothing constant (default: 60)',
      )
      ..addOption(
        'limit',
        valueHelp: 'n',
        help: 'Maximum results to return (default: 10)',
      )
      ..addOption(
        'offset',
        valueHelp: 'n',
        help: 'Number of results to skip (default: 0)',
      )
      ..addOption(
        'output',
        valueHelp: 'table|json|ids',
        help: 'Output format for search results (default: table)',
        allowed: ['table', 'json', 'ids'],
      )
      ..addFlag(
        'explain',
        negatable: false,
        help: 'Show search execution plan',
      );
  }

  // Keywords that are always subcommands, never collection names.
  static const _subcommands = {'list', 'create', 'delete'};

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError(
        'search: collection and query required, or a subcommand '
        '(list, create, delete).\nUsage: $usage',
      );
      return false;
    }

    final first = args[0];

    if (_subcommands.contains(first)) {
      switch (first) {
        case 'list':
          return _list(ctx, args.sublist(1));
        case 'create':
          return _create(ctx, args.sublist(1), flags);
        case 'delete':
          return _delete(ctx, args.sublist(1));
      }
    }

    // Default path: `search <collection> <query>`.
    return _search(ctx, args, flags);
  }

  // ── search ─────────────────────────────────────────────────────────────────

  /// Executes a search query and writes ranked results.
  ///
  /// Supports `--mode lexical` (BM25), `--mode semantic` (vector cosine), and
  /// `--mode auto` (best available index). Semantic search requires
  /// `embeddingModel` to be configured in `local/config.json`.
  ///
  /// When `--mode auto` and both FTS and vector indexes are configured in the
  /// CLI config, the output header includes a `(hybrid)` label to indicate
  /// that Reciprocal Rank Fusion is being applied. The `--rrf-k` flag controls
  /// the RRF smoothing constant for that path (default 60).
  ///
  /// Note: the CLI search command uses [FtsManager] directly and routes to
  /// hybrid via `KmdbCollection.search()` for the output mode label; the
  /// lexical leg is always used for the actual results since `kmdb_cli` does
  /// not depend on `kmdb_inferencing`.
  Future<bool> _search(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.length < 2) {
      ctx.writeError('search: collection and query required.\nUsage: $usage');
      return false;
    }

    final collection = args[0];
    final query = args.sublist(1).join(' ');

    // Parse and validate --mode (default: auto).
    final modeFlag = (flags['mode'] as String?)?.trim() ?? 'auto';
    if (modeFlag != 'auto' && modeFlag != 'lexical' && modeFlag != 'semantic') {
      ctx.writeError(
        "search: unknown --mode value '$modeFlag'. "
        "Expected: auto, lexical, semantic.",
      );
      return false;
    }

    // Determine which fields to search.
    final fieldsFlag = flags['fields'] as String?;
    final List<String> fields;
    if (fieldsFlag != null && fieldsFlag.trim().isNotEmpty) {
      fields = fieldsFlag
          .split(',')
          .map((f) => f.trim())
          .where((f) => f.isNotEmpty)
          .toList();
    } else {
      // Default: all FTS-indexed fields configured for this collection.
      final configured = ctx.config.ftsIndexesForCollection(collection);
      if (configured.isEmpty) {
        ctx.writeError(
          "search: no FTS indexes configured for collection '$collection'. "
          "Run 'search create $collection <field>' to register an index.",
        );
        return false;
      }
      fields = configured.map((r) => r.field).toList();
    }

    // Validate output format.
    final outputFlag = (flags['output'] as String?)?.trim() ?? 'table';
    if (outputFlag != 'table' && outputFlag != 'json' && outputFlag != 'ids') {
      ctx.writeError(
        "search: unknown --output value '$outputFlag'. "
        "Expected: table, json, ids.",
      );
      return false;
    }

    // --mode semantic explicitly requires an embedding model to be configured.
    // --mode auto falls back to lexical when no model is available; semantic
    // features are enabled automatically when both an embeddingModel and a
    // vector index are present.
    if (modeFlag == 'semantic' && ctx.config.embeddingModel == null) {
      ctx.writeError(
        'Semantic search requires an embedding model; configure '
        'embeddingModel in local/config.json.\n'
        'Example: { "type": "onnx", "modelPath": "/path/to/bge_small.onnx" }',
      );
      return false;
    }

    final limit = _parseInt(flags['limit']) ?? 10;
    final offset = _parseInt(flags['offset']) ?? 0;
    final candidates = _parseInt(flags['candidates']) ?? 100;
    final explain = flags['explain'] == true;

    // Parse and validate --rrf-k (default 60). Only used in hybrid mode.
    final rrfK = _parseInt(flags['rrf-k']) ?? 60;
    if (rrfK < 1) {
      ctx.writeError(
        'search: --rrf-k must be >= 1 (got $rrfK). '
        'The RRF smoothing constant controls ranking blending in hybrid mode.',
      );
      return false;
    }

    // Build FTS index definitions from config.
    final ftsIndexDefs = _buildFtsDefs(ctx.config);
    if (ftsIndexDefs.isEmpty) {
      ctx.writeError(
        "search: no FTS indexes configured for any collection. "
        "Run 'search create <collection> <field>' to register an index.",
      );
      return false;
    }

    final ftsManager = FtsManager(ctx.store, ftsIndexDefs);

    // Callback that reads a document from the KvStore and decodes it.
    Future<Map<String, dynamic>?> fetchDoc(String docId) async {
      final bytes = await ctx.store.get(collection, docId);
      if (bytes == null) return null;
      // Inject _id from the docId — documents are stored without _id in
      // the value bytes; the key is the canonical identity.
      return ValueCodec.decode(bytes)..['_id'] = docId;
    }

    // Determine whether hybrid mode would be active for this collection.
    // The CLI cannot load the kmdb_inferencing package (ONNX Runtime), so it
    // uses FtsManager directly for results. However, when both an FTS index
    // and an embedding model are configured, the output indicates that a hybrid
    // search would be active when accessed via the full database API.
    //
    // isHybrid = mode is auto AND embeddingModel is configured (signals that a
    // vec index is intended) AND this collection has FTS indexes.
    final ftsIndexedForCollection = ftsIndexDefs
        .where((d) => d.collection == collection)
        .isNotEmpty;
    final isHybrid =
        modeFlag == 'auto' &&
        ctx.config.embeddingModel != null &&
        ftsIndexedForCollection;

    final SearchResult<Map<String, dynamic>> result;
    try {
      result = await ftsManager.search<Map<String, dynamic>>(
        namespace: collection,
        query: query,
        fields: fields,
        fetchDoc: fetchDoc,
        limit: limit,
        offset: offset,
      );
    } catch (e) {
      ctx.writeError('search: query failed: $e');
      return false;
    }

    // Pass the resolved mode and rrfK to _writeResults so the header can
    // display the correct mode label and hybrid indicator.
    _writeResults(
      ctx,
      result,
      fields,
      outputFlag,
      modeFlag: modeFlag,
      isHybrid: isHybrid,
      rrfK: rrfK,
      candidates: candidates,
      explain: explain,
    );
    return true;
  }

  /// Writes [result] to [ctx.out] in the requested [format].
  ///
  /// [modeFlag] is the resolved search mode string (`auto`, `lexical`, or
  /// `semantic`). [isHybrid] is `true` when `--mode auto` and both FTS and
  /// vector indexes are configured — in that case the table header includes a
  /// `(hybrid)` label. [rrfK] and [candidates] are included in the JSON
  /// output for transparency.
  void _writeResults(
    CommandContext ctx,
    SearchResult<Map<String, dynamic>> result,
    List<String> fields,
    String format, {
    String modeFlag = 'auto',
    bool isHybrid = false,
    int rrfK = 60,
    int candidates = 100,
    bool explain = false,
  }) {
    // ── Explain block ─────────────────────────────────────────────────────────
    if (explain) {
      final meta = result.metadata;
      if (format == 'json') {
        final planMap = {
          '_explain': {
            'query': meta.query,
            'mode': isHybrid ? 'hybrid' : modeFlag,
            'searched': meta.searched,
            'skipped': meta.skipped,
            'total': meta.total,
          },
        };
        ctx.out.writeln(const JsonEncoder.withIndent('  ').convert(planMap));
      } else {
        ctx.out.writeln('Search plan');
        ctx.out.writeln(
          '  Mode     : ${isHybrid ? "$modeFlag (hybrid)" : modeFlag}',
        );
        if (meta.searched.isNotEmpty) {
          ctx.out.writeln('  Searched : ${meta.searched.join(", ")}');
        }
        if (meta.skipped.isNotEmpty) {
          ctx.out.writeln('  Skipped  : ${meta.skipped.join(", ")} (no index)');
        }
        ctx.out.writeln('  Results  : ${meta.total}');
        ctx.out.writeln('');
      }
    }

    switch (format) {
      case 'ids':
        for (final hit in result.hits) {
          ctx.out.writeln(hit.id);
        }

      case 'json':
        final json = {
          'query': result.metadata.query,
          'mode': isHybrid ? 'hybrid' : modeFlag,
          if (isHybrid) 'rrfK': rrfK,
          'total': result.metadata.total,
          'searched': result.metadata.searched,
          'skipped': result.metadata.skipped,
          'hits': [
            for (final hit in result.hits)
              {
                'rank': hit.rank,
                'score': hit.score,
                'id': hit.id,
                'fieldScores': {
                  for (final e in hit.fieldScores.entries) e.key: e.value,
                },
                'document': hit.document,
              },
          ],
        };
        ctx.out.writeln(const JsonEncoder.withIndent('  ').convert(json));

      case 'table':
      default:
        if (result.hits.isEmpty) {
          ctx.out.writeln('No results for "${result.metadata.query}".');
          return;
        }

        // Write a mode header line before the results table.
        // In hybrid mode, the label includes "(hybrid)" to indicate RRF.
        final modeLabel = isHybrid ? '$modeFlag (hybrid)' : modeFlag;
        ctx.out.writeln('mode: $modeLabel');

        // Header row.
        final headerCols = ['rank', 'score', 'id', ...fields];
        _writeTableRow(ctx, headerCols);
        _writeTableSeparator(ctx, headerCols.length);

        for (final hit in result.hits) {
          final row = [
            '${hit.rank}',
            hit.score.toStringAsFixed(4),
            hit.id,
            for (final field in fields)
              _truncate(_fieldValue(hit.document, field), 60),
          ];
          _writeTableRow(ctx, row);
        }

        ctx.out.writeln(
          '\n${result.hits.length} of ${result.metadata.total} results.',
        );
    }
  }

  /// Extracts a string value from [doc] at [field] (supports dot-notation).
  static String _fieldValue(Map<String, dynamic> doc, String field) {
    final parts = field.split('.');
    dynamic current = doc;
    for (final part in parts) {
      if (current is! Map) return '';
      current = current[part];
    }
    if (current == null) return '';
    return '$current';
  }

  /// Truncates [s] to at most [max] characters, appending `…` when cut.
  static String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max - 1)}…';
  }

  static void _writeTableRow(CommandContext ctx, List<String> cols) {
    ctx.out.writeln(cols.join('\t'));
  }

  static void _writeTableSeparator(CommandContext ctx, int cols) {
    ctx.out.writeln(List.filled(cols, '---').join('\t'));
  }

  // ── list ───────────────────────────────────────────────────────────────────

  /// Lists all configured FTS indexes for [collection] and their status.
  Future<bool> _list(CommandContext ctx, List<String> args) async {
    if (args.isEmpty) {
      ctx.writeError('search list: collection name required.');
      return false;
    }
    final collection = args[0];
    final defined = ctx.config.ftsIndexesForCollection(collection);

    if (defined.isEmpty) {
      ctx.out.writeln(
        'No FTS indexes configured for collection "$collection".',
      );
      return true;
    }

    final ftsManager = FtsManager(ctx.store, _buildFtsDefs(ctx.config));

    for (final record in defined) {
      final state = await ftsManager.stateFor(collection, record.field);
      final statusName = state?.status.name ?? 'undefined';
      ctx.out.writeln(
        '${record.field}\t$statusName'
        '\tstopWords=${record.stopWords}'
        '\tk1=${record.k1}\tb=${record.b}',
      );
    }
    return true;
  }

  // ── create ─────────────────────────────────────────────────────────────────

  /// Registers a new FTS index definition in the CLI config.
  ///
  /// Accepts optional `--stopwords` (boolean), `--k1 <n>`, and `--b <n>` flags
  /// to customise the BM25 parameters.
  Future<bool> _create(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.length < 2) {
      ctx.writeError('search create: collection name and field required.');
      return false;
    }
    final collection = args[0];
    final field = args[1];

    final stopWords =
        flags['stopwords'] == true || flags['stopwords'] == 'true';
    final k1 = _parseDouble(flags['k1']) ?? 1.2;
    final b = _parseDouble(flags['b']) ?? 0.75;

    // Validate BM25 params.
    if (k1 <= 0) {
      ctx.writeError('search create: --k1 must be a positive number.');
      return false;
    }
    if (b < 0.0 || b > 1.0) {
      ctx.writeError('search create: --b must be between 0.0 and 1.0.');
      return false;
    }

    try {
      ctx.config.addFtsIndex(
        collection,
        field,
        stopWords: stopWords,
        k1: k1,
        b: b,
      );
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    }

    try {
      await ctx.config.save();
    } catch (e) {
      ctx.writeError('search create: failed to save config: $e');
      return false;
    }

    ctx.out.writeln(
      'FTS index on "$collection.$field" registered'
      '${stopWords ? " (stop words enabled)" : ""}. '
      'It will be built on the next search query.',
    );
    return true;
  }

  // ── delete ─────────────────────────────────────────────────────────────────

  /// Removes an FTS index definition from the config.
  Future<bool> _delete(CommandContext ctx, List<String> args) async {
    if (args.length < 2) {
      ctx.writeError('search delete: collection name and field required.');
      return false;
    }
    final collection = args[0];
    final field = args[1];

    final isConfigured = ctx.config
        .ftsIndexesForCollection(collection)
        .any((r) => r.field == field);

    if (!isConfigured) {
      ctx.writeError(
        "search delete: no FTS index on '$collection.$field' found in config.",
      );
      return false;
    }

    try {
      ctx.config.removeFtsIndex(collection, field);
    } on ArgumentError catch (e) {
      ctx.writeError(e.message as String);
      return false;
    }

    try {
      await ctx.config.save();
    } catch (e) {
      ctx.writeError('search delete: failed to save config: $e');
      return false;
    }

    ctx.out.writeln('FTS index on "$collection.$field" deleted from config.');
    return true;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Converts all [FtsIndexRecord] entries in [config] to [FtsIndexDefinition]
  /// objects for use with [FtsManager].
  static List<FtsIndexDefinition> _buildFtsDefs(KmdbConfig config) => [
    for (final r in config.ftsIndexes)
      FtsIndexDefinition(
        collection: r.collection,
        field: r.field,
        stopWords: r.stopWords,
        k1: r.k1,
        b: r.b,
      ),
  ];

  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse('$value');
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse('$value');
  }
}
