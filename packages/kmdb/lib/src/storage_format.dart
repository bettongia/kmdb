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

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

/// Represents a single key-value entry in the storage.
class StorageEntry {
  /// The key associated with this entry.
  final Uint8List key;
  
  /// The value associated with this entry.
  final Uint8List value;
  
  /// The checksum of the key and value for data integrity.
  final int checksum;

  /// Creates a new [StorageEntry] with the given [key], [value], and optional [checksum].
  StorageEntry(this.key, this.value, {this.checksum = 0});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StorageEntry &&
          runtimeType == other.runtimeType &&
          const ListEquality().equals(key, other.key) &&
          const ListEquality().equals(value, other.value) &&
          checksum == other.checksum;

  @override
  int get hashCode =>
      const ListEquality().hash(key) ^
      const ListEquality().hash(value) ^
      checksum.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {
        'key': base64Encode(key),
        'value': base64Encode(value),
        'checksum': checksum,
      };
}

/// A utility class for encoding and decoding the kmdb storage format.
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

  /// Encodes multiple entries into a single byte array.
  static Uint8List encodeEntries(List<MapEntry<Uint8List, Uint8List>> entries) {
    final builder = BytesBuilder();
    
    final count = Uint8List(4)..buffer.asByteData().setUint32(0, entries.length);
    builder.add(count);
    
    for (final entry in entries) {
      builder.add(encodeEntry(entry.key, entry.value));
    }
    
    return builder.toBytes();
  }

  /// Decodes multiple entries from a byte array.
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StorageFormat && runtimeType == other.runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {};
}
