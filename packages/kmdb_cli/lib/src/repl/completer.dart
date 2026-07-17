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

import '../commands/command.dart';
import 'dot_command.dart';

/// Context-sensitive tab-completion provider for the REPL.
///
/// ## Completion tree
///
/// | Cursor position                        | Completions offered                           |
/// |:---------------------------------------|:----------------------------------------------|
/// | First token starts with `.`            | Dot-command names                             |
/// | First token (no `.`)                   | REPL command names                            |
/// | After `scan/get/count/delete/update`   | Collection names                              |
/// | After `schema`                         | `set show list remove validate`               |
/// | After `schema show/remove/validate`    | Collections with registered schemas           |
/// | After `search`                         | Collection names, then `list create delete`   |
/// | After `search create`                  | Collection names                              |
/// | After `index`                          | `list create info delete`                     |
/// | After `index create/list/info/delete`  | Collection names                              |
/// | After `--order-by`                     | Field names from active/named collection      |
/// | After `.mode`                          | Mode names                                    |
/// | After `.collection`                    | Collection names                              |
/// | After `vault`                          | `get export search reindex status`            |
/// | After `remote`                         | `add list remove`                             |
abstract class CompletionProvider {
  /// Returns completion candidates for the current [text] at [cursorPos].
  ///
  /// Only the text up to [cursorPos] is considered; text after the cursor is
  /// ignored when determining context.
  Future<List<String>> complete(String text, int cursorPos);
}

// ── LiveCompletionProvider ────────────────────────────────────────────────────

/// [CompletionProvider] backed by a live [CommandContext].
///
/// Collection names are fetched from the live database on each Tab press so
/// that collections created mid-session are immediately completable.
final class LiveCompletionProvider implements CompletionProvider {
  /// Creates a [LiveCompletionProvider] backed by [ctx].
  LiveCompletionProvider(this._ctx, this._dotRegistry);

  final CommandContext _ctx;
  final DotCommandRegistry _dotRegistry;

  static const _replCommands = [
    'get',
    'insert',
    'update',
    'delete',
    'scan',
    'count',
    'collections',
    'create_collection',
    'export',
    'import',
    'dump',
    'restore',
    'schema',
    'search',
    'index',
    'vault',
    'remote',
    'push',
    'pull',
    'sync',
  ];

  static const _schemaSubcommands = [
    'set',
    'show',
    'list',
    'remove',
    'validate',
  ];

  static const _searchSubcommands = ['list', 'create', 'delete'];

  static const _indexSubcommands = ['list', 'create', 'info', 'delete'];

  static const _remoteSubcommands = ['add', 'list', 'remove'];

  static const _outputModes = [
    'json',
    'compact',
    'ndjson',
    'table',
    'csv',
    'line',
  ];

  static const _collectionCommands = {
    'scan',
    'get',
    'count',
    'delete',
    'update',
    'create_collection',
    'export',
    'import',
  };

  @override
  Future<List<String>> complete(String text, int cursorPos) async {
    final before = text.substring(0, cursorPos);
    final tokens = _tokenize(before);

    if (tokens.isEmpty) return _replCommands;

    final first = tokens[0];

    // ── Dot-commands ────────────────────────────────────────────────────────
    if (first.startsWith('.')) {
      if (tokens.length == 1) {
        return _dotRegistry.names.where((n) => n.startsWith(first)).toList()
          ..sort();
      }
      // .mode <tab>
      if (first == '.mode' && tokens.length == 2) {
        return _filterPrefix(_outputModes, tokens[1]);
      }
      // .collection <tab>
      if (first == '.collection' && tokens.length == 2) {
        return _filterPrefix(await _collections(), tokens[1]);
      }
      return [];
    }

    // ── First token: REPL command names ─────────────────────────────────────
    if (tokens.length == 1) {
      return _filterPrefix(_replCommands, first);
    }

    // ── Second token onwards ─────────────────────────────────────────────────
    final second = tokens.length >= 2 ? tokens[1] : '';

    // --order-by flag: offer field names from the relevant collection.
    // Must come before the collection-positional check so that `scan notes
    // --order-by <tab>` completes fields, not collection names.
    final orderByIdx = tokens.indexOf('--order-by');
    if (orderByIdx != -1 && tokens.length == orderByIdx + 2) {
      final coll = tokens.length > 1 ? tokens[1] : null;
      if (coll != null) {
        return _filterPrefix(await _fieldNames(coll), tokens.last);
      }
      return [];
    }

    // Collection-positional commands
    if (_collectionCommands.contains(first)) {
      return _filterPrefix(await _collections(), second);
    }

    // schema subcommands
    if (first == 'schema') {
      if (tokens.length == 2) return _filterPrefix(_schemaSubcommands, second);
      if (tokens.length == 3 &&
          (second == 'show' || second == 'remove' || second == 'validate')) {
        return _filterPrefix(await _schemasCollections(), tokens[2]);
      }
      return [];
    }

    // search
    if (first == 'search') {
      if (tokens.length == 2) {
        // Could be a collection name or a subcommand.
        return _filterPrefix([
          ...await _collections(),
          ..._searchSubcommands,
        ], second);
      }
      if (tokens.length == 3 && second == 'create') {
        return _filterPrefix(await _collections(), tokens[2]);
      }
      return [];
    }

    // index
    if (first == 'index') {
      if (tokens.length == 2) return _filterPrefix(_indexSubcommands, second);
      if (tokens.length == 3) {
        return _filterPrefix(await _collections(), tokens[2]);
      }
      return [];
    }

    // vault
    if (first == 'vault' && tokens.length == 2) {
      return _filterPrefix([
        'get',
        'export',
        'search',
        'reindex',
        'status',
      ], second);
    }

    // remote
    if (first == 'remote' && tokens.length == 2) {
      return _filterPrefix(_remoteSubcommands, second);
    }

    return [];
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Future<List<String>> _collections() async {
    try {
      return await _ctx.store.listNamespaces();
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> _schemasCollections() async {
    try {
      return _ctx.db.schemaManager.registeredCollections;
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> _fieldNames(String collection) async {
    try {
      final col = _ctx.rawCollection(collection);
      final docs = await col.all().limit(20).get();
      final fields = <String>{};
      for (final doc in docs) {
        fields.addAll(doc.keys.where((k) => !k.startsWith('_')));
      }
      return fields.toList()..sort();
    } catch (_) {
      return [];
    }
  }

  List<String> _filterPrefix(List<String> candidates, String prefix) {
    if (prefix.isEmpty) return candidates;
    return candidates.where((c) => c.startsWith(prefix)).toList();
  }

  /// Splits [text] on whitespace, ignoring quoted strings.
  ///
  /// When [text] ends with whitespace, a trailing empty token is appended to
  /// represent the "start of the next word" position, allowing callers to
  /// distinguish `'scan'` (completing the command name) from `'scan '`
  /// (completing the first argument).
  List<String> _tokenize(String text) {
    final tokens = <String>[];
    final buf = StringBuffer();
    String? quote;
    for (final ch in text.split('')) {
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else {
          buf.write(ch);
        }
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == ' ' || ch == '\t') {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(ch);
      }
    }
    // Include the trailing partial token so we can complete it.
    if (buf.isNotEmpty) tokens.add(buf.toString());
    // Add a sentinel empty token when the input ends with whitespace so
    // 'scan ' is treated as ['scan', ''] rather than ['scan'].
    if (text.isNotEmpty &&
        (text.endsWith(' ') || text.endsWith('\t')) &&
        (tokens.isEmpty || tokens.last.isNotEmpty)) {
      tokens.add('');
    }
    return tokens;
  }
}
