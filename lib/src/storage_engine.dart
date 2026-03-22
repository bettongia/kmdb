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
  
  // Use SplayTreeMap for ordered storage in memory
  final SplayTreeMap<Uint8List, Uint8List> _memTable = 
      SplayTreeMap<Uint8List, Uint8List>(compareUint8Lists);

  StorageEngine(this.path);

  Future<void> open() async {
    final file = File(path);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    
    // Read existing data first
    await _loadFromDisk();

    // Open for appending new data
    _file = await file.open(mode: FileMode.append);
  }

  Future<void> _loadFromDisk() async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;

    var offset = 0;
    while (offset < bytes.length) {
      try {
        final byteData = ByteData.view(bytes.buffer, bytes.offsetInBytes + offset);
        
        // Key length
        final keyLen = byteData.getUint32(0);
        final keyOffset = offset + 4;
        final key = bytes.sublist(keyOffset, keyOffset + keyLen);
        
        // Value length
        final valLenOffset = keyOffset + keyLen;
        final valLen = byteData.getUint32(valLenOffset - offset);
        final valOffset = valLenOffset + 4;
        final value = bytes.sublist(valOffset, valOffset + valLen);
        
        _memTable[key] = value;
        offset = valOffset + valLen;
      } catch (e) {
        // Stop on corruption or EOF
        break;
      }
    }
  }

  Future<void> put(Uint8List key, Uint8List value) async {
    _memTable[key] = value;
    
    if (_file != null) {
      final encoded = StorageFormat.encodeEntry(key, value);
      await _file!.writeFrom(encoded);
      await _file!.flush();
    }
  }

  Future<Uint8List?> get(Uint8List key) async {
    return _memTable[key];
  }

  /// Returns all entries in lexicographical order.
  Future<List<StorageEntry>> getAll() async {
    return _memTable.entries
        .map((e) => StorageEntry(e.key, e.value))
        .toList();
  }

  /// Returns entries within the given range [start, end] inclusive.
  Future<List<StorageEntry>> getRange(Uint8List start, Uint8List end) async {
    // SplayTreeMap doesn't have a built-in range method like some other languages,
    // so we use skipWhile and takeWhile on the entries.
    return _memTable.entries
        .where((e) => compareUint8Lists(e.key, start) >= 0 && 
                     compareUint8Lists(e.key, end) <= 0)
        .map((e) => StorageEntry(e.key, e.value))
        .toList();
  }

  Future<void> close() async {
    await _file?.close();
    _file = null;
    _memTable.clear();
  }
}
