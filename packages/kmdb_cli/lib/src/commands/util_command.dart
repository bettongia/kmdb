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
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kmdb/kmdb.dart';
import 'package:kmdb/kmdb_analysis.dart' hide CorruptedWalException;

import 'command.dart';

/// Storage-engine diagnostic command.
///
/// Provides subcommands for inspecting raw SSTable, WAL, and Manifest files
/// without acquiring any database lock. This allows inspection of a database
/// that is currently open in another process.
///
/// ## Usage
///
/// ```bash
/// kmdb mydb util sstable <filename>                    # summary (default)
/// kmdb mydb util sstable <filename> --full             # complete record-level output
/// kmdb mydb util sstable <filename> --full --data      # full output + decoded values
/// kmdb mydb util wal <filename>                        # summary
/// kmdb mydb util wal <filename> --full                 # every record
/// kmdb mydb util wal <filename> --full --data          # full output + decoded values
/// kmdb mydb util manifest                              # current level state
/// kmdb mydb util manifest --full                       # complete VersionEdit history
/// ```
///
/// All subcommands are **read-only** — no writes are performed.
final class UtilCommand implements CliCommand {
  /// Creates a [UtilCommand].
  const UtilCommand();

  @override
  String get name => 'util';

  @override
  String get description =>
      'Inspect raw SSTable, WAL, and Manifest files for debugging.';

  @override
  String get usage =>
      'util <sstable|wal|manifest> [filename] [--full] [--data]';

  @override
  Future<bool> execute(
    CommandContext ctx,
    List<String> args,
    Map<String, dynamic> flags,
  ) async {
    // util is purely diagnostic — never flush the memtable on exit.
    ctx.suppressFlush = true;

    if (args.isEmpty) {
      ctx.writeError(
        'util requires a subcommand: sstable, wal, or manifest. '
        'Usage: $usage',
      );
      return false;
    }

    final sub = args[0];
    final subArgs = args.sublist(1);
    final full = flags['full'] == true;
    final data = full && flags['data'] == true;

    return switch (sub) {
      'sstable' => _sstable(ctx, subArgs, full: full, data: data),
      'wal' => _wal(ctx, subArgs, full: full, data: data),
      'manifest' => _manifest(ctx, subArgs, full: full),
      _ => _unknownSubcommand(ctx, sub),
    };
  }

  // ── Subcommand: sstable ────────────────────────────────────────────────────

  /// Inspects a single SSTable file.
  ///
  /// [filename] is resolved relative to the `sst/` subdirectory of the
  /// database directory. No lock is acquired.
  ///
  /// Summary output (default): footer fields, Bloom filter stats, index entry
  /// count.
  ///
  /// Full output ([full] = true): everything above plus each [BlockRef] and
  /// every key/value pair from every data block.
  ///
  /// Data output ([data] = true, requires [full] = true): decodes each entry
  /// value using [ValueCodec] and includes the result alongside the byte-level
  /// metadata. Entries that cannot be decoded (e.g. internal system records)
  /// include a `decodeError` field instead of `decoded`.
  Future<bool> _sstable(
    CommandContext ctx,
    List<String> args, {
    required bool full,
    required bool data,
  }) async {
    if (args.isEmpty) {
      ctx.writeError('util sstable requires a filename argument.');
      return false;
    }

    final filename = args[0];
    final stats = await ctx.store.stats();
    // Filenames are resolved relative to the sst/ subdirectory.
    final path = '${stats.dbDir}/sst/$filename';
    final adapter = StorageAdapterNative();

    final SstableReader reader;
    try {
      reader = await SstableReader.open(path, adapter);
    } on StorageException {
      ctx.writeValue({'error': 'File not found: $path'});
      return false;
    } on CorruptedSstableException catch (e) {
      ctx.writeValue({'error': e.toString()});
      return false;
    }

    final footer = reader.footer;
    final filter = reader.filter;
    final index = reader.index;

    // Estimate FPR using: FPR ≈ (1 - e^(-k*n/m))^k
    // where k = hash functions, n = entries, m = filter bits.
    final fpr = _estimateFpr(
      k: filter.numHashFunctions,
      n: footer.entryCount,
      m: filter.numBits,
    );

    final result = <String, dynamic>{
      'file': filename,
      'footer': footer.toMap(),
      'bloomFilter': {
        'numBits': filter.numBits,
        'numHashFunctions': filter.numHashFunctions,
        'estimatedFpr': double.parse(fpr.toStringAsFixed(4)),
      },
      'indexEntryCount': index.length,
    };

    if (full) {
      // Include each block reference (offset, size, lastKey hex).
      result['index'] = [
        for (final ref in index)
          {
            'offset': ref.offset,
            'size': ref.size,
            'lastKey': _hexEncode(ref.lastKey),
          },
      ];

      // Stream every key/value entry from all data blocks.
      final entries = <Map<String, dynamic>>[];
      await for (final entry in reader.scan()) {
        final valueMap = <String, dynamic>{
          'compressionFlag': entry.value.isNotEmpty ? entry.value[0] : 0,
          'byteLength': entry.value.length,
        };

        if (data && entry.value.isNotEmpty) {
          // Only attempt ValueCodec decoding for user collections. System
          // collections (those starting with '$') use internal raw encodings
          // that are incompatible with ValueCodec.
          final coll = KeyCodec.decodeNamespace(Uint8List.fromList(entry.key));
          if (!coll.startsWith(r'$')) {
            try {
              valueMap['decoded'] = ValueCodec.decode(
                Uint8List.fromList(entry.value),
              );
            } catch (e) {
              valueMap['decodeError'] = e.toString();
            }
          }
        }


        entries.add({'key': _hexEncode(entry.key), 'value': valueMap});
      }
      result['entries'] = entries;
    }

    ctx.writeValue(result);
    return true;
  }

  // ── Subcommand: wal ────────────────────────────────────────────────────────

  /// Inspects a single WAL file.
  ///
  /// [filename] is resolved relative to the database directory. No lock is
  /// acquired. [WalReader.replayStrict] is used so corruption is surfaced
  /// immediately rather than silently skipped.
  ///
  /// Summary output (default): total record count, HLC range (min/max as hex
  /// strings), and the list of distinct namespaces seen.
  ///
  /// Full output ([full] = true): every record rendered via [WalRecord.toMap].
  ///
  /// Data output ([data] = true, requires [full] = true): decodes the value of
  /// each `put` record using [ValueCodec] and includes the result alongside the
  /// byte-level metadata. Records that cannot be decoded include a `decodeError`
  /// field instead of `decoded`.
  ///
  /// On [CorruptedWalException]: records decoded before the failure are
  /// included in the output, then a `corruptedAt` field is added.
  Future<bool> _wal(
    CommandContext ctx,
    List<String> args, {
    required bool full,
    required bool data,
  }) async {
    if (args.isEmpty) {
      ctx.writeError('util wal requires a filename argument.');
      return false;
    }

    final filename = args[0];
    final stats = await ctx.store.stats();
    final path = '${stats.dbDir}/$filename';
    final adapter = StorageAdapterNative();

    // Verify the file exists before attempting replay. WalReader.replayStrict
    // swallows the StorageException for missing files and returns an empty
    // stream, so a pre-check is needed to distinguish "not found" from "empty
    // WAL".
    final exists = await adapter.fileExists(path);
    if (!exists) {
      ctx.writeValue({'error': 'File not found: $path'});
      return false;
    }

    final walReader = WalReader(adapter: adapter);
    final records = <WalRecord>[];
    Map<String, dynamic>? corruptedAt;

    try {
      await for (final record in walReader.replayStrict(path)) {
        records.add(record);
      }
    } on CorruptedWalException catch (e) {
      // Capture corruption marker; all records decoded before the failure are
      // still in the list so partial output is not lost.
      corruptedAt = {'recordIndex': records.length, 'reason': e.message};
    }

    if (full) {
      // Full output: every record plus optional corruption marker.
      // When data=true, augment each put record's value map with decoded content.
      final recordMaps = records.map((r) {
        final map = r.toMap();
        if (data && r.value.isNotEmpty && !r.namespace.startsWith(r'$')) {
          // Only attempt ValueCodec decoding for user collections. System
          // collections (those starting with '$') use internal raw encodings
          // that are incompatible with ValueCodec.
          final valueMap = Map<String, dynamic>.from(
            map['value'] as Map<String, dynamic>,
          );
          try {
            valueMap['decoded'] = ValueCodec.decode(
              Uint8List.fromList(r.value),
            );
          } catch (e) {
            valueMap['decodeError'] = e.toString();
          }
          map['value'] = valueMap;
        }
        return map;
      }).toList();

      ctx.writeValue({
        'file': filename,
        'records': recordMaps,
        'corruptedAt': ?corruptedAt,
      });
    } else {
      // Summary output: record count, HLC range, distinct collections.
      Hlc? minHlc;
      Hlc? maxHlc;
      final collections = <String>{};

      for (final r in records) {
        final seq = r.sequence;
        if (minHlc == null || seq < minHlc) minHlc = seq;
        if (maxHlc == null || seq > maxHlc) maxHlc = seq;
        if (r.namespace.isNotEmpty) collections.add(r.namespace);
      }

      ctx.writeValue({
        'file': filename,
        'recordCount': records.length,
        'hlcRange': {'min': minHlc?.toHex(), 'max': maxHlc?.toHex()},
        'collections': collections.toList()..sort(),
        'corruptedAt': ?corruptedAt,
      });
    }

    // Return false if corruption was detected (non-zero exit for tooling).
    return corruptedAt == null;
  }

  // ── Subcommand: manifest ───────────────────────────────────────────────────

  /// Inspects the active Manifest file.
  ///
  /// Resolves the active Manifest by reading the `CURRENT` file in the
  /// database directory. No lock is acquired.
  ///
  /// Summary output (default): current level state via [ManifestReader.replay]
  /// — each level mapped to its list of SSTable filenames.
  ///
  /// Full output ([full] = true): complete [VersionEdit] sequence via
  /// [ManifestReader.replayEdits], each edit rendered via
  /// [VersionEdit.toMap].
  Future<bool> _manifest(
    CommandContext ctx,
    List<String> args, {
    required bool full,
  }) async {
    final stats = await ctx.store.stats();
    final dbDir = stats.dbDir;
    final adapter = StorageAdapterNative();

    // Resolve the active manifest by reading CURRENT.
    final currentPath = '$dbDir/CURRENT';
    final currentExists = await adapter.fileExists(currentPath);
    if (!currentExists) {
      // A fresh database that has never been written to has no CURRENT file.
      ctx.writeValue({'manifestFile': null, 'levels': <String, dynamic>{}});
      return true;
    }

    final currentBytes = await adapter.readFile(currentPath);
    final manifestName = utf8.decode(currentBytes).trimRight();
    final manifestPath = '$dbDir/$manifestName';
    final manifestReader = ManifestReader(adapter: adapter);

    if (full) {
      final edits = await manifestReader.replayEdits(manifestPath);
      ctx.writeValue({
        'manifestFile': manifestName,
        'editCount': edits.length,
        'edits': edits.map((e) => e.toMap()).toList(),
      });
    } else {
      final state = await manifestReader.replay(manifestPath);
      // Convert int keys to string keys for JSON serialisation.
      final levelsMap = {
        for (final entry in state.levels.entries) '${entry.key}': entry.value,
      };
      ctx.writeValue({
        'manifestFile': manifestName,
        'maxLogNumber': state.maxLogNumber,
        'maxNextSeq': state.maxNextSeq,
        'levels': levelsMap,
      });
    }

    return true;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Returns false and writes an error for an unrecognised subcommand.
  Future<bool> _unknownSubcommand(CommandContext ctx, String sub) async {
    ctx.writeError(
      "Unknown util subcommand '$sub'. "
      'Valid subcommands: sstable, wal, manifest.',
    );
    return false;
  }

  /// Encodes [bytes] as a lowercase hex string.
  static String _hexEncode(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Estimates the Bloom filter false-positive rate.
  ///
  /// Uses the standard approximation:
  /// `FPR ≈ (1 - e^(-k*n/m))^k`
  ///
  /// where:
  /// - [k] = number of hash functions
  /// - [n] = number of elements inserted
  /// - [m] = number of bits in the filter
  static double _estimateFpr({required int k, required int n, required int m}) {
    if (m == 0 || n == 0) return 0.0;
    final exponent = -(k * n) / m;
    final base = 1.0 - math.exp(exponent);
    return math.pow(base, k).toDouble();
  }
}
