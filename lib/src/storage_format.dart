import 'dart:typed_data';

class StorageEntry {
  final Uint8List key;
  final Uint8List value;

  StorageEntry(this.key, this.value);
}

class StorageFormat {
  /// Encodes a single key-value entry as a length-prefixed byte array.
  /// Format: [key_length (4 bytes)] [key] [value_length (4 bytes)] [value]
  static Uint8List encodeEntry(Uint8List key, Uint8List value) {
    final builder = BytesBuilder();
    
    // Key
    final keyLength = Uint8List(4)..buffer.asByteData().setUint32(0, key.length);
    builder.add(keyLength);
    builder.add(key);
    
    // Value
    final valueLength = Uint8List(4)..buffer.asByteData().setUint32(0, value.length);
    builder.add(valueLength);
    builder.add(value);
    
    return builder.toBytes();
  }

  /// Decodes a single key-value entry from a byte array.
  static StorageEntry decodeEntry(Uint8List data) {
    final byteData = ByteData.view(data.buffer, data.offsetInBytes, data.length);
    var offset = 0;
    
    // Key
    final keyLen = byteData.getUint32(offset);
    offset += 4;
    final key = data.sublist(offset, offset + keyLen);
    offset += keyLen;
    
    // Value
    final valueLen = byteData.getUint32(offset);
    offset += 4;
    final value = data.sublist(offset, offset + valueLen);
    
    return StorageEntry(key, value);
  }

  /// Encodes multiple entries.
  /// Format: [count (4 bytes)] [entry1] [entry2] ...
  static Uint8List encodeEntries(List<MapEntry<Uint8List, Uint8List>> entries) {
    final builder = BytesBuilder();
    
    final count = Uint8List(4)..buffer.asByteData().setUint32(0, entries.length);
    builder.add(count);
    
    for (final entry in entries) {
      builder.add(encodeEntry(entry.key, entry.value));
    }
    
    return builder.toBytes();
  }

  /// Decodes multiple entries.
  static List<StorageEntry> decodeEntries(Uint8List data) {
    final byteData = ByteData.view(data.buffer, data.offsetInBytes, data.length);
    var offset = 0;
    
    final count = byteData.getUint32(offset);
    offset += 4;
    
    final result = <StorageEntry>[];
    for (var i = 0; i < count; i++) {
      // Key
      final keyLen = byteData.getUint32(offset);
      offset += 4;
      final key = data.sublist(offset, offset + keyLen);
      offset += keyLen;
      
      // Value
      final valueLen = byteData.getUint32(offset);
      offset += 4;
      final value = data.sublist(offset, offset + valueLen);
      offset += valueLen;
      
      result.add(StorageEntry(key, value));
    }
    
    return result;
  }
}
