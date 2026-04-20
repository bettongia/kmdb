// Copyright 2026 The KMDB Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

/// Magic number match rule for identifying file types based on their contents.
class Magic {
  final int priority;
  final List<Match> _matches;

  const Magic({required List<Match> matches, this.priority = 50})
    : _matches = matches;

  @override
  int get hashCode =>
      Object.hash(priority, const ListEquality().hash(_matches));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Magic &&
          runtimeType == other.runtimeType &&
          priority == other.priority &&
          const ListEquality().equals(_matches, other._matches);

  List<Match> get matches => UnmodifiableListView(_matches);

  Set<int> match(List<int> bytes) {
    final results = <int>{};
    for (final m in _matches) {
      if (m.matches(bytes)) {
        results.add(priority);
      }
    }
    return results;
  }

  Map<String, dynamic> toMap() {
    return {
      'priority': priority,
      'match': matches.map((e) => e.toMap()).toList(),
    };
  }

  @override
  String toString() => jsonEncode(toMap());
}

/// Types of data that can be matched in a magic rule.
enum MatchType {
  string('string'),
  big16('big16'),
  big32('big32'),
  little16('little16'),
  little32('little32'),
  host16('host16'),
  host32('host32'),
  byte('byte');

  final String value;

  const MatchType(this.value);

  static MatchType? tryParse(String value) {
    for (var t in MatchType.values) {
      if (t.value == value) {
        return t;
      }
    }
    return null;
  }

  @override
  String toString() => value;
}

/// A single match condition within a magic rule.
class Match {
  final String offset;
  final MatchType type;
  final String value;
  final String? mask;
  final List<Match> _subMatches;

  const Match({
    required this.offset,
    required this.type,
    required this.value,
    this.mask,
    List<Match> subMatches = const [],
  }) : _subMatches = subMatches;

  List<Match> get subMatches => UnmodifiableListView(_subMatches);

  @override
  int get hashCode => Object.hash(
    offset,
    type,
    value,
    mask,
    const ListEquality().hash(_subMatches),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Match &&
          runtimeType == other.runtimeType &&
          offset == other.offset &&
          type == other.type &&
          value == other.value &&
          mask == other.mask &&
          const ListEquality().equals(_subMatches, other._subMatches);

  /// Check if [bytes] matches this magic match rule.
  ///
  /// Parses the [offset] (single value or `start:end` range), converts
  /// [value] to bytes based on [type], optionally applies [mask], then
  /// checks for a match at each candidate offset position.
  ///
  /// If this match succeeds and [subMatches] is non-empty, at least one
  /// sub-match must also succeed (AND with parent, OR among children).
  bool matches(List<int> bytes) {
    // Parse offset — either "N" or "N:M".
    final (startOffset, endOffset) = _parseOffset(offset);

    // Convert the value string to a list of bytes based on the match type.
    final valueBytes = _valueToBytes(value, type);
    if (valueBytes.isEmpty) return false;

    // Convert the mask string to bytes, if present.
    final maskBytes = mask != null ? _hexToBytes(mask!) : null;

    // Try matching at each candidate offset in the range.
    final rangeEnd = endOffset ?? startOffset;
    for (var pos = startOffset; pos <= rangeEnd; pos++) {
      if (pos + valueBytes.length > bytes.length) break;

      if (_matchesAt(bytes, pos, valueBytes, maskBytes)) {
        // If there are sub-matches, at least one must also match (OR).
        if (_subMatches.isEmpty) return true;
        for (final sub in _subMatches) {
          if (sub.matches(bytes)) return true;
        }
        // Parent matched but no sub-match did.
        continue;
      }
    }
    return false;
  }

  /// Compare [valueBytes] against [bytes] at [position], applying [maskBytes]
  /// if provided.
  static bool _matchesAt(
    List<int> bytes,
    int position,
    List<int> valueBytes,
    List<int>? maskBytes,
  ) {
    for (var i = 0; i < valueBytes.length; i++) {
      var fileByte = bytes[position + i];
      var valueByte = valueBytes[i];
      if (maskBytes != null && i < maskBytes.length) {
        fileByte &= maskBytes[i];
        valueByte &= maskBytes[i];
      }
      if (fileByte != valueByte) return false;
    }
    return true;
  }

  /// Parse an offset string: "N" returns (N, null), "N:M" returns (N, M).
  static (int, int?) _parseOffset(String offset) {
    final parts = offset.split(':');
    final start = int.parse(parts[0]);
    final end = parts.length > 1 ? int.parse(parts[1]) : null;
    return (start, end);
  }

  /// Convert a [value] string to bytes based on the [MatchType].
  static List<int> _valueToBytes(String value, MatchType type) {
    switch (type) {
      case MatchType.string:
        // The value is a Dart string with escape sequences already decoded
        // at code-gen time; convert to raw bytes.
        return value.codeUnits;

      case MatchType.byte:
        return [_parseHexInt(value)];

      case MatchType.big16:
        final v = _parseHexInt(value);
        return [(v >> 8) & 0xFF, v & 0xFF];

      case MatchType.big32:
        final v = _parseHexInt(value);
        return [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

      case MatchType.little16:
        final v = _parseHexInt(value);
        return [v & 0xFF, (v >> 8) & 0xFF];

      case MatchType.little32:
        final v = _parseHexInt(value);
        return [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

      case MatchType.host16:
        final v = _parseHexInt(value);
        if (Endian.host == Endian.little) {
          return [v & 0xFF, (v >> 8) & 0xFF];
        } else {
          return [(v >> 8) & 0xFF, v & 0xFF];
        }

      case MatchType.host32:
        final v = _parseHexInt(value);
        if (Endian.host == Endian.little) {
          return [
            v & 0xFF,
            (v >> 8) & 0xFF,
            (v >> 16) & 0xFF,
            (v >> 24) & 0xFF,
          ];
        } else {
          return [
            (v >> 24) & 0xFF,
            (v >> 16) & 0xFF,
            (v >> 8) & 0xFF,
            v & 0xFF,
          ];
        }
    }
  }

  /// Parse a hex string like "0xBEEFC0DE" or decimal string into an int.
  static int _parseHexInt(String s) {
    if (s.startsWith('0x') || s.startsWith('0X')) {
      return int.parse(s.substring(2), radix: 16);
    }
    return int.parse(s);
  }

  /// Convert a hex mask string like "0xffffff00ffffffff" to a list of bytes.
  static List<int> _hexToBytes(String hex) {
    var s = hex;
    if (s.startsWith('0x') || s.startsWith('0X')) {
      s = s.substring(2);
    }
    // Pad to even length.
    if (s.length.isOdd) {
      s = '0$s';
    }
    final result = <int>[];
    for (var i = 0; i < s.length; i += 2) {
      result.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  Map<String, dynamic> toMap() {
    return {
      'offset': offset,
      'datatype': type.name,
      'value': value,
      if (mask != null) 'mask': mask,
      if (_subMatches.isNotEmpty)
        'match': _subMatches.map((e) => e.toMap()).toList(),
    };
  }

  @override
  String toString() => jsonEncode(toMap());
}
