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

  Future<void> close() async {
    await _file?.close();
    _file = null;
    _memTable.clear();
  }
}
