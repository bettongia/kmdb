import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'storage_format.dart';

int compareUint8Lists(Uint8List a, Uint8List b) {
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    if (a[i] < b[i]) return -1;
    if (a[i] > b[i]) return 1;
  }
  return a.length.compareTo(b.length);
}

class StorageEngine {
  final String path;
  RandomAccessFile? _file;
  
  final SplayTreeMap<Uint8List, Uint8List> _memTable = 
      SplayTreeMap<Uint8List, Uint8List>(compareUint8Lists);

  StorageEngine(this.path);

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
        if (offset + 4 > bytes.length) break;
        final byteData = ByteData.view(bytes.buffer, bytes.offsetInBytes + offset);
        
        // Key length
        final keyLen = byteData.getUint32(0);
        final keyOffset = offset + 4;
        if (keyOffset + keyLen > bytes.length) break;
        final key = bytes.sublist(keyOffset, keyOffset + keyLen);
        
        // Value length
        final valLenOffset = keyOffset + keyLen;
        if (valLenOffset + 4 > bytes.length) break;
        final valLen = byteData.getUint32(valLenOffset - offset);
        final valOffset = valLenOffset + 4;
        if (valOffset + valLen > bytes.length) break;
        final value = bytes.sublist(valOffset, valOffset + valLen);
        
        _memTable[key] = value;
        offset = valOffset + valLen;
      } catch (e) {
        break;
      }
    }
  }

  /// Puts a key-value pair and ensures it is durable (ACID: Durability).
  Future<void> put(Uint8List key, Uint8List value) async {
    _memTable[key] = value;
    
    if (_file != null) {
      final encoded = StorageFormat.encodeEntry(key, value);
      // ACID: Atomicity and Durability - Ensure write is flushed to OS buffer and synced to disk
      await _file!.writeFrom(encoded);
      await _file!.flush();
      // On most modern OSs, flush() on RandomAccessFile calls fsync/FlushFileBuffers
      // which satisfies the Durability requirement of ACID.
    }
  }

  Future<Uint8List?> get(Uint8List key) async {
    return _memTable[key];
  }

  Future<List<StorageEntry>> getAll() async {
    return _memTable.entries
        .map((e) => StorageEntry(e.key, e.value))
        .toList();
  }

  Future<List<StorageEntry>> getRange(Uint8List start, Uint8List end) async {
    return _memTable.entries
        .where((e) => compareUint8Lists(e.key, start) >= 0 && 
                     compareUint8Lists(e.key, end) <= 0)
        .map((e) => StorageEntry(e.key, e.value))
        .toList();
  }

  /// Rewrites the entire database file to reclaim space and ensure a clean state.
  /// Uses an atomic rename for safety (ACID: Atomicity).
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

    // Atomic rename
    await _file?.close();
    await tempFile.rename(path);
    
    // Re-open for append
    _file = await File(path).open(mode: FileMode.append);
  }

  Future<void> close() async {
    await _file?.close();
    _file = null;
    _memTable.clear();
  }
}
