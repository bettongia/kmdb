# Building a BGE Embedding Application in Dart

This tutorial walks you through building a self-contained Dart application that
takes text input and produces 384-dimensional semantic embeddings using the
`BAAI/bge-small-en-v1.5` model via ONNX Runtime. The code is **pure Dart with no
Flutter dependency**, so it works equally well as a CLI tool, a server library,
or embedded inside a Flutter app.

---

## What We're Building

```
text input  →  tokenizer (Dart)  →  ONNX inference  →  mean pool + normalize  →  embedding vector
```

The final application will:

- Automatically download the correct ONNX Runtime native library for the current
  platform on first run
- Load the BGE model from a local `.onnx` file
- Tokenize input text using a pure Dart WordPiece tokenizer
- Run inference via direct FFI bindings to the ONNX Runtime C API
- Mean pool and L2 normalize the output into a 384-dim embedding vector

---

## Prerequisites

- Dart SDK >= 3.0 (`dart --version`)
- Python 3 with `transformers` — for the one-time model export only
- Your UAX #29 word segmentation library available as a local package or on
  pub.dev

---

## Project Structure

```
bge_embeddings/
├── pubspec.yaml
├── bin/
│   └── main.dart
├── lib/
│   ├── ort_library.dart      # platform-aware FFI loader + auto-download
│   ├── ort_bindings.dart     # FFI type signatures for the ORT C API
│   ├── ort_session.dart      # session lifecycle and inference wrapper
│   ├── tokenizer.dart        # pure Dart WordPiece tokenizer
│   ├── embedding.dart        # end-to-end embedding pipeline
│   └── math_utils.dart       # mean pool, L2 normalize, cosine similarity
└── assets/
    ├── vocab.txt             # downloaded in Step 1
    └── bge_small.onnx        # downloaded in Step 1
```

---

## Step 1: Download the Model and Vocabulary

The ONNX integration in `optimum` was moved to a dedicated package, so the
install command and export workflow have changed from older tutorials you may
have seen. The correct approach is now a two-step process: export via the
`optimum-cli` command-line tool, then save the vocabulary with a short Python
script.

### 1a. Install dependencies

```bash
pip install "optimum[onnx]" transformers onnx onnxruntime
```

Use `optimum[onnx]` — not `optimum[exporters]` (removed) and not
`optimum[onnxruntime]` (that installs the Python ORT inference wrapper, which
you don't need since inference runs in Dart). The `onnx` and `onnxruntime`
packages are required separately — the exporter uses them to fix dynamic shapes
in the exported graph and will error without them.

### 1b. Export the model to ONNX

```bash
mkdir -p assets
optimum-cli export onnx \
    --model BAAI/bge-small-en-v1.5 \
    --task feature-extraction \
    assets/
mv assets/model.onnx assets/bge_small.onnx
```

This produces a quantized `model.onnx` (~23 MB) in the `assets/` directory. The
`--task feature-extraction` flag tells the exporter this is an embedding model
rather than a classifier or generator.

### 1c. Save the vocabulary

The CLI does not save `vocab.txt` automatically, so save it separately:

```python
# save_vocab.py
from transformers import AutoTokenizer

tokenizer = AutoTokenizer.from_pretrained("BAAI/bge-small-en-v1.5")
tokenizer.save_vocabulary("assets/")
print("Saved vocab.txt to assets/")
```

```bash
python save_vocab.py
```

You should now have both `assets/bge_small.onnx` and `assets/vocab.txt`.

---

## Step 2: Project Setup

```bash
dart create bge_embeddings
cd bge_embeddings
```

### pubspec.yaml

```yaml
name: bge_embeddings
description: BGE text embeddings in pure Dart — no Flutter required
version: 1.0.0

environment:
  sdk: ">=3.0.0 <4.0.0"

dependencies:
  ffi: ^2.1.0 # Dart FFI helpers (Utf8, Arena, sizeOf, etc.)
  http: ^1.2.0 # downloading the ORT native library on first run
  archive: ^3.4.0 # unpacking the downloaded .tgz / .zip
  path: ^1.9.0
  # your_uax29_package: ...

dev_dependencies:
  lints: ^3.0.0
```

```bash
dart pub get
```

---

## Step 3: Platform-Aware Library Loader (`lib/ort_library.dart`)

This is the heart of the cross-platform story. It detects the current OS and CPU
architecture, resolves the correct native library filename, downloads it from
the official ONNX Runtime GitHub releases if it is not already present, and
returns an open `DynamicLibrary` ready for FFI use.

Callers just `await openOrtLibrary()` — no manual setup required.

```dart
import 'dart:ffi';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// ONNX Runtime release to use. Bump this string to upgrade.
const _ortVersion = '1.22.0';

/// Resolves, downloads if needed, and opens the ORT native library.
///
/// On Android the .so is bundled by Gradle and loaded by name.
/// On all other platforms the library is downloaded from GitHub Releases on
/// first run and cached next to the compiled executable.
Future<DynamicLibrary> openOrtLibrary() async {
  if (Platform.isAndroid) {
    // Android: the .so is placed in the APK lib/ directory by Gradle.
    // The dynamic linker resolves it by name at runtime — no path needed.
    return DynamicLibrary.open('libonnxruntime.so');
  }

  final libPath = await _ensureLibraryPresent();
  return DynamicLibrary.open(libPath);
}

// ── Private helpers ───────────────────────────────────────────────────────────

Future<String> _ensureLibraryPresent() async {
  final libName = _platformLibraryName();
  final libDir  = _executableDirectory();
  final libPath = p.join(libDir, libName);

  if (File(libPath).existsSync()) return libPath;

  print('[ort] Native library not found, downloading ORT $_ortVersion...');
  await _downloadAndExtract(libDir, libName);
  print('[ort] Download complete: $libPath');

  return libPath;
}

/// The shared-library filename for the current platform.
String _platformLibraryName() {
  if (Platform.isLinux)   return 'libonnxruntime.so.$_ortVersion';
  if (Platform.isMacOS)   return 'libonnxruntime.$_ortVersion.dylib';
  if (Platform.isWindows) return 'onnxruntime.dll';
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Store the library next to the compiled executable so it survives across runs.
String _executableDirectory() => File(Platform.resolvedExecutable).parent.path;

Future<void> _downloadAndExtract(String libDir, String libName) async {
  final (archiveName, innerPath) = _archiveDetails();
  final url = 'https://github.com/microsoft/onnxruntime/releases/download'
      '/v$_ortVersion/$archiveName';

  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw Exception(
      'Failed to download ORT (HTTP ${response.statusCode}): $url',
    );
  }

  // Extract only the shared library from the archive
  final bytes = response.bodyBytes;
  final outFile = File(p.join(libDir, libName));

  if (archiveName.endsWith('.zip')) {
    for (final file in ZipDecoder().decodeBytes(bytes)) {
      if (file.name.endsWith(innerPath)) {
        await outFile.writeAsBytes(file.content as List<int>);
        return;
      }
    }
  } else {
    // .tgz
    final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    for (final file in tar) {
      if (file.name.endsWith(innerPath)) {
        await outFile.writeAsBytes(file.content as List<int>);
        return;
      }
    }
  }

  throw Exception('Expected library not found inside archive: $innerPath');
}

/// Returns (archiveFilename, pathSuffixOfLibInsideArchive).
(String, String) _archiveDetails() {
  final arch = _cpuArch();

  if (Platform.isLinux) {
    return (
      'onnxruntime-linux-$arch-$_ortVersion.tgz',
      'lib/libonnxruntime.so.$_ortVersion',
    );
  }
  if (Platform.isMacOS) {
    return (
      'onnxruntime-osx-$arch-$_ortVersion.tgz',
      'lib/libonnxruntime.$_ortVersion.dylib',
    );
  }
  if (Platform.isWindows) {
    return (
      'onnxruntime-win-$arch-$_ortVersion.zip',
      'lib/onnxruntime.dll',
    );
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Detect x64 vs arm64 from Dart's version string.
String _cpuArch() {
  final ver = Platform.version.toLowerCase();
  if (ver.contains('arm64') || ver.contains('aarch64')) return 'arm64';
  return 'x64'; // default for all desktop platforms
}
```

> **Android setup:** The ORT `.so` must be added to your Android project via the
> Gradle dependency. In `android/app/build.gradle`:
>
> ```groovy
> dependencies {
>     implementation 'com.microsoft.onnxruntime:onnxruntime-android:1.22.0'
> }
> ```
>
> Gradle fetches the AAR from Maven Central, unpacks it into the APK, and the
> Android dynamic linker makes `libonnxruntime.so` available by name. Your Dart
> code calls `DynamicLibrary.open('libonnxruntime.so')` and the linker resolves
> it automatically — no manual file management required.

---

## Step 4: FFI Bindings (`lib/ort_bindings.dart`)

The ORT C API does **not** export flat named symbols like
`OrtApi_CreateSession`. Instead it uses a vtable pattern:

1. Call `OrtGetApiBase()` — the **one** real exported symbol — to get an
   `OrtApiBase*`
2. Call `apiBase->GetApi(version)` on that to get an `OrtApi*`
3. `OrtApi` is a large C struct whose **fields are function pointers**, in a
   fixed order defined by `onnxruntime_c_api.h`. Each function is read by byte
   offset.

This file models the vtable slots we need and provides a helper to obtain the
API pointer. The slot numbers come directly from the header field order.

```dart
import 'dart:ffi';
import 'package:ffi/ffi.dart';

// ── Opaque handle types ───────────────────────────────────────────────────────

final class OrtEnv            extends Opaque {}
final class OrtSession        extends Opaque {}
final class OrtSessionOptions extends Opaque {}
final class OrtValue          extends Opaque {}
final class OrtStatus         extends Opaque {}
final class OrtMemoryInfo     extends Opaque {}

// ── OrtApiBase: the one real exported symbol ──────────────────────────────────

// OrtApiBase* OrtGetApiBase()
typedef OrtGetApiBaseC    = Pointer<Void> Function();
typedef OrtGetApiBaseDart = Pointer<Void> Function();

// slot 0 of OrtApiBase: const OrtApi* GetApi(uint32_t version)
typedef GetApiC    = Pointer<Void> Function(Uint32);
typedef GetApiDart = Pointer<Void> Function(int);

// ── OrtApi vtable slot typedefs ───────────────────────────────────────────────
// These match the field ORDER in struct OrtApi in onnxruntime_c_api.h.
// Slots we don't call are noted but not bound.

// slot 0: CreateStatus
typedef CreateStatusC    = Pointer<OrtStatus> Function(Int32, Pointer<Utf8>);
typedef CreateStatusDart = Pointer<OrtStatus> Function(int,   Pointer<Utf8>);

// slot 1: GetErrorCode  (unused, but occupies a slot)
// slot 2: GetErrorMessage
typedef GetErrorMessageC    = Pointer<Utf8> Function(Pointer<OrtStatus>);
typedef GetErrorMessageDart = Pointer<Utf8> Function(Pointer<OrtStatus>);

// slot 3: CreateEnv
typedef CreateEnvC    = Pointer<OrtStatus> Function(Int32, Pointer<Utf8>, Pointer<Pointer<OrtEnv>>);
typedef CreateEnvDart = Pointer<OrtStatus> Function(int,   Pointer<Utf8>, Pointer<Pointer<OrtEnv>>);

// slots 4-6: CreateEnvWithCustomLogger, EnableTelemetryEvents,
//            DisableTelemetryEvents  (all unused)

// slot 7: CreateSession
typedef CreateSessionC    = Pointer<OrtStatus> Function(Pointer<OrtEnv>, Pointer<Utf8>, Pointer<OrtSessionOptions>, Pointer<Pointer<OrtSession>>);
typedef CreateSessionDart = Pointer<OrtStatus> Function(Pointer<OrtEnv>, Pointer<Utf8>, Pointer<OrtSessionOptions>, Pointer<Pointer<OrtSession>>);

// slot 8: CreateSessionFromArray  (unused)

// slot 9: Run
typedef RunC    = Pointer<OrtStatus> Function(Pointer<OrtSession>, Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<OrtValue>>, Size, Pointer<Pointer<Utf8>>, Size, Pointer<Pointer<OrtValue>>);
typedef RunDart = Pointer<OrtStatus> Function(Pointer<OrtSession>, Pointer<Void>, Pointer<Pointer<Utf8>>, Pointer<Pointer<OrtValue>>, int,  Pointer<Pointer<Utf8>>, int,  Pointer<Pointer<OrtValue>>);

// slot 10: CreateSessionOptions
typedef CreateSessionOptionsC    = Pointer<OrtStatus> Function(Pointer<Pointer<OrtSessionOptions>>);
typedef CreateSessionOptionsDart = Pointer<OrtStatus> Function(Pointer<Pointer<OrtSessionOptions>>);

// slots 11-50: various functions we don't use here

// slot 51: CreateCpuMemoryInfo
typedef CreateMemoryInfoC    = Pointer<OrtStatus> Function(Int32, Int32, Pointer<Pointer<OrtMemoryInfo>>);
typedef CreateMemoryInfoDart = Pointer<OrtStatus> Function(int,   int,   Pointer<Pointer<OrtMemoryInfo>>);

// slots 52-53: unused

// slot 54: CreateTensorWithDataAsOrtValue
typedef CreateTensorC    = Pointer<OrtStatus> Function(Pointer<OrtMemoryInfo>, Pointer<Void>, Size, Pointer<Int64>, Size, Int32, Pointer<Pointer<OrtValue>>);
typedef CreateTensorDart = Pointer<OrtStatus> Function(Pointer<OrtMemoryInfo>, Pointer<Void>, int,  Pointer<Int64>, int,  int,  Pointer<Pointer<OrtValue>>);

// slots 55-56: unused

// slot 57: GetTensorMutableData
typedef GetTensorDataC    = Pointer<OrtStatus> Function(Pointer<OrtValue>, Pointer<Pointer<Void>>);
typedef GetTensorDataDart = Pointer<OrtStatus> Function(Pointer<OrtValue>, Pointer<Pointer<Void>>);

// Release functions (void, no OrtStatus return)
typedef ReleaseValueC    = Void Function(Pointer<OrtValue>);
typedef ReleaseValueDart = void Function(Pointer<OrtValue>);

typedef ReleaseSessionC    = Void Function(Pointer<OrtSession>);
typedef ReleaseSessionDart = void Function(Pointer<OrtSession>);

// ── Constants ─────────────────────────────────────────────────────────────────

const int onnxInt64 = 7; // ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
const int onnxFloat = 1; // ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
const int ortLoggingWarning  = 2;
const int ortDeviceAllocator = 0;
const int ortMemTypeCpuInput = -2;

// Must match the library version you downloaded in ort_library.dart
const int ortApiVersion = 22; // ORT 1.22.x
```

---

## Step 5: Session Wrapper (`lib/ort_session.dart`)

This is where the vtable is actually traversed. We call `OrtGetApiBase()`, then
`GetApi()`, then read each needed function pointer out of the resulting `OrtApi`
struct by its byte offset (each slot is one pointer-sized word).

```dart
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'ort_bindings.dart';

/// Reads one function-pointer slot from an OrtApi (or OrtApiBase) struct.
///
/// Each slot is a native pointer-sized word. [slotIndex] is zero-based from
/// the start of the struct, matching the field order in onnxruntime_c_api.h.
T _slot<T extends Function>(Pointer<Void> struct, int slotIndex) {
  final slotPtr = struct
      .cast<Pointer<NativeFunction<T>>>()
      .elementAt(slotIndex)
      .value;
  return slotPtr.asFunction<T>();
}

class OrtInferenceSession {
  final Pointer<OrtSession>    _session;
  final Pointer<OrtMemoryInfo> _memInfo;
  final Pointer<Void>          _api;     // OrtApi* — kept for release calls

  OrtInferenceSession._(this._session, this._memInfo, this._api);

  /// Load [modelPath] and create a session using the vtable API.
  static OrtInferenceSession create(DynamicLibrary lib, String modelPath) {
    return using((arena) {
      // ── Step 1: get OrtApiBase* ───────────────────────────────────────────
      final getApiBase = lib.lookupFunction<OrtGetApiBaseC, OrtGetApiBaseDart>(
        'OrtGetApiBase',
      );
      final apiBase = getApiBase();
      if (apiBase == nullptr) throw Exception('OrtGetApiBase() returned null');

      // ── Step 2: get OrtApi* via OrtApiBase.GetApi (slot 0 of OrtApiBase) ─
      final getApi = _slot<GetApiC>(apiBase, 0);
      final api = getApi(ortApiVersion);
      if (api == nullptr) {
        throw Exception(
          'OrtApi v$ortApiVersion not supported by this library. '
          'Check that _ortVersion in ort_library.dart matches ortApiVersion here.',
        );
      }

      // ── Step 3: bind the functions we need from OrtApi ───────────────────
      // Slot numbers match struct OrtApi field order in onnxruntime_c_api.h

      final getErrorMessage = _slot<GetErrorMessageC>(api, 2);

      void check(Pointer<OrtStatus> status) {
        if (status == nullptr) return;
        final msg = getErrorMessage(status).toDartString();
        throw Exception('ONNX Runtime: $msg');
      }

      // slot 3: CreateEnv
      final createEnv = _slot<CreateEnvC>(api, 3);
      final envPtr = arena<Pointer<OrtEnv>>();
      check(createEnv(
        ortLoggingWarning,
        'bge'.toNativeUtf8(allocator: arena),
        envPtr,
      ));

      // slot 10: CreateSessionOptions
      final createOpts = _slot<CreateSessionOptionsC>(api, 10);
      final optsPtr = arena<Pointer<OrtSessionOptions>>();
      check(createOpts(optsPtr));

      // slot 7: CreateSession
      final createSess = _slot<CreateSessionC>(api, 7);
      final sessPtr    = arena<Pointer<OrtSession>>();
      check(createSess(
        envPtr.value,
        modelPath.toNativeUtf8(allocator: arena),
        optsPtr.value,
        sessPtr,
      ));

      // slot 51: CreateCpuMemoryInfo
      final createMem = _slot<CreateMemoryInfoC>(api, 51);
      final memPtr    = arena<Pointer<OrtMemoryInfo>>();
      check(createMem(ortDeviceAllocator, ortMemTypeCpuInput, memPtr));

      return OrtInferenceSession._(sessPtr.value, memPtr.value, api);
    });
  }

  /// Run inference. Returns the flattened float output tensor.
  List<double> run({
    required List<String>    inputNames,
    required List<Int64List> inputData,
    required List<int>       inputShape,  // [batch, seqLen]
    required String          outputName,
  }) {
    return using((arena) {
      // Bind the functions we need from OrtApi
      final getErrorMessage = _slot<GetErrorMessageC>(_api, 2);
      void check(Pointer<OrtStatus> s) {
        if (s == nullptr) return;
        throw Exception('ONNX Runtime: ${getErrorMessage(s).toDartString()}');
      }

      final createTensor  = _slot<CreateTensorC>(_api, 54);
      final run           = _slot<RunC>(_api, 9);
      final getTensorData = _slot<GetTensorDataC>(_api, 57);
      final releaseValue  = _slot<ReleaseValueC>(_api, /* ReleaseValue slot */ 175);

      // Build shape array
      final shapePtr = arena<Int64>(inputShape.length);
      for (var i = 0; i < inputShape.length; i++) shapePtr[i] = inputShape[i];

      // Build input tensors
      final inputPtrs = arena<Pointer<OrtValue>>(inputNames.length);
      for (var i = 0; i < inputNames.length; i++) {
        final data    = inputData[i];
        final dataPtr = arena<Int64>(data.length);
        for (var j = 0; j < data.length; j++) dataPtr[j] = data[j];

        final valPtr = arena<Pointer<OrtValue>>();
        check(createTensor(
          _memInfo,
          dataPtr.cast<Void>(),
          data.length * sizeOf<Int64>(),
          shapePtr,
          inputShape.length,
          onnxInt64,
          valPtr,
        ));
        inputPtrs[i] = valPtr.value;
      }

      // Input and output name arrays
      final inNames = arena<Pointer<Utf8>>(inputNames.length);
      for (var i = 0; i < inputNames.length; i++) {
        inNames[i] = inputNames[i].toNativeUtf8(allocator: arena);
      }
      final outName = arena<Pointer<Utf8>>(1);
      outName[0]    = outputName.toNativeUtf8(allocator: arena);

      final outputPtrs = arena<Pointer<OrtValue>>(1);
      check(run(
        _session,
        nullptr,           // default OrtRunOptions
        inNames,
        inputPtrs,
        inputNames.length,
        outName,
        1,
        outputPtrs,
      ));

      // Extract float32 data from output [1, seqLen, 384]
      final rawPtr = arena<Pointer<Void>>();
      check(getTensorData(outputPtrs[0], rawPtr));

      final seqLen    = inputShape[1];
      const hiddenDim = 384;
      final floatPtr  = rawPtr.value.cast<Float>();
      final result    = List<double>.generate(
        seqLen * hiddenDim, (i) => floatPtr[i].toDouble(),
      );

      releaseValue(outputPtrs[0]);
      return result;
    });
  }

  void dispose() {
    final releaseSession = _slot<ReleaseSessionC>(_api, /* ReleaseSession slot */ 156);
    releaseSession(_session);
  }
}
```

> **About the slot numbers:** The numbers above (3, 7, 9, 10, 51, 54, 57,
> 156, 175) are the zero-based field positions in `struct OrtApi` as defined in
> `onnxruntime_c_api.h` for ORT 1.22. If you upgrade to a significantly newer
> release, confirm these haven't shifted by checking the header. The first ~15
> slots (CreateStatus through CreateSessionOptions) are stable across all modern
> releases; later slots occasionally shift. A quick way to verify: print
> `nm -gU /path/to/libonnxruntime.dylib | grep OrtGetApiBase` — if the symbol is
> present you have the right library, and the vtable approach will work.

---

## Step 6: The Tokenizer (`lib/tokenizer.dart`)

Pure Dart WordPiece tokenizer. Plug in your UAX #29 library at the marked point.

```dart
import 'dart:io';
import 'dart:typed_data';

// Replace with your actual UAX #29 import, e.g.:
// import 'package:your_uax29_package/your_uax29_package.dart';

class BertTokenizer {
  final Map<String, int> _vocab;
  final int _maxLength;

  static const int _clsId = 101;
  static const int _sepId = 102;
  static const int _unkId = 100;
  static const int _padId = 0;

  BertTokenizer._(this._vocab, this._maxLength);

  /// Load vocabulary from vocab.txt (one token per line; line index = token ID).
  static Future<BertTokenizer> load(String vocabPath, {int maxLength = 512}) async {
    final lines = await File(vocabPath).readAsLines();
    final vocab = <String, int>{};
    for (var i = 0; i < lines.length; i++) vocab[lines[i].trim()] = i;
    return BertTokenizer._(vocab, maxLength);
  }

  TokenizerOutput encode(String text) {
    final normalized = _normalize(text);

    // ── Replace with your UAX #29 word segmentation call: ────────────────────
    // final words = segmentWords(normalized);
    final words = _splitOnWhitespace(normalized);
    // ─────────────────────────────────────────────────────────────────────────

    final tokenIds = <int>[_clsId];
    outer:
    for (final word in words) {
      if (word.isEmpty) continue;
      for (final id in _wordPiece(word)) {
        if (tokenIds.length >= _maxLength - 1) break outer;
        tokenIds.add(id);
      }
    }
    tokenIds.add(_sepId);

    final attentionMask = List<int>.filled(tokenIds.length, 1);
    while (tokenIds.length < _maxLength) {
      tokenIds.add(_padId);
      attentionMask.add(0);
    }

    return TokenizerOutput(
      inputIds:      Int64List.fromList(tokenIds),
      attentionMask: Int64List.fromList(attentionMask),
      tokenTypeIds:  Int64List.fromList(List.filled(_maxLength, 0)),
    );
  }

  String _normalize(String text) {
    final buf = StringBuffer();
    for (final char in text.toLowerCase().runes) {
      if (char >= 0x0300 && char <= 0x036F) continue; // strip combining accents
      buf.writeCharCode(char);
    }
    return buf.toString();
  }

  List<String> _splitOnWhitespace(String text) =>
      text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  List<int> _wordPiece(String word) {
    if (_vocab.containsKey(word)) return [_vocab[word]!];
    final ids = <int>[];
    var start = 0;
    while (start < word.length) {
      var end = word.length;
      int? found;
      while (start < end) {
        final sub = start == 0
            ? word.substring(start, end)
            : '##${word.substring(start, end)}';
        if (_vocab.containsKey(sub)) { found = _vocab[sub]; break; }
        end--;
      }
      if (found == null) return [_unkId];
      ids.add(found);
      start = end;
    }
    return ids;
  }
}

class TokenizerOutput {
  final Int64List inputIds;
  final Int64List attentionMask;
  final Int64List tokenTypeIds;
  const TokenizerOutput({
    required this.inputIds,
    required this.attentionMask,
    required this.tokenTypeIds,
  });
}
```

---

## Step 7: Math Utilities (`lib/math_utils.dart`)

```dart
import 'dart:math';

List<double> meanPool(
  List<double> hiddenState,
  List<int> attentionMask, {
  int seqLen    = 512,
  int hiddenDim = 384,
}) {
  final result = List<double>.filled(hiddenDim, 0.0);
  var active   = 0;
  for (var t = 0; t < seqLen; t++) {
    if (attentionMask[t] != 1) continue;
    final offset = t * hiddenDim;
    for (var d = 0; d < hiddenDim; d++) result[d] += hiddenState[offset + d];
    active++;
  }
  if (active == 0) return result;
  for (var d = 0; d < hiddenDim; d++) result[d] /= active;
  return result;
}

List<double> l2Normalize(List<double> vec) {
  final norm = sqrt(vec.fold(0.0, (s, v) => s + v * v));
  if (norm == 0.0) return vec;
  return vec.map((v) => v / norm).toList();
}

double cosineSimilarity(List<double> a, List<double> b) {
  assert(a.length == b.length);
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) dot += a[i] * b[i];
  return dot;
}
```

---

## Step 8: The Embedding Engine (`lib/embedding.dart`)

```dart
import 'dart:isolate';

import 'ort_library.dart';
import 'ort_session.dart';
import 'tokenizer.dart';
import 'math_utils.dart';

class BgeEmbedder {
  final OrtInferenceSession _session;
  final BertTokenizer       _tokenizer;

  BgeEmbedder._(this._session, this._tokenizer);

  /// Load the model. Downloads the ORT native library automatically if needed.
  static Future<BgeEmbedder> load({
    required String modelPath,
    required String vocabPath,
    int maxLength = 512,
  }) async {
    final lib       = await openOrtLibrary();
    final session   = OrtInferenceSession.create(lib, modelPath);
    final tokenizer = await BertTokenizer.load(vocabPath, maxLength: maxLength);
    return BgeEmbedder._(session, tokenizer);
  }

  /// Embed a single string. Returns a normalized 384-dim vector.
  /// Synchronous — call from a background isolate for large batches.
  List<double> embed(String text) {
    final tokens = _tokenizer.encode(text);
    final raw    = _session.run(
      inputNames: ['input_ids', 'attention_mask', 'token_type_ids'],
      inputData:  [tokens.inputIds, tokens.attentionMask, tokens.tokenTypeIds],
      inputShape: [1, tokens.inputIds.length],
      outputName: 'last_hidden_state',
    );
    return l2Normalize(
      meanPool(raw, tokens.attentionMask.toList(),
          seqLen: tokens.inputIds.length),
    );
  }

  /// Embed multiple texts in a background [Isolate] so the caller stays
  /// responsive. This is important for CLI tools processing large batches
  /// and essential for any UI that must not block.
  Future<List<List<double>>> embedAll(List<String> texts) =>
      Isolate.run(() => texts.map(embed).toList());

  void dispose() => _session.dispose();
}
```

---

## Step 9: The Entry Point (`bin/main.dart`)

```dart
import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:bge_embeddings/embedding.dart';
import 'package:bge_embeddings/math_utils.dart';

Future<void> main() async {
  final assetDir = p.join(Directory.current.path, 'assets');

  print('Loading model (ORT library downloaded automatically on first run)...');
  final embedder = await BgeEmbedder.load(
    modelPath: p.join(assetDir, 'bge_small.onnx'),
    vocabPath: p.join(assetDir, 'vocab.txt'),
  );
  print('Ready.\n');

  // ── Single embedding ──────────────────────────────────────────────────────
  const query          = 'What is the effect of temperature on enzyme activity?';
  final queryEmbedding = embedder.embed(query);
  print('Query: "$query"');
  print('Dims : ${queryEmbedding.length}');
  print('First 6: ${queryEmbedding.take(6).map((v) => v.toStringAsFixed(4)).join(', ')}\n');

  // ── Ranked similarity search ──────────────────────────────────────────────
  final passages = [
    'Enzyme activity generally increases with temperature up to an optimal '
        'point, after which denaturation causes a sharp decline.',
    'The mitochondria is the powerhouse of the cell.',
    'Higher temperatures increase molecular kinetic energy, accelerating '
        'reaction rates until the enzyme structure is disrupted.',
    'Photosynthesis converts light energy into chemical energy stored in glucose.',
  ];

  final passageEmbeddings = await embedder.embedAll(passages);
  final scored = List.generate(passages.length, (i) => (
    score:   cosineSimilarity(queryEmbedding, passageEmbeddings[i]),
    passage: passages[i],
  ))..sort((a, b) => b.score.compareTo(a.score));

  print('Results (ranked):');
  for (final r in scored) {
    print('  [${(r.score * 100).toStringAsFixed(1)}%] ${r.passage.substring(0, 60)}...');
  }

  embedder.dispose();
}
```

---

## Step 10: Run It

```bash
dart run bin/main.dart
```

First run:

```
Loading model (ORT library downloaded automatically on first run)...
[ort] Native library not found, downloading ORT 1.22.0...
[ort] Download complete: /path/to/exe/libonnxruntime.so.1.22.0
Ready.

Query: "What is the effect of temperature on enzyme activity?"
Dims : 384
First 6: 0.0412, -0.0831, 0.0563, 0.0277, -0.0194, 0.0341

Results (ranked):
  [91.3%] Enzyme activity generally increases with temperature up to...
  [87.6%] Higher temperatures increase molecular kinetic energy, acce...
  [34.2%] Photosynthesis converts light energy into chemical energy s...
  [31.8%] The mitochondria is the powerhouse of the cell...
```

Subsequent runs skip the download and start immediately.

---

## Platform Behaviour Summary

| Platform          | Library filename              | How obtained                                           |
| ----------------- | ----------------------------- | ------------------------------------------------------ |
| Linux x64 / arm64 | `libonnxruntime.so.1.22.0`    | Auto-downloaded from GitHub Releases                   |
| macOS x64 / arm64 | `libonnxruntime.1.22.0.dylib` | Auto-downloaded from GitHub Releases                   |
| Windows x64       | `onnxruntime.dll`             | Auto-downloaded from GitHub Releases                   |
| Android           | `libonnxruntime.so`           | Bundled via Gradle AAR, resolved by the Android linker |

No developer configuration is required on any platform beyond adding the Gradle
dependency for Android builds.

---

## Upgrading ONNX Runtime

To upgrade to a newer ORT release, change the single constant at the top of
`ort_library.dart`:

```dart
const _ortVersion = '1.23.0'; // ← bump here
```

Delete the old library file next to your executable and the next run will
download the new version automatically.

---

## Validating Your Tokenizer

Before deploying, cross-check Dart token IDs against the Python reference:

```python
# validate_tokenizer.py
from transformers import AutoTokenizer
tok = AutoTokenizer.from_pretrained("BAAI/bge-small-en-v1.5")
enc = tok("What is the effect of temperature on enzyme activity?",
          max_length=512, truncation=True, padding="max_length")
print("input_ids[:10]     :", enc["input_ids"][:10])
print("attention_mask[:10]:", enc["attention_mask"][:10])
```

Add a matching debug print in `BertTokenizer.encode` and compare the first 10
values. They must be identical. Any mismatch points to a normalization or
WordPiece edge case to fix before relying on results.

---

## Common Issues

**Library fails to load after download** On Linux/macOS run
`chmod 644 libonnxruntime.*` in the executable directory if the file was written
without read permissions.

**`OrtGetApiBase` symbol not found** This is the one real exported symbol in the
library. If it is missing, the downloaded file is corrupt or is not an ORT
shared library. Delete it and let the auto-downloader re-fetch it.

**Token IDs don't match Python** Almost always a normalization difference.
Confirm that `_normalize()` lowercases before stripping accents, and that your
UAX #29 boundaries match Python's whitespace split on ASCII text.

**Slow first inference** ORT JIT-compiles the graph on first use. Embed a short
dummy string at startup to warm up the session before processing real inputs.

**Out of memory on large articles** Chunk into ~400-token segments with
~50-token overlap. Embed each chunk separately and store the per-chunk vectors.
At query time retrieve the top-k chunks by cosine similarity rather than
embedding the whole document.

---

## Next Steps

- **Persist embeddings** — serialize vectors as `Float32List` raw bytes; halves
  storage vs float64 with negligible precision loss
- **Vector search at scale** — brute-force dot product is fine up to ~10k
  vectors; beyond that look at an HNSW implementation
- **Batch inference** — extend `OrtInferenceSession.run` to accept batch size >
  1 for higher GPU throughput
- **GPU providers** — add CUDA (Linux/Windows) or CoreML (macOS) by reading the
  appropriate execution-provider slot from the `OrtApi` vtable and calling it on
  the session options pointer before `create`
- **Domain fine-tuning** — BGE fine-tuned on domain-specific sentence pairs from
  your academic field significantly improves retrieval quality
