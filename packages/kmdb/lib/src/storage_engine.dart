/*
 Copyright 2026 The Aurochs KMesh Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'storage_format.dart';

/// Compares two [Uint8List]s byte by byte.
/// 
/// Returns a negative integer if [a] is less than [b], a positive integer
/// if [a] is greater than [b], and zero if they are equal.
int compareUint8Lists(Uint8List a, Uint8List b) {
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    if (a[i] < b[i]) return -1;
    if (a[i] > b[i]) return 1;
  }
  return a.length.compareTo(b.length);
}

/// A performance-first storage engine for the kmdb document database.
/// 
/// It uses a write-ahead log for persistence and an in-memory [SplayTreeMap]
/// for fast lookups and range queries.
class StorageEngine {
  /// The path to the database file.
  final String path;
  RandomAccessFile? _file;
  
  final SplayTreeMap<Uint8List, Uint8List> _memTable = 
      SplayTreeMap<Uint8List, Uint8List>(compareUint8Lists);

  /// Creates a new [StorageEngine] with the given [path].
  StorageEngine(this.path);

  /// Opens the storage engine by loading existing data from disk
  /// and preparing the file for appending new entries.
  Future<void> open() async {
    final file = File(path);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    
    await _loadFromDisk();
    _file = await file.open(mode: FileMode.append);
  }

  Future<void> _loadFromDisk() async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;

    var offset = 0;
    while (offset < bytes.length) {
      try {
        final remainingData = bytes.sublist(offset);
        final entry = StorageFormat.decodeEntry(remainingData);
        
        _memTable[entry.key] = entry.value;
        // Format: checksum (1) + keyLen (4) + key + valLen (4) + value
        offset += 1 + 4 + entry.key.length + 4 + entry.value.length;
      } catch (e) {
        // If corruption is detected, we stop loading from this file.
        // In a more complex engine, we could attempt to skip the corrupted block.
        break;
      }
    }
  }

  /// Inserts or updates a [value] for the given [key].
  /// 
  /// The entry is stored in memory and appended to the write-ahead log on disk.
  Future<void> put(Uint8List key, Uint8List value) async {
    _memTable[key] = value;
    
    if (_file != null) {
      final encoded = StorageFormat.encodeEntry(key, value);
      await _file!.writeFrom(encoded);
      await _file!.flush();
    }
  }

  /// Retrieves the value associated with the given [key], or `null` if not found.
  Future<Uint8List?> get(Uint8List key) async {
    return _memTable[key];
  }

  /// Returns all key-value entries currently stored in the database.
  Future<List<StorageEntry>> getAll() async {
    return _memTable.entries
        .map((e) => StorageEntry(e.key, e.value))
        .toList();
  }

  /// Returns all key-value entries within the range from [start] to [end] (inclusive).
  Future<List<StorageEntry>> getRange(Uint8List start, Uint8List end) async {
    return _memTable.entries
        .where((e) => compareUint8Lists(e.key, start) >= 0 && 
                     compareUint8Lists(e.key, end) <= 0)
        .map((e) => StorageEntry(e.key, e.value))
        .toList();
  }

  /// Rewrites the database file to remove old versions of keys,
  /// keeping only the latest value for each key.
  Future<void> compact() async {
    final tempPath = '$path.tmp';
    final tempFile = File(tempPath);
    if (await tempFile.exists()) await tempFile.delete();
    
    final raf = await tempFile.open(mode: FileMode.write);
    try {
      for (final entry in _memTable.entries) {
        final encoded = StorageFormat.encodeEntry(entry.key, entry.value);
        await raf.writeFrom(encoded);
      }
      await raf.flush();
    } finally {
      await raf.close();
    }

    await _file?.close();
    await tempFile.rename(path);
    _file = await File(path).open(mode: FileMode.append);
  }

  /// Closes the storage engine, releasing all resources.
  Future<void> close() async {
    await _file?.close();
    _file = null;
    _memTable.clear();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StorageEngine &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {
        'path': path,
      };
}
