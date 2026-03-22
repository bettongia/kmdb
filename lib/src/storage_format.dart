import 'dart:typed_data';

class StorageEntry {
  final Uint8List key;
  final Uint8List value;
  final int checksum;

  StorageEntry(this.key, this.value, {this.checksum = 0});
}

class StorageFormat {
  /// Simple XOR checksum for data integrity.
  static int computeChecksum(Uint8List key, Uint8List value) {
    var checksum = 0;
    for (final b in key) {
      checksum ^= b;
    }
    for (final b in value) {
      checksum ^= b;
    }
    return checksum;
  }

  /// Encodes a single key-value entry as a length-prefixed byte array.
  /// Format: [checksum (1 byte)] [key_length (4 bytes)] [key] [value_length (4 bytes)] [value]
  static Uint8List encodeEntry(Uint8List key, Uint8List value) {
    final builder = BytesBuilder();
    
    // Checksum
    builder.addByte(computeChecksum(key, value));

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
  /// Throws if data is corrupted.
  static StorageEntry decodeEntry(Uint8List data) {
    final byteData = ByteData.view(data.buffer, data.offsetInBytes, data.length);
    var offset = 0;
    
    // Checksum
    final storedChecksum = data[offset];
    offset += 1;

    // Key
    final keyLen = byteData.getUint32(offset);
    offset += 4;
    final key = data.sublist(offset, offset + keyLen);
    offset += keyLen;
    
    // Value
    final valueLen = byteData.getUint32(offset);
    offset += 4;
    final value = data.sublist(offset, offset + valueLen);
    
    final computedChecksum = computeChecksum(key, value);
    if (storedChecksum != computedChecksum) {
      throw Exception('Data corruption detected: checksum mismatch');
    }

    return StorageEntry(key, value, checksum: storedChecksum);
  }

  /// Encodes multiple entries.
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
      // Use the helper to decode and verify checksum
      final entryData = data.sublist(offset);
      final entry = decodeEntry(entryData);
      
      // Calculate next offset manually because decodeEntry doesn't return size
      // Format: 1 (checksum) + 4 (keyLen) + key + 4 (valLen) + value
      offset += 1 + 4 + entry.key.length + 4 + entry.value.length;
      
      result.add(entry);
    }
    
    return result;
  }
}
