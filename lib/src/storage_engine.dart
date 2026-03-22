import 'dart:io';
import 'dart:typed_data';
import 'package:collection/collection.dart';
import 'storage_format.dart';

class StorageEngine {
  final String path;
  RandomAccessFile? _file;
  final Map<Uint8List, Uint8List> _memTable = <Uint8List, Uint8List>{};

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
        
        _putInMemory(key, value);
        offset = valOffset + valLen;
      } catch (e) {
        // Stop on corruption or EOF
        break;
      }
    }
  }

  void _putInMemory(Uint8List key, Uint8List value) {
    final existingKey = _memTable.keys.firstWhereOrNull(
      (k) => const ListEquality().equals(k, key)
    );
    if (existingKey != null) {
      _memTable[existingKey] = value;
    } else {
      _memTable[key] = value;
    }
  }

  Future<void> put(Uint8List key, Uint8List value) async {
    _putInMemory(key, value);
    
    if (_file != null) {
      final encoded = StorageFormat.encodeEntry(key, value);
      await _file!.writeFrom(encoded);
      await _file!.flush();
    }
  }

  Future<Uint8List?> get(Uint8List key) async {
    final existingKey = _memTable.keys.firstWhereOrNull(
      (k) => const ListEquality().equals(k, key)
    );
    return existingKey != null ? _memTable[existingKey] : null;
  }

  Future<void> close() async {
    await _file?.close();
    _file = null;
    _memTable.clear();
  }
}
