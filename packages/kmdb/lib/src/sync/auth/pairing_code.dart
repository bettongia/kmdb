// Copyright 2026 The Authors.
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

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;

import 'sync_set_key.dart';

/// Encodes and decodes a [SyncSetKey] as a human-transcribable pairing code
/// (0.10.01 WI-4 T1, `kmdb remote pair show`/`import`).
///
/// ## Format
///
/// `KSA1-` followed by the base32 (RFC 4648, uppercase, no padding)
/// encoding of `[SyncSetKey.encode() bytes][2-byte checksum]`, grouped into
/// 5-character blocks separated by `-` for readability. The `KSA1` prefix
/// identifies both the artefact ("**K**MDB **S**ync **A**uthentication")
/// and the format version, mirroring [SyncAuthEnvelope]'s magic+version
/// framing.
///
/// [encode] and [decode] are asynchronous because the checksum is computed
/// via `package:cryptography`'s `Sha256` (already a dependency of this
/// package, used elsewhere for HKDF — see [DefaultSyncAuthenticator]); every
/// real call site (CLI commands, tests) is already inside an `async`
/// function, so this costs nothing in practice and avoids adding a second
/// hashing dependency purely for a synchronous fast path.
///
/// ## Why a checksum, not a PAKE
///
/// The pairing code carries the key itself, in the clear, to be transcribed
/// or copy-pasted between devices out of band (a settled design decision —
/// see the plan's rationale record). A PAKE would be over-engineering for a
/// **re-provisionable** secret whose loss costs nothing (unlike the
/// encryption DEK, which uses a recovery code precisely because losing it
/// is catastrophic). The checksum exists purely to catch transcription
/// errors — a fat-fingered character — not to add cryptographic strength; it
/// is the leading 2 bytes of `SHA-256(payload)`.
///
/// ## Example
///
/// ```dart
/// final key = SyncSetKey.generate();
/// final code = await PairingCode.encode(key);
/// // 'KSA1-JBSWY-3DPEB-LW64T-MMQ...'
/// final recovered = await PairingCode.decode(code);
/// assert(recovered == key);
/// ```
final class PairingCode {
  const PairingCode._();

  /// The fixed prefix identifying a KMDB sync-authentication pairing code,
  /// version 1.
  static const String kPrefix = 'KSA1-';

  /// The RFC 4648 base32 alphabet, uppercase, no padding.
  static const String _kAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// Number of characters per dash-separated group in the rendered code.
  static const int _kGroupSize = 5;

  /// Encodes [key] as a pairing code string.
  static Future<String> encode(SyncSetKey key) async {
    final payload = key.encode();
    final checksum = await _checksum(payload);
    final full = Uint8List(payload.length + checksum.length)
      ..setAll(0, payload)
      ..setAll(payload.length, checksum);
    final encoded = _base32Encode(full);
    return kPrefix + _group(encoded);
  }

  /// Decodes a pairing code string previously produced by [encode].
  ///
  /// Accepts and ignores whitespace and `-` group separators anywhere after
  /// the prefix (so a code copy-pasted with its original grouping, or
  /// retyped without it, both decode identically). The prefix match is
  /// case-insensitive; the base32 body is normalised to uppercase before
  /// decoding.
  ///
  /// Throws [FormatException] if the prefix is missing, the base32 body is
  /// malformed, the payload is too short to contain a [SyncSetKey] plus
  /// checksum, or the checksum does not match (almost always a
  /// transcription typo).
  static Future<SyncSetKey> decode(String code) async {
    final trimmed = code.trim();
    if (trimmed.length < kPrefix.length ||
        !trimmed
            .substring(0, kPrefix.length)
            .toUpperCase()
            .startsWith(kPrefix)) {
      throw FormatException('Pairing code must start with "$kPrefix"', code);
    }
    final body = trimmed
        .substring(kPrefix.length)
        .replaceAll(RegExp(r'[\s-]'), '')
        .toUpperCase();
    final Uint8List full;
    try {
      full = _base32Decode(body);
    } on FormatException catch (e) {
      throw FormatException('Malformed pairing code: ${e.message}', code);
    }
    if (full.length < 3) {
      throw FormatException('Pairing code payload is too short', code);
    }
    final payload = Uint8List.sublistView(full, 0, full.length - 2);
    final checksum = Uint8List.sublistView(full, full.length - 2);
    final expected = await _checksum(payload);
    if (checksum[0] != expected[0] || checksum[1] != expected[1]) {
      throw FormatException(
        'Pairing code checksum mismatch — check for a transcription error',
        code,
      );
    }
    try {
      return SyncSetKey.decode(payload);
    } on FormatException catch (e) {
      throw FormatException(
        'Pairing code decoded but its payload is not a valid SyncSetKey: '
        '${e.message}',
        code,
      );
    }
  }

  /// Computes the 2-byte checksum: the leading bytes of `SHA-256(payload)`.
  static Future<Uint8List> _checksum(Uint8List payload) async {
    final digest = await Sha256().hash(payload);
    return Uint8List.fromList(digest.bytes.sublist(0, 2));
  }

  // ── Base32 (RFC 4648, uppercase, no padding) ──────────────────────────────

  static String _base32Encode(Uint8List bytes) {
    final buffer = StringBuffer();
    var value = 0;
    var bits = 0;
    for (final byte in bytes) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        buffer.write(_kAlphabet[(value >> bits) & 0x1f]);
      }
    }
    if (bits > 0) {
      buffer.write(_kAlphabet[(value << (5 - bits)) & 0x1f]);
    }
    return buffer.toString();
  }

  static Uint8List _base32Decode(String encoded) {
    var value = 0;
    var bits = 0;
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < encoded.length; i++) {
      final index = _kAlphabet.indexOf(encoded[i]);
      if (index < 0) {
        throw FormatException(
          'Invalid base32 character "${encoded[i]}" at position $i',
        );
      }
      value = (value << 5) | index;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.addByte((value >> bits) & 0xff);
      }
    }
    return out.toBytes();
  }

  static String _group(String encoded) {
    final buffer = StringBuffer();
    for (var i = 0; i < encoded.length; i += _kGroupSize) {
      if (i > 0) buffer.write('-');
      final end = (i + _kGroupSize < encoded.length)
          ? i + _kGroupSize
          : encoded.length;
      buffer.write(encoded.substring(i, end));
    }
    return buffer.toString();
  }
}
