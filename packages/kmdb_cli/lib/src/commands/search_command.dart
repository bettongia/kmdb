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

/// Executes search queries and manages FTS and vector index definitions.
///
/// ## Subcommands
///
/// ```
/// kmdb <db> search <collection> <query> [options]
/// kmdb <db> search list <collection>
/// kmdb <db> search create <collection> <field> [--fts | --semantic] [--stopwords] [--k1 <n>] [--b <n>]
/// kmdb <db> search delete <collection> <field> [--fts | --semantic]
/// ```
///
/// ## Index registration (`search create`/`search delete`)
///
/// `search create` registers **both** an FTS index and a vector (semantic)
/// index for the field by default — "search create turns on search for a
/// field" is one mental model, rather than a parallel `vecIndex create`
/// command family. `--fts` and `--semantic` are narrowing flags: passing
/// either alone limits registration/removal to just that type; passing both
/// explicitly is equivalent to the no-flag default. `search list` shows both
/// registrations for a field; `search delete` removes both by default, or
/// just one with `--fts`/`--semantic`.
///
/// A vector index requires `embeddingModel` to be configured in
/// `local/config.json` — `search create` does not hard-fail without one
/// (config is written and stays lexical-only until a model is added), but
/// prints a warning. Note the generic flag parser
/// (`cli_runner._dispatchTokens`) treats `--flag <positional>` as consuming
/// the positional as the flag's value, so `--fts`/`--semantic` must follow
/// the positional args (same pre-existing footgun as `--stopwords`).
///
/// ## Search options
///
/// - `--fields <f1,f2>` — comma-separated field list; defaults to the union
///   of FTS- and vector-indexed fields for the collection.
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
      'Full-text and semantic search, plus FTS/vector index management (list, create, delete).';

  @override
  String get usage =>
      'search <collection> <query>\n'
      '       search list <collection>\n'
      '       search create <collection> <field> [--fts | --semantic]\n'
      '       search delete <collection> <field> [--fts | --semantic]';

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
      ..addFlag('explain', negatable: false, help: 'Show search execution plan')
      ..addFlag(
        'fts',
        negatable: false,
        help:
            "search create/delete: limit to the FTS (lexical) index only "
            "(default: both FTS and semantic)",
      )
      ..addFlag(
        'semantic',
        negatable: false,
        help:
            "search create/delete: limit to the vector (semantic) index "
            "only (default: both FTS and semantic)",
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
          return _delete(ctx, args.sublist(1), flags);
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
  /// `embeddingModel` to be configured in `local/config.json` (and, for
  /// document-field search specifically, a `vecIndex` registered for the
  /// field via `search create --semantic`).
  ///
  /// Calls the real [KmdbCollection.search] — genuine lexical, semantic, and
  /// hybrid (Reciprocal Rank Fusion) scoring, not a lexical-only
  /// approximation. The output mode label is computed deterministically from
  /// config presence rather than read off [SearchResult], which carries no
  /// resolved-mode field: for `--mode auto`, both an FTS and a vector index
  /// configured for the collection ⇒ `hybrid`; FTS only ⇒ `lexical`; vector
  /// only ⇒ `semantic`. An explicit `--mode lexical`/`--mode semantic` shows
  /// that mode directly.
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

    // Parse and validate --mode (default: auto), mapping the string flag
    // onto the SearchMode enum before it reaches KmdbCollection.search().
    // Names match auto/lexical/semantic exactly, so .byName is exact.
    final modeFlag = (flags['mode'] as String?)?.trim() ?? 'auto';
    final SearchMode mode;
    try {
      mode = SearchMode.values.byName(modeFlag);
    } on ArgumentError {
      ctx.writeError(
        "search: unknown --mode value '$modeFlag'. "
        "Expected: auto, lexical, semantic.",
      );
      return false;
    }

    // Determine which fields to search — default: the union of FTS- and
    // vector-indexed fields for the collection (mirrors
    // KmdbCollection.search()'s own default-field-resolution logic, needed
    // here up front for the "no indexes configured" guard and the results
    // table header).
    final fieldsFlag = flags['fields'] as String?;
    final List<String> fields;
    if (fieldsFlag != null && fieldsFlag.trim().isNotEmpty) {
      fields = fieldsFlag
          .split(',')
          .map((f) => f.trim())
          .where((f) => f.isNotEmpty)
          .toList();
    } else {
      final ftsFields = ctx.config
          .ftsIndexesForCollection(collection)
          .map((r) => r.field);
      final vecFields = ctx.config
          .vecIndexesForCollection(collection)
          .map((r) => r.field);
      final merged = {...ftsFields, ...vecFields}.toList();
      if (merged.isEmpty) {
        ctx.writeError(
          "search: no FTS or vector indexes configured for collection "
          "'$collection'. Run 'search create $collection <field>' to "
          "register one.",
        );
        return false;
      }
      fields = merged;
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
    // --mode auto falls back to lexical when no model/vecIndex is available.
    if (mode == SearchMode.semantic && ctx.config.embeddingModel == null) {
      ctx.writeError(
        'Semantic search requires an embedding model; configure '
        'embeddingModel in local/config.json.\n'
        'Example: { "type": "onnx", "modelId": "bge-small-en-v1.5" }',
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

    // A vector index's first query triggers a synchronous, foreground
    // full-collection embedding pass (§18) before results appear — the same
    // lazy-build convention ftsIndexes/vault indexes already have, just
    // potentially slower per-document (one ONNX inference call per document).
    // Print a one-line notice so this doesn't look like a hang. There is no
    // public API to check whether the index is *already* built (VecManager
    // exposes no per-field status getter, unlike FtsManager.stateFor), so
    // this prints whenever semantic scoring might run for the collection,
    // not strictly only on the very first build.
    if (mode != SearchMode.lexical &&
        ctx.config.vecIndexesForCollection(collection).isNotEmpty) {
      ctx.err.writeln(
        'Building semantic index for "$collection" fields if not already '
        'current — this may take a while for large collections.',
      );
    }

    final col = ctx.rawCollection(collection);
    final SearchResult<Map<String, dynamic>> result;
    try {
      result = await col.search(
        query,
        fields: fields,
        mode: mode,
        candidates: candidates,
        limit: limit,
        offset: offset,
        rrfK: rrfK,
      );
    } catch (e) {
      ctx.writeError('search: query failed: $e');
      return false;
    }

    // Config-derived, three-way mode label (deterministic — see the class
    // doc comment on _search for the exact rule). SearchMetadata carries no
    // resolved-mode field to read this off of.
    final String modeLabel;
    if (modeFlag == 'auto') {
      final hasFts = ctx.config.ftsIndexesForCollection(collection).isNotEmpty;
      final hasVec = ctx.config.vecIndexesForCollection(collection).isNotEmpty;
      modeLabel = hasFts && hasVec
          ? 'hybrid'
          : (hasVec ? 'semantic' : 'lexical');
    } else {
      modeLabel = modeFlag;
    }

    _writeResults(
      ctx,
      result,
      fields,
      outputFlag,
      modeLabel: modeLabel,
      rrfK: rrfK,
      candidates: candidates,
      explain: explain,
    );
    return true;
  }

  /// Writes [result] to [ctx.out] in the requested [format].
  ///
  /// [modeLabel] is the fully-resolved mode label to display — `lexical`,
  /// `semantic`, or `hybrid` — already computed by the caller (see
  /// [_search]'s doc comment for the config-derived resolution rule). [rrfK]
  /// is included in the JSON output only when [modeLabel] is `hybrid`.
  void _writeResults(
    CommandContext ctx,
    SearchResult<Map<String, dynamic>> result,
    List<String> fields,
    String format, {
    required String modeLabel,
    int rrfK = 60,
    int candidates = 100,
    bool explain = false,
  }) {
    final isHybrid = modeLabel == 'hybrid';

    // ── Explain block ─────────────────────────────────────────────────────────
    if (explain) {
      final meta = result.metadata;
      if (format == 'json') {
        final planMap = {
          '_explain': {
            'query': meta.query,
            'mode': modeLabel,
            'searched': meta.searched,
            'skipped': meta.skipped,
            'total': meta.total,
          },
        };
        ctx.out.writeln(const JsonEncoder.withIndent('  ').convert(planMap));
      } else {
        ctx.out.writeln('Search plan');
        ctx.out.writeln('  Mode     : $modeLabel');
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
          'mode': modeLabel,
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

  /// Lists all configured FTS and vector indexes for [collection] and their
  /// status.
  ///
  /// The FTS side shows real build status via [FtsManager.stateFor]. The
  /// vector side shows only config-registration presence
  /// ([KmdbConfig.vecIndexesForCollection]), never a build-state lookup —
  /// [VecManager] (and the model it needs) may not be loaded during a plain
  /// `search list` per the command-token-gated model-construction rule
  /// (WI-12 Q6), so a `vecManager.stateFor`-style call could not run
  /// reliably here even if one existed.
  Future<bool> _list(CommandContext ctx, List<String> args) async {
    if (args.isEmpty) {
      ctx.writeError('search list: collection name required.');
      return false;
    }
    final collection = args[0];
    final ftsDefined = ctx.config.ftsIndexesForCollection(collection);
    final vecDefined = ctx.config.vecIndexesForCollection(collection);

    if (ftsDefined.isEmpty && vecDefined.isEmpty) {
      ctx.out.writeln(
        'No FTS or vector indexes configured for collection "$collection".',
      );
      return true;
    }

    final ftsManager = FtsManager(ctx.store, _buildFtsDefs(ctx.config));

    // Union of fields across both index types, FTS-first (matches _search's
    // default field-resolution order).
    final fields = {
      ...ftsDefined.map((r) => r.field),
      ...vecDefined.map((r) => r.field),
    };

    for (final field in fields) {
      final ftsRecord = ftsDefined.where((r) => r.field == field).firstOrNull;
      final hasVec = vecDefined.any((r) => r.field == field);

      final types = [if (ftsRecord != null) 'fts', if (hasVec) 'semantic'];

      if (ftsRecord != null) {
        final state = await ftsManager.stateFor(collection, field);
        final statusName = state?.status.name ?? 'undefined';
        ctx.out.writeln(
          '$field\t[${types.join(",")}]\t$statusName'
          '\tstopWords=${ftsRecord.stopWords}'
          '\tk1=${ftsRecord.k1}\tb=${ftsRecord.b}',
        );
      } else {
        // Vec-only field: config-registration presence only (see doc above).
        ctx.out.writeln('$field\t[${types.join(",")}]\tregistered');
      }
    }
    return true;
  }

  // ── create ─────────────────────────────────────────────────────────────────

  /// Registers a new FTS and/or vector index definition in the CLI config.
  ///
  /// By default registers **both** an FTS index and a vector index for the
  /// field — `--fts`/`--semantic` narrow this to just one type (see the
  /// class-level doc comment). Accepts optional `--stopwords` (boolean),
  /// `--k1 <n>`, and `--b <n>` flags to customise the BM25 parameters (FTS
  /// side only).
  ///
  /// A vector index does not require `embeddingModel` to already be
  /// configured — `search create` writes the config and prints a warning
  /// rather than hard-failing, so the database stays lexical-only-searchable
  /// until a model is added (WI-12 Q8's graceful-degradation requirement;
  /// without this, a bare `search create` on a database with no
  /// `embeddingModel` would make every subsequent CLI command throw once
  /// `DatabaseOpener.open()` sees a non-empty, modelless `vecIndexes`).
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

    // --fts/--semantic narrow registration to one index type; the no-flag
    // default (and passing both explicitly) registers both (Q8).
    final ftsFlag = flags['fts'] == true || flags['fts'] == 'true';
    final semanticFlag =
        flags['semantic'] == true || flags['semantic'] == 'true';
    final registerFts = ftsFlag || !semanticFlag;
    final registerVec = semanticFlag || !ftsFlag;

    final stopWords =
        flags['stopwords'] == true || flags['stopwords'] == 'true';
    final k1 = _parseDouble(flags['k1']) ?? 1.2;
    final b = _parseDouble(flags['b']) ?? 0.75;

    // Validate BM25 params (only meaningful when registering FTS, but
    // validated unconditionally — an invalid --k1/--b with --semantic alone
    // is still a user mistake worth catching rather than silently ignoring).
    if (k1 <= 0) {
      ctx.writeError('search create: --k1 must be a positive number.');
      return false;
    }
    if (b < 0.0 || b > 1.0) {
      ctx.writeError('search create: --b must be between 0.0 and 1.0.');
      return false;
    }

    if (registerFts) {
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
    }
    if (registerVec) {
      try {
        ctx.config.addVecIndex(collection, field);
      } on ArgumentError catch (e) {
        ctx.writeError(e.message as String);
        return false;
      }
    }

    try {
      await ctx.config.save();
    } catch (e) {
      ctx.writeError('search create: failed to save config: $e');
      return false;
    }

    final typeLabel = [
      if (registerFts) 'FTS',
      if (registerVec) 'semantic',
    ].join(' and ');
    ctx.out.writeln(
      '$typeLabel index on "$collection.$field" registered'
      '${registerFts && stopWords ? " (stop words enabled)" : ""}. '
      'It will be built on the next search query.',
    );

    // Graceful-degradation warning (Q8): a vecIndex makes embeddingModel
    // mandatory at the *next* KmdbDatabase.open() (see DatabaseOpener.open's
    // doc comment) — warn now so this isn't a surprise later, and so the
    // database is never bricked: cli_runner.dart only passes vecIndexes:
    // through when a model was actually constructed, so a registered vecIndex
    // with no embeddingModel lies dormant rather than erroring.
    if (registerVec && ctx.config.embeddingModel == null) {
      ctx.out.writeln(
        'Note: semantic index for \'$field\' registered, but no '
        'embeddingModel is configured in local/config.json — search will '
        'remain lexical-only until one is added.',
      );
    }

    return true;
  }

  // ── delete ─────────────────────────────────────────────────────────────────

  /// Removes an FTS and/or vector index definition from the config.
  ///
  /// By default removes **both** index types for the field —
  /// `--fts`/`--semantic` narrow this to just one, leaving the other intact.
  /// Only errors when *neither* the requested type(s) are actually
  /// registered — this is a deliberate rework of the previous FTS-only hard
  /// guard, which blocked deleting a vec-only field (one registered via
  /// `--semantic` alone) even though nothing was wrong with the request.
  Future<bool> _delete(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.length < 2) {
      ctx.writeError('search delete: collection name and field required.');
      return false;
    }
    final collection = args[0];
    final field = args[1];

    final ftsFlag = flags['fts'] == true || flags['fts'] == 'true';
    final semanticFlag =
        flags['semantic'] == true || flags['semantic'] == 'true';
    final removeFts = ftsFlag || !semanticFlag;
    final removeVec = semanticFlag || !ftsFlag;

    final hasFts = ctx.config
        .ftsIndexesForCollection(collection)
        .any((r) => r.field == field);
    final hasVec = ctx.config
        .vecIndexesForCollection(collection)
        .any((r) => r.field == field);

    final wantsFts = removeFts && hasFts;
    final wantsVec = removeVec && hasVec;

    if (!wantsFts && !wantsVec) {
      ctx.writeError(
        "search delete: no matching index on '$collection.$field' found in "
        "config.",
      );
      return false;
    }

    if (wantsFts) {
      try {
        ctx.config.removeFtsIndex(collection, field);
      } on ArgumentError catch (e) {
        ctx.writeError(e.message as String);
        return false;
      }
    }
    if (wantsVec) {
      try {
        ctx.config.removeVecIndex(collection, field);
      } on ArgumentError catch (e) {
        ctx.writeError(e.message as String);
        return false;
      }
    }

    try {
      await ctx.config.save();
    } catch (e) {
      ctx.writeError('search delete: failed to save config: $e');
      return false;
    }

    final typeLabel = [
      if (wantsFts) 'FTS',
      if (wantsVec) 'semantic',
    ].join(' and ');
    ctx.out.writeln(
      '$typeLabel index on "$collection.$field" deleted from config.',
    );
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
