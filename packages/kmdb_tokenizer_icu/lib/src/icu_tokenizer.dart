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

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:kmdb_lexical/lexical.dart' show Tokenizer;

// ---------------------------------------------------------------------------
// ICU constants
// ---------------------------------------------------------------------------

/// UBreakIteratorType value for word boundary analysis.
const int _ubrkWord = 2;

/// Sentinel returned by ubrk_next() when iteration is complete.
///
/// ICU defines UBRK_DONE as (int32_t)0xFFFFFFFF — i.e. -1 in signed form.
const int _ubrkDone = -1;

// ---------------------------------------------------------------------------
// Native function typedefs
// ---------------------------------------------------------------------------

/// `ubrk_open` — allocates a UBreakIterator.
///
/// Passing address 0 for [locale] selects ICU's default (root) locale, which
/// is sufficient for script-level word boundary rules.
typedef _UbrkOpenNative =
    Pointer<Void> Function(
      Int32 type,
      Pointer<Utf8> locale,
      Pointer<Uint16> text,
      Int32 textLength,
      Pointer<Int32> status,
    );
typedef _UbrkOpen =
    Pointer<Void> Function(
      int type,
      Pointer<Utf8> locale,
      Pointer<Uint16> text,
      int textLength,
      Pointer<Int32> status,
    );

/// `ubrk_next` — advance to the next boundary; returns position or [_ubrkDone].
typedef _UbrkNextNative = Int32 Function(Pointer<Void> bi);
typedef _UbrkNext = int Function(Pointer<Void> bi);

/// `ubrk_close` — release the UBreakIterator.
typedef _UbrkCloseNative = Void Function(Pointer<Void> bi);
typedef _UbrkClose = void Function(Pointer<Void> bi);

// ---------------------------------------------------------------------------
// Library loader
// ---------------------------------------------------------------------------

/// Opens the system ICU library appropriate for the current platform.
///
/// ICU is bundled with every target OS that KMDB supports:
///
/// | Platform    | Library                              |
/// |-------------|--------------------------------------|
/// | macOS / iOS | libicucore.dylib  (ships with OS)    |
/// | Android     | libicuuc.so       (NDK)              |
/// | Linux       | libicuuc.so.NN    (widely packaged)  |
/// | Windows     | icu.dll           (Windows 10+)      |
///
/// Throws [UnsupportedError] if no matching library can be found.
DynamicLibrary _openIcuLibrary() {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('libicucore.dylib');
  }

  if (Platform.isAndroid) {
    return DynamicLibrary.open('libicuuc.so');
  }

  if (Platform.isLinux) {
    // The unversioned symlink (libicuuc.so) requires the -dev package.
    // Try versioned names common across distributions.
    const candidates = [
      'libicuuc.so',
      'libicuuc.so.76',
      'libicuuc.so.74',
      'libicuuc.so.73',
      'libicuuc.so.72',
      'libicuuc.so.70',
      'libicuuc.so.67',
      'libicuuc.so.66',
    ];
    for (final name in candidates) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {
        // try next candidate
      }
    }
    throw UnsupportedError(
      'Could not find libicuuc on this Linux system. '
      'Install libicu-dev (Debian/Ubuntu) or icu (Arch/Fedora).',
    );
  }

  if (Platform.isWindows) {
    const candidates = ['icu.dll', 'icuuc.dll', 'icuuc74.dll', 'icuuc70.dll'];
    for (final name in candidates) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {
        // try next candidate
      }
    }
    throw UnsupportedError('Could not find ICU DLL on this Windows system.');
  }

  throw UnsupportedError(
    'IcuTokenizer is not supported on ${Platform.operatingSystem}.',
  );
}

// ---------------------------------------------------------------------------
// IcuTokenizer
// ---------------------------------------------------------------------------

/// A [Tokenizer] backed by the ICU C library's UBRK_WORD break iterator.
///
/// Conforms to UAX #29 Unicode Text Segmentation and handles non-Latin scripts
/// (CJK, Thai, Arabic, etc.) correctly. This is the implementation to adopt
/// when multi-language support is added to the lexical search index.
///
/// ## Deployment
///
/// ICU is a system library on all of KMDB's target platforms — no bundling is
/// required and there is no App Store risk:
///
/// | Platform    | Library                              |
/// |-------------|--------------------------------------|
/// | macOS / iOS | libicucore.dylib  (ships with OS)    |
/// | Android     | libicuuc.so       (NDK)              |
/// | Linux       | libicuuc.so.NN    (widely packaged)  |
/// | Windows     | icu.dll           (Windows 10+)      |
///
/// ## Platform note — ubrk_getRuleStatus
///
/// Apple's libicucore does not include UAX #29 rule-status tags in its
/// compiled word break rules, so `ubrk_getRuleStatus()` returns non-standard
/// values on macOS/iOS. This implementation therefore uses Dart's own Unicode
/// `RegExp` for span classification rather than relying on rule-status codes.
/// Boundary *positions* from the ICU iterator are correct on all platforms.
///
/// Construct once and reuse — the FFI bindings are resolved at construction
/// time. Each call to [tokenise] allocates a temporary native UTF-16 buffer
/// and releases it before returning.
///
/// Throws [UnsupportedError] if the ICU library cannot be found or if the
/// required symbols are absent.
class IcuTokenizer implements Tokenizer {
  // Retain the DynamicLibrary reference to prevent the OS from unloading the
  // library while this tokenizer is alive.
  // ignore: unused_field
  final DynamicLibrary _lib;
  final _UbrkOpen _ubrkOpen;
  final _UbrkNext _ubrkNext;
  final _UbrkClose _ubrkClose;

  /// Opens the system ICU library and resolves the FFI symbols.
  ///
  /// Throws [UnsupportedError] if the library cannot be found on this platform.
  IcuTokenizer() : this._fromLib(_openIcuLibrary());

  IcuTokenizer._fromLib(DynamicLibrary lib)
    : _lib = lib,
      _ubrkOpen = lib.lookupFunction<_UbrkOpenNative, _UbrkOpen>('ubrk_open'),
      _ubrkNext = lib.lookupFunction<_UbrkNextNative, _UbrkNext>('ubrk_next'),
      _ubrkClose = lib.lookupFunction<_UbrkCloseNative, _UbrkClose>(
        'ubrk_close',
      );

  // Matches any Unicode letter or digit — used to classify ICU spans.
  //
  // NOTE: ubrk_getRuleStatus() is NOT used for span classification. Apple's
  // libicucore does not include the UAX #29 rule-status tags in its compiled
  // word break rules, so the function returns 0 for all letter/number spans
  // and non-zero for certain whitespace sequences — the inverse of the
  // upstream ICU convention. Character-based classification is both more
  // portable and simpler.
  static final _hasWordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  // Strips leading/trailing non-letter/non-digit characters from a span.
  // Some ICU builds (including Apple's) group adjacent punctuation into the
  // same span as the word (e.g. "Hello," rather than "Hello" + ",").
  static final _leadingNonWord = RegExp(r'^[^\p{L}\p{N}]+', unicode: true);
  static final _trailingNonWord = RegExp(r'[^\p{L}\p{N}]+$', unicode: true);

  @override
  List<String> tokenise(String text) {
    if (text.isEmpty) return const [];

    final codeUnits = text.codeUnits;
    final len = codeUnits.length;

    // Allocate a native UTF-16 buffer and an error-code cell.
    final textBuf = calloc<Uint16>(len);
    final statusBuf = calloc<Int32>();

    try {
      // Copy the Dart string's UTF-16 code units into native memory.
      // Dart strings are encoded as UTF-16 internally; codeUnits gives the
      // correct uint16_t values for BMP characters (the common case).
      for (var i = 0; i < len; i++) {
        textBuf[i] = codeUnits[i];
      }

      // Open a UBRK_WORD iterator. Passing address 0 for locale means
      // "default locale"; for script-level word breaking this is fine.
      final bi = _ubrkOpen(
        _ubrkWord,
        Pointer<Utf8>.fromAddress(0), // nullptr → default locale
        textBuf,
        len,
        statusBuf,
      );

      _checkStatus(statusBuf.value, 'ubrk_open');

      try {
        final tokens = <String>[];
        var start = 0;

        while (true) {
          final end = _ubrkNext(bi);
          if (end == _ubrkDone) break;

          final span = text.substring(start, end);

          // Include the span only if it contains at least one letter or digit.
          // Then strip any punctuation that was grouped at either end.
          if (_hasWordChar.hasMatch(span)) {
            final word = span
                .replaceFirst(_leadingNonWord, '')
                .replaceFirst(_trailingNonWord, '');
            if (word.isNotEmpty) tokens.add(word);
          }

          start = end;
        }

        return tokens;
      } finally {
        _ubrkClose(bi);
      }
    } finally {
      calloc.free(textBuf);
      calloc.free(statusBuf);
    }
  }

  /// Throws [StateError] if [statusCode] indicates a fatal ICU error.
  ///
  /// ICU's UErrorCode convention (unicode/utypes.h):
  ///   < 0  warnings (non-fatal — e.g. U_USING_DEFAULT_WARNING = -127)
  ///   = 0  U_ZERO_ERROR (success)
  ///   > 0  errors (fatal — e.g. U_ILLEGAL_ARGUMENT_ERROR = 1)
  void _checkStatus(int statusCode, String fn) {
    if (statusCode > 0) {
      throw StateError('ICU error in $fn: UErrorCode $statusCode');
    }
  }
}
