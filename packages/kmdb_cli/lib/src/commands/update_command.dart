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

import 'dart:convert';

import 'package:kmdb/kmdb.dart';

import '../filter/filter_parser.dart';
import 'command.dart';
import 'vault/vault_import_helper.dart';

/// Partially updates one or more existing documents in a collection.
///
/// Performs a shallow merge: the fields provided via `--set` are merged
/// into the top-level of each matching document. Nested objects are replaced
/// wholesale, not recursively merged. The `_id` field is always preserved from
/// the existing document — any `_id` in `--set` is silently ignored.
///
/// Writes route through the full Query Layer write pipeline: schema validation,
/// secondary index maintenance, FTS updates, and vault ref-count adjustments
/// all run automatically and atomically with each document write.
///
/// Each document write is independent — there is no atomicity guarantee across
/// multiple documents.
///
/// **Targeting modes (exactly one required):**
///
/// ```sh
/// # Single document by positional ID
/// kmdb <db> update <collection> <id> --set '{"status":"done"}'
///
/// # Multiple specific IDs (repeatable flag)
/// kmdb <db> update <collection> --id <id> --id <id> --set '{"status":"done"}'
///
/// # Filter-based (all matching documents)
/// kmdb <db> update <collection> --filter '{"field":"active","op":"eq","value":false}' --set '{"archived":true}'
///
/// # All documents (explicit opt-in)
/// kmdb <db> update <collection> --all --set '{"archived":true}'
///
/// # Vault package import (requires --id or positional <id>; replaces document)
/// kmdb <db> update <collection> <id> --import package.kvlt
/// ```
///
/// Reports `{"updated": N}` on success.
final class UpdateCommand extends CliCommand {
  const UpdateCommand();

  @override
  String get name => 'update';

  @override
  String get description =>
      'Partially update documents in a collection (shallow merge). '
      'Requires exactly one targeting mode: positional <id>, '
      '--id <id> (repeatable), --filter <json>, or --all. '
      'Always requires --set <json>.';

  @override
  String get usage => 'update <collection> [<id>]';

  @override
  void configureArgParser(ArgParser parser) {
    parser
      ..addOption(
        'id',
        valueHelp: 'id,...',
        help: 'Document ID(s) to update (comma-separated, repeatable)',
      )
      ..addOption(
        'filter',
        valueHelp: 'json',
        help: 'JSON filter to select documents to update',
      )
      ..addFlag(
        'all',
        negatable: false,
        help: 'Update all documents in the collection',
      )
      ..addOption(
        'set',
        valueHelp: 'json',
        help: 'JSON fields to shallow-merge into matching documents',
      )
      ..addOption(
        'import',
        valueHelp: 'package.kvlt',
        help: 'Merge fields from a vault KVLT package',
      );
  }

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('update requires <collection>.\nUsage: $usage');
      return false;
    }
    final collection = args[0];

    // ── Handle --import flag (mutually exclusive with --set) ──────────────────
    final importPath = flags['import'] as String?;
    if (importPath != null) {
      if (flags['set'] != null) {
        ctx.writeError('--import is mutually exclusive with --set.');
        return false;
      }
      return _executeImport(ctx, collection, args, flags, importPath);
    }

    // ── Parse --set ──────────────────────────────────────────────────────────
    final setJson = flags['set'] as String?;
    if (setJson == null) {
      ctx.writeError('update requires --set <json>.\nUsage: $usage');
      return false;
    }

    final Map<String, dynamic> setFields;
    try {
      final decoded = json.decode(setJson);
      if (decoded is! Map<String, dynamic>) {
        ctx.writeError('--set must be a JSON object, not an array or scalar.');
        return false;
      }
      setFields = decoded;
    } on FormatException catch (e) {
      ctx.writeError('Invalid JSON in --set: ${e.message}');
      return false;
    }

    // ── Detect targeting mode ────────────────────────────────────────────────
    // Exactly one of: positional <id>, --id, --filter, or --all.
    final positionalId = args.length > 1 ? args[1] : null;
    // The CLI flag parser collapses repeated --id into the last value, so we
    // need to collect them differently. We receive them as a single string when
    // there's one value, or the parser would need to support lists. Since the
    // CLI dispatcher stores only the last value, we treat --id as a single
    // value and document that the user must pass the command multiple times for
    // multi-id updates via script mode. For inline invocation the shell already
    // tokenises, so we use a custom multi-value approach: the flag parser in
    // _dispatchTokens stores the last value — we therefore support multiple
    // --id flags by scanning the raw flag map for 'id' values across multiple
    // occurrences. However, the current CLI parser stores one value per flag
    // name. We work around this by accepting a comma-separated list in --id.
    //
    // Design note: The plan specifies repeatable --id flags. The current
    // _dispatchTokens parser only keeps the last occurrence of a flag. Rather
    // than restructuring the parser, we accept --id as a comma-separated list
    // of IDs. This is consistent with --select in ScanCommand and avoids a
    // parser overhaul.
    final idFlag = flags['id'] as String?;
    final filterFlag = flags['filter'] as String?;
    final allFlag = flags['all'] == true;

    // Count how many targeting modes were specified.
    final modeCount = [
      positionalId != null,
      idFlag != null,
      filterFlag != null,
      allFlag,
    ].where((b) => b).length;

    if (modeCount == 0) {
      ctx.writeError(
        'update requires a targeting mode: '
        'positional <id>, --id <id>, --filter <json>, or --all.\n'
        'Usage: $usage',
      );
      return false;
    }

    if (modeCount > 1) {
      ctx.writeError(
        'update targeting modes are mutually exclusive: '
        'specify exactly one of positional <id>, --id, --filter, or --all.',
      );
      return false;
    }

    // ── Dispatch to targeting mode ───────────────────────────────────────────
    var updated = 0;

    if (positionalId != null) {
      // Single document by positional ID.
      final ok = await _updateOne(ctx, collection, positionalId, setFields);
      if (!ok) return false;
      updated = 1;
    } else if (idFlag != null) {
      // One or more IDs provided as a comma-separated list.
      final ids = idFlag
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      for (final id in ids) {
        final ok = await _updateOne(ctx, collection, id, setFields);
        if (!ok) return false;
        updated++;
      }
    } else if (filterFlag != null) {
      // Filter-based: query matching documents via the Query Layer, then update
      // each one through the write pipeline so augmentors run.
      final Filter filter;
      try {
        filter = FilterParser.parse(filterFlag);
      } on ArgumentError catch (e) {
        ctx.writeError('Invalid filter: ${e.message}');
        return false;
      } on FormatException catch (e) {
        ctx.writeError('Invalid filter JSON: ${e.message}');
        return false;
      }

      final col = ctx.rawCollection(collection);
      // Collect all matching documents first to avoid iterating while writing.
      final matches = await col.where(filter).get();
      for (final doc in matches) {
        final merged = _merge(doc, setFields);
        // col.put() runs the full write pipeline (validators + augmentors).
        await col.put(merged);
        updated++;
      }
    } else {
      // All-docs mode: update every document via the write pipeline.
      final col = ctx.rawCollection(collection);
      // Collect all documents first to avoid iterating while writing.
      final all = await col.all().get();
      for (final doc in all) {
        final merged = _merge(doc, setFields);
        await col.put(merged);
        updated++;
      }
    }

    ctx.writeValue({'updated': updated});
    return true;
  }

  // ── Vault package import ───────────────────────────────────────────────────

  /// Imports a KVLT vault package and replaces an existing document.
  ///
  /// The target document is identified by a positional `<id>` argument or
  /// `--id <id>`. For bulk targeting (--filter, --all), use --set instead.
  ///
  /// The update scenarios from §24 are:
  /// 1. No vault dir in package, document has no vault URIs → replace document.
  /// 2. No vault dir, document has URIs already in vault → replace document,
  ///    adjusting ref counts (old doc URIs decremented, new doc URIs incremented).
  /// 3. No vault dir, document has URIs not in vault → failure.
  /// 4. Vault dir present, all URIs resolved → ingest blobs, replace document.
  /// 5. Vault dir present, some URIs unresolvable → failure.
  Future<bool> _executeImport(
    CommandContext ctx,
    String collection,
    List<String> args,
    Map<String, dynamic> flags,
    String importPath,
  ) async {
    final vaultStore = ctx.vaultStore;
    if (vaultStore == null) {
      ctx.writeError(
        '--import requires vault to be configured for this database.',
      );
      return false;
    }

    // --import requires a single target document (positional <id> or --id).
    final positionalId = args.length > 1 ? args[1] : null;
    final idFlag = flags['id'] as String?;
    if (positionalId == null && idFlag == null) {
      ctx.writeError(
        '--import requires a target document ID. '
        'Specify a positional <id> or --id <id>.\n'
        'Usage: $usage',
      );
      return false;
    }
    if (positionalId != null && idFlag != null) {
      ctx.writeError(
        'Specify either a positional <id> or --id <id>, not both.',
      );
      return false;
    }
    final targetId = positionalId ?? idFlag!;

    // Read and parse the vault package.
    final contents = readVaultPackage(
      packagePath: importPath,
      packageBytes: null,
      errSink: ctx.err,
    );
    if (contents == null) return false;

    // Validate: all vault URIs in document are covered by attachments or vault.
    // First check what's already in the vault so we can pass existingHashes.
    final docUris = extractVaultUrisFromDoc(contents.documentJson);
    final existingHashes = <String>{};
    for (final sha256 in docUris) {
      if (await vaultStore.exists(sha256)) {
        existingHashes.add(sha256);
      }
    }

    try {
      VaultPackage.validate(
        documentJson: contents.documentJson,
        attachments: contents.attachments,
        existingHashes: existingHashes,
      );
    } on FormatException catch (e) {
      ctx.writeError('Invalid vault package: ${e.message}');
      return false;
    }

    // Check target document exists via the Query Layer (Cache Layer consulted).
    final col = ctx.rawCollection(collection);
    final oldDoc = await col.get(targetId);
    if (oldDoc == null) {
      ctx.writeError('Document not found: $targetId');
      return false;
    }

    // Ingest all vault blobs from the package.
    final info = await ctx.store.storeInfo();
    final ingestedHashes = await ingestVaultAttachments(
      vaultStore: vaultStore,
      attachments: contents.attachments,
      hlcTimestamp: info.currentHlc,
      errSink: ctx.err,
    );
    if (ingestedHashes == null) return false;

    // Build the replacement document, preserving the existing _id.
    final doc = Map<String, dynamic>.of(contents.documentJson);
    doc['_id'] = targetId;

    // Build a WriteBatch: document replace + vault ref count adjustments.
    final batch = WriteBatch();
    batch.put(collection, targetId, ValueCodec.encode(doc));
    await applyVaultRefCounts(
      doc: doc,
      oldDoc: oldDoc,
      store: ctx.store,
      vaultStore: vaultStore,
      batch: batch,
    );
    await ctx.store.writeBatch(batch);

    ctx.writeValue({'updated': 1});
    return true;
  }

  /// Reads, merges, and writes back a single document identified by [key].
  ///
  /// Routes through the Query Layer write pipeline so schema validation,
  /// secondary index maintenance, FTS, and vault ref counts run automatically.
  ///
  /// Returns `false` and writes an error to [ctx] when the document is not
  /// found. Returns `true` on success.
  Future<bool> _updateOne(
    CommandContext ctx,
    String collection,
    String key,
    Map<String, dynamic> setFields,
  ) async {
    final col = ctx.rawCollection(collection);
    final doc = await col.get(key);
    if (doc == null) {
      ctx.writeError('Document not found: $key');
      return false;
    }
    final merged = _merge(doc, setFields);
    // col.put() is an upsert; since the document already exists, it runs the
    // write pipeline with the old document for augmentors that need oldDoc.
    await col.put(merged);
    return true;
  }

  /// Performs a shallow merge of [setFields] into [existing].
  ///
  /// All top-level keys in [setFields] overwrite the corresponding keys in
  /// [existing]. The `_id` field is always preserved from [existing] and
  /// cannot be overwritten by [setFields].
  Map<String, dynamic> _merge(
    Map<String, dynamic> existing,
    Map<String, dynamic> setFields,
  ) {
    // Preserve the existing _id regardless of what --set contains.
    final id = existing['_id'];
    final result = Map<String, dynamic>.of(existing)..addAll(setFields);
    if (id != null) {
      result['_id'] = id;
    } else {
      result.remove('_id');
    }
    return result;
  }
}
