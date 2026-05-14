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
import 'dart:io' as io;

import 'package:kmdb/kmdb.dart';

import 'command.dart';

/// Manages collection schemas for a KMDB database from the command line.
///
/// Schemas define the shape that documents in a collection must conform to.
/// Once a schema is registered, every document write to that collection is
/// validated before being committed. Violations are reported as a structured
/// list of field-level errors.
///
/// ## Subcommands
///
/// ```
/// kmdb <db> schema set <collection> (--file <path> | --schema <json>)
/// kmdb <db> schema show <collection>
/// kmdb <db> schema list
/// kmdb <db> schema remove <collection>
/// kmdb <db> schema validate <collection> (--doc <json> | --file <path>)
/// ```
///
/// ## Storage
///
/// Schemas are stored in `$meta` under the key `schema:{collection}` and sync
/// automatically alongside documents. They are not stored in `local/config.json`.
final class SchemaCommand extends CliCommand {
  /// Creates a [SchemaCommand].
  const SchemaCommand();

  @override
  String get name => 'schema';

  @override
  String get description =>
      'Manage collection schemas (set, show, list, remove, validate).';

  @override
  String get usage =>
      '''schema set <collection> (--file <path> | --schema <json>)
       schema show <collection>
       schema list
       schema remove <collection>
       schema validate <collection> (--doc <json> | --file <path>)''';

  @override
  void configureArgParser(ArgParser parser) {
    parser
      ..addOption(
        'file',
        valueHelp: 'path',
        help: 'Path to a JSON file (schema for set; document for validate)',
      )
      ..addOption(
        'schema',
        valueHelp: 'json',
        help: 'Inline JSON Schema string (for schema set)',
      )
      ..addOption(
        'doc',
        valueHelp: 'json',
        help: 'Inline JSON document string (for schema validate)',
      );
  }

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError(
        'schema: subcommand required (set, show, list, remove, validate).\n'
        'Usage: $usage',
      );
      return false;
    }

    final subcommand = args[0];
    switch (subcommand) {
      case 'set':
        return _set(ctx, args.sublist(1), flags);
      case 'show':
        return _show(ctx, args.sublist(1));
      case 'list':
        return _list(ctx);
      case 'remove':
        return _remove(ctx, args.sublist(1));
      case 'validate':
        return _validate(ctx, args.sublist(1), flags);
      default:
        ctx.writeError(
          "schema: unknown subcommand '$subcommand'. "
          'Expected: set, show, list, remove, validate.',
        );
        return false;
    }
  }

  // ── set ─────────────────────────────────────────────────────────────────────

  /// Registers a JSON Schema for [collection].
  ///
  /// Accepts the schema as an inline JSON string via `--schema` or from a file
  /// via `--file`. Exactly one of these options must be provided.
  Future<bool> _set(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError('schema set: collection name required.\nUsage: $usage');
      return false;
    }
    final collection = args[0];

    // Exactly one input source must be provided.
    final schemaStr = flags['schema'] as String?;
    final filePath = flags['file'] as String?;

    if (schemaStr == null && filePath == null) {
      ctx.writeError(
        'schema set: one of --schema <json> or --file <path> is required.',
      );
      return false;
    }
    if (schemaStr != null && filePath != null) {
      ctx.writeError('schema set: --schema and --file are mutually exclusive.');
      return false;
    }

    // Read the schema JSON from the chosen source.
    final String rawJson;
    if (filePath != null) {
      try {
        rawJson = await io.File(filePath).readAsString();
      } on io.IOException catch (e) {
        ctx.writeError('schema set: cannot read file "$filePath": $e');
        return false;
      }
    } else {
      rawJson = schemaStr!;
    }

    // Decode and validate that the root is a JSON object.
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException catch (e) {
      ctx.writeError('schema set: invalid JSON: ${e.message}');
      return false;
    }
    if (decoded is! Map<String, dynamic>) {
      ctx.writeError(
        'schema set: JSON Schema must be a JSON object (got '
        '${decoded.runtimeType}).',
      );
      return false;
    }

    // Register the schema via KmdbDatabase convenience wrapper so we never
    // touch the package-private MetaStore from outside the kmdb package.
    await ctx.db.registerSchema(
      CollectionSchema(collection: collection, jsonSchema: decoded),
    );

    ctx.out.writeln("Schema registered for '$collection'.");
    return true;
  }

  // ── show ────────────────────────────────────────────────────────────────────

  /// Prints the registered JSON Schema for [collection].
  Future<bool> _show(CommandContext ctx, List<String> args) async {
    if (args.isEmpty) {
      ctx.writeError('schema show: collection name required.\nUsage: $usage');
      return false;
    }
    final collection = args[0];

    final schema = ctx.db.schemaManager.getSchema(collection);
    if (schema == null) {
      ctx.writeError("No schema registered for '$collection'.");
      return false;
    }

    ctx.out.writeln(const JsonEncoder.withIndent('  ').convert(schema));
    return true;
  }

  // ── list ────────────────────────────────────────────────────────────────────

  /// Lists all collections that have a registered schema.
  Future<bool> _list(CommandContext ctx) async {
    final collections = ctx.db.schemaManager.registeredCollections;
    if (collections.isEmpty) {
      ctx.out.writeln('No schemas registered.');
      return true;
    }
    for (final c in collections..sort()) {
      ctx.out.writeln(c);
    }
    return true;
  }

  // ── remove ──────────────────────────────────────────────────────────────────

  /// Removes the schema for [collection].
  ///
  /// If the collection has no registered schema, the operation succeeds
  /// silently (deregister is idempotent).
  Future<bool> _remove(CommandContext ctx, List<String> args) async {
    if (args.isEmpty) {
      ctx.writeError('schema remove: collection name required.\nUsage: $usage');
      return false;
    }
    final collection = args[0];

    // Deregister via KmdbDatabase convenience wrapper to avoid accessing the
    // package-private MetaStore from outside the kmdb package.
    await ctx.db.deregisterSchema(collection);
    ctx.out.writeln("Schema removed for '$collection'.");
    return true;
  }

  // ── validate ─────────────────────────────────────────────────────────────────

  /// Validates a document against the registered schema for [collection].
  ///
  /// The document may be supplied as an inline JSON string via `--doc` or read
  /// from a file via `--file`. Exactly one of these options must be provided.
  ///
  /// Prints `{"valid": true}` on success or a structured violation report on
  /// failure. If no schema is registered for [collection], prints an
  /// informational message and returns `true` (nothing to validate against).
  Future<bool> _validate(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    if (args.isEmpty) {
      ctx.writeError(
        'schema validate: collection name required.\nUsage: $usage',
      );
      return false;
    }
    final collection = args[0];

    // Exactly one input source must be provided.
    final docStr = flags['doc'] as String?;
    final filePath = flags['file'] as String?;

    if (docStr == null && filePath == null) {
      ctx.writeError(
        'schema validate: one of --doc <json> or --file <path> is required.',
      );
      return false;
    }
    if (docStr != null && filePath != null) {
      ctx.writeError(
        'schema validate: --doc and --file are mutually exclusive.',
      );
      return false;
    }

    // Read the document JSON from the chosen source.
    final String rawJson;
    if (filePath != null) {
      try {
        rawJson = await io.File(filePath).readAsString();
      } on io.IOException catch (e) {
        ctx.writeError('schema validate: cannot read file "$filePath": $e');
        return false;
      }
    } else {
      rawJson = docStr!;
    }

    // Decode and validate the document is a JSON object.
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException catch (e) {
      ctx.writeError('schema validate: invalid JSON: ${e.message}');
      return false;
    }
    if (decoded is! Map<String, dynamic>) {
      ctx.writeError(
        'schema validate: document must be a JSON object (got '
        '${decoded.runtimeType}).',
      );
      return false;
    }

    // If no schema is registered, skip validation and inform the caller.
    final schema = ctx.db.schemaManager.getSchema(collection);
    if (schema == null) {
      ctx.out.writeln(
        "No schema registered for '$collection'. Document not validated.",
      );
      return true;
    }

    // Validate and report.
    try {
      ctx.db.schemaManager.validate(collection, decoded);
    } on SchemaValidationException catch (e) {
      _writeViolations(ctx, collection, e);
      return false;
    }

    ctx.out.writeln('{"valid": true}');
    return true;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  /// Formats and writes a [SchemaValidationException] to [ctx.err].
  ///
  /// Output format:
  /// ```
  /// Error: schema validation failed for '<collection>':
  ///   name: required field is missing
  ///   email: must be a valid email
  /// ```
  ///
  /// When a violation has an empty [path], the message is printed without a
  /// prefix (root-level violation).
  static void _writeViolations(
    CommandContext ctx,
    String collection,
    SchemaValidationException e,
  ) {
    ctx.err.writeln("Error: schema validation failed for '$collection':");
    for (final v in e.violations) {
      if (v.path.isEmpty) {
        ctx.err.writeln('  ${v.message}');
      } else {
        ctx.err.writeln('  ${v.path}: ${v.message}');
      }
    }
  }

  /// Formats and writes a [SchemaValidationException] to [sink].
  ///
  /// This static helper is exposed for use by other write commands (e.g.
  /// `insert`, `put`, `update`) that need to report schema violations in a
  /// consistent format after the prerequisite CLI migration.
  static void formatViolations(
    StringSink sink,
    String collection,
    SchemaValidationException e,
  ) {
    sink.writeln("Error: schema validation failed for '$collection':");
    for (final v in e.violations) {
      if (v.path.isEmpty) {
        sink.writeln('  ${v.message}');
      } else {
        sink.writeln('  ${v.path}: ${v.message}');
      }
    }
  }
}
