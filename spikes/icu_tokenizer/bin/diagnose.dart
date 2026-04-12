// Copyright 2026 The KMDB Authors.
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

// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Raw ICU FFI — mirrors icu_tokeniser.dart but prints every span + status
// value so we can see exactly what Apple's libicucore is returning.

typedef _UbrkOpenNative = Pointer<Void> Function(
  Int32 type, Pointer<Utf8> locale, Pointer<Uint16> text,
  Int32 textLength, Pointer<Int32> status,
);
typedef _UbrkOpen = Pointer<Void> Function(
  int type, Pointer<Utf8> locale, Pointer<Uint16> text,
  int textLength, Pointer<Int32> status,
);

typedef _UbrkNextNative = Int32 Function(Pointer<Void> bi);
typedef _UbrkNext = int Function(Pointer<Void> bi);

typedef _UbrkGetRuleStatusNative = Int32 Function(Pointer<Void> bi);
typedef _UbrkGetRuleStatus = int Function(Pointer<Void> bi);

typedef _UbrkCloseNative = Void Function(Pointer<Void> bi);
typedef _UbrkClose = void Function(Pointer<Void> bi);

void main() {
  if (!Platform.isMacOS) {
    print('Diagnostic written for macOS only.');
    exit(1);
  }

  final lib = DynamicLibrary.open('libicucore.dylib');

  final ubrkOpen   = lib.lookupFunction<_UbrkOpenNative, _UbrkOpen>('ubrk_open');
  final ubrkNext   = lib.lookupFunction<_UbrkNextNative, _UbrkNext>('ubrk_next');
  final ubrkStatus = lib.lookupFunction<_UbrkGetRuleStatusNative, _UbrkGetRuleStatus>('ubrk_getRuleStatus');
  final ubrkClose  = lib.lookupFunction<_UbrkCloseNative, _UbrkClose>('ubrk_close');

  const inputs = [
    'Jekyll',
    '   \t\n  ',
    'mTLS',
    '0x8004210B',
    'Hello, world!',
  ];

  for (final text in inputs) {
    _diagnose(text, ubrkOpen, ubrkNext, ubrkStatus, ubrkClose);
  }
}

void _diagnose(
  String text,
  _UbrkOpen ubrkOpen,
  _UbrkNext ubrkNext,
  _UbrkGetRuleStatus ubrkStatus,
  _UbrkClose ubrkClose,
) {
  final codeUnits = text.codeUnits;
  final len = codeUnits.length;

  final textBuf  = calloc<Uint16>(len == 0 ? 1 : len);
  final statusBuf = calloc<Int32>();

  for (var i = 0; i < len; i++) {
    textBuf[i] = codeUnits[i];
  }

  // UBRK_WORD = 2
  final bi = ubrkOpen(2, Pointer<Utf8>.fromAddress(0), textBuf, len, statusBuf);
  print('input: ${_repr(text)}  (ubrk_open status=${statusBuf.value})');
  print('  ${'span'.padRight(20)} status  classification');
  print('  ${'----'.padRight(20)} ------  --------------');

  var start = 0;
  while (true) {
    final end = ubrkNext(bi);
    if (end == -1) break;               // UBRK_DONE

    final status = ubrkStatus(bi);
    final span = text.substring(start, end);
    final cls = _classify(status);

    print('  ${_repr(span).padRight(20)} ${status.toString().padLeft(6)}  $cls');
    start = end;
  }

  ubrkClose(bi);
  calloc.free(textBuf);
  calloc.free(statusBuf);
  print('');
}

String _classify(int status) {
  if (status < 0)   return 'warning/unknown';
  if (status < 100) return 'NON-WORD (space/punct)';
  if (status < 200) return 'NUMBER';
  if (status < 300) return 'LETTER';
  if (status < 400) return 'KANA';
  if (status < 500) return 'IDEO';
  return 'other ($status)';
}

String _repr(String s) => s
    .replaceAll('\t', r'\t')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r');
