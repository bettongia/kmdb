// Copyright 2026 The Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';
import 'dart:typed_data';

import 'package:kmdb/src/engine/kvstore/kv_store.dart';
import 'package:kmdb/src/engine/util/hlc.dart';
import 'package:kmdb/src/vault/vault_recovery.dart';

/// A minimal in-memory [KvStore] for vault tests.
///
/// Only [get] is wired through to an internal map; all write methods are
/// no-ops. Use [setRefCount] to seed a properly-encoded `$vault` reference
/// count entry, or [setRawRefCount] to inject deliberately malformed bytes
/// for fail-safe testing (review finding H3).
class TestKvStore implements KvStore {
  /// In-memory store: namespace → key → bytes.
  final Map<String, Map<String, Uint8List>> _data = {};

  /// Seeds a properly-encoded `$vault:{sha256}` entry with `refCount: count`.
  ///
  /// Uses the same CBOR encoding [VaultRefInterceptor] produces (a single
  /// `0x00` codec flag prefix followed by a CBOR map with a `refCount` int).
  void setRefCount(String sha256, int count) {
    _data[kVaultNamespace] ??= {};
    final keyBytes = utf8.encode('refCount');
    final builder = BytesBuilder();
    builder.addByte(0x00); // ValueCodec raw flag
    builder.addByte(0xA1); // CBOR map with 1 pair
    builder.addByte(0x60 | keyBytes.length); // text string
    builder.add(keyBytes);
    if (count <= 23) {
      builder.addByte(count); // inline uint
    } else if (count <= 255) {
      builder.addByte(0x18);
      builder.addByte(count);
    } else {
      builder.addByte(0x19);
      builder.addByte((count >> 8) & 0xFF);
      builder.addByte(count & 0xFF);
    }
    _data[kVaultNamespace]![sha256] = builder.toBytes();
  }

  /// Injects raw (possibly malformed) bytes for [sha256] under `$vault`.
  ///
  /// Used to simulate a corrupt/undecodable ref-count entry that callers
  /// must treat as "referenced" (retain), never as "no reference" (delete).
  void setRawRefCount(String sha256, Uint8List bytes) {
    _data[kVaultNamespace] ??= {};
    _data[kVaultNamespace]![sha256] = bytes;
  }

  /// Removes any existing entry for [sha256] under `$vault`.
  void clearRefCount(String sha256) {
    _data[kVaultNamespace]?.remove(sha256);
  }

  @override
  Future<Uint8List?> get(String namespace, String key) async =>
      _data[namespace]?[key];

  @override
  Future<void> put(String namespace, String key, Uint8List value) async {}

  @override
  Future<void> delete(String namespace, String key) async {}

  @override
  Future<void> writeBatch(WriteBatch batch) async {}

  @override
  Stream<KvEntry> scan(
    String namespace, {
    String? startKey,
    String? endKey,
  }) async* {}

  @override
  Future<void> close({bool flush = true}) async {}

  @override
  void setTombstoneHorizonProvider(Future<Hlc> Function()? provider) {}

  @override
  Future<void> compactAll() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<StoreStats> stats() async => const StoreStats(
    dbDir: '/test',
    l0Count: 0,
    l1Count: 0,
    l2Count: 0,
    totalSstBytes: 0,
    totalDbBytes: 0,
  );

  @override
  Future<StoreInfo> storeInfo() async =>
      const StoreInfo(dbDir: '/test', deviceId: '00000000', currentHlc: '0');

  @override
  Future<void> reassignDeviceId(String newDeviceId) async {}

  @override
  Stream<String> get writeEvents => const Stream.empty();

  @override
  Future<void> ingestSstable(String filename, Uint8List bytes) async {}

  @override
  Future<void> dropAllSstables() async {}

  @override
  Future<List<String>> listNamespaces() async => [];

  @override
  Future<bool> createNamespace(String namespace) async => false;
}
