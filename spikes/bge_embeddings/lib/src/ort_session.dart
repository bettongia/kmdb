// Copyright 2026 The Aurochs KMesh Authors
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

import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'ort_bindings.dart';

/// Reads one function-pointer slot from an OrtApi (or OrtApiBase) struct,
/// returning a typed native function pointer.
///
/// Each slot is a native pointer-sized word. [slotIndex] is zero-based from
/// the start of the struct, matching the field order in onnxruntime_c_api.h.
/// Call `.asFunction<D>()` on the result with the corresponding Dart typedef
/// to get a callable Dart function — `asFunction` requires a compile-time
/// constant type, so it cannot be called inside this generic helper.
Pointer<NativeFunction<T>> _slotPtr<T extends Function>(
  Pointer<Void> struct,
  int slotIndex,
) => (struct.cast<Pointer<NativeFunction<T>>>() + slotIndex).value;

class OrtInferenceSession {
  final Pointer<OrtSession> _session;
  final Pointer<OrtMemoryInfo> _memInfo;
  final Pointer<Void> _api; // OrtApi* — kept for release calls

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
      final getApi = _slotPtr<GetApiC>(apiBase, 0).asFunction<GetApiDart>();
      final api = getApi(ortApiVersion);
      if (api == nullptr) {
        throw Exception(
          'OrtApi v$ortApiVersion not supported by this library. '
          'Check that _ortVersion in ort_library.dart matches ortApiVersion here.',
        );
      }

      // ── Step 3: bind the functions we need from OrtApi ───────────────────
      // Slot numbers match struct OrtApi field order in onnxruntime_c_api.h

      final getErrorMessage = _slotPtr<GetErrorMessageC>(
        api,
        2,
      ).asFunction<GetErrorMessageDart>();

      void check(Pointer<OrtStatus> status) {
        if (status == nullptr) return;
        final msg = getErrorMessage(status).toDartString();
        throw Exception('ONNX Runtime: $msg');
      }

      // slot 3: CreateEnv
      final createEnv = _slotPtr<CreateEnvC>(
        api,
        3,
      ).asFunction<CreateEnvDart>();
      final envPtr = arena<Pointer<OrtEnv>>();
      check(
        createEnv(
          ortLoggingWarning,
          'bge'.toNativeUtf8(allocator: arena),
          envPtr,
        ),
      );

      // slot 10: CreateSessionOptions
      final createOpts = _slotPtr<CreateSessionOptionsC>(
        api,
        10,
      ).asFunction<CreateSessionOptionsDart>();
      final optsPtr = arena<Pointer<OrtSessionOptions>>();
      check(createOpts(optsPtr));

      // Disable the intra-op and inter-op thread pools so that ReleaseSession
      // does not race against worker threads that may still be quiescing.
      final setIntra = _slotPtr<SetIntraOpNumThreadsC>(
        api,
        24,
      ).asFunction<SetIntraOpNumThreadsDart>();
      final setInter = _slotPtr<SetInterOpNumThreadsC>(
        api,
        25,
      ).asFunction<SetInterOpNumThreadsDart>();
      check(setIntra(optsPtr.value, 1));
      check(setInter(optsPtr.value, 1));

      // slot 7: CreateSession
      final createSess = _slotPtr<CreateSessionC>(
        api,
        7,
      ).asFunction<CreateSessionDart>();
      final sessPtr = arena<Pointer<OrtSession>>();
      check(
        createSess(
          envPtr.value,
          modelPath.toNativeUtf8(allocator: arena),
          optsPtr.value,
          sessPtr,
        ),
      );

      // slot 69: CreateCpuMemoryInfo
      final createMem = _slotPtr<CreateMemoryInfoC>(
        api,
        69,
      ).asFunction<CreateMemoryInfoDart>();
      final memPtr = arena<Pointer<OrtMemoryInfo>>();
      check(createMem(ortDeviceAllocator, ortMemTypeCpuInput, memPtr));

      return OrtInferenceSession._(sessPtr.value, memPtr.value, api);
    });
  }

  /// Run inference. Returns the flattened float output tensor.
  List<double> run({
    required List<String> inputNames,
    required List<Int64List> inputData,
    required List<int> inputShape, // [batch, seqLen]
    required String outputName,
  }) {
    return using((arena) {
      // Bind the functions we need from OrtApi
      final getErrorMessage = _slotPtr<GetErrorMessageC>(
        _api,
        2,
      ).asFunction<GetErrorMessageDart>();
      void check(Pointer<OrtStatus> s) {
        if (s == nullptr) return;
        throw Exception('ONNX Runtime: ${getErrorMessage(s).toDartString()}');
      }

      final createTensor = _slotPtr<CreateTensorC>(
        _api,
        49,
      ).asFunction<CreateTensorDart>();
      final run = _slotPtr<RunC>(_api, 9).asFunction<RunDart>();
      final getTensorData = _slotPtr<GetTensorDataC>(
        _api,
        51,
      ).asFunction<GetTensorDataDart>();
      final releaseValue = _slotPtr<ReleaseValueC>(
        _api,
        /* ReleaseValue slot */ 96,
      ).asFunction<ReleaseValueDart>();

      // Build shape array
      final shapePtr = arena<Int64>(inputShape.length);
      for (var i = 0; i < inputShape.length; i++) {
        shapePtr[i] = inputShape[i];
      }

      // Build input tensors
      final inputPtrs = arena<Pointer<OrtValue>>(inputNames.length);
      for (var i = 0; i < inputNames.length; i++) {
        final data = inputData[i];
        final dataPtr = arena<Int64>(data.length);
        for (var j = 0; j < data.length; j++) {
          dataPtr[j] = data[j];
        }

        final valPtr = arena<Pointer<OrtValue>>();
        check(
          createTensor(
            _memInfo,
            dataPtr.cast<Void>(),
            data.length * sizeOf<Int64>(),
            shapePtr,
            inputShape.length,
            onnxInt64,
            valPtr,
          ),
        );
        inputPtrs[i] = valPtr.value;
      }

      // Input and output name arrays
      final inNames = arena<Pointer<Utf8>>(inputNames.length);
      for (var i = 0; i < inputNames.length; i++) {
        inNames[i] = inputNames[i].toNativeUtf8(allocator: arena);
      }
      final outName = arena<Pointer<Utf8>>(1);
      outName[0] = outputName.toNativeUtf8(allocator: arena);

      final outputPtrs = arena<Pointer<OrtValue>>(1);
      check(
        run(
          _session,
          nullptr, // default OrtRunOptions
          inNames,
          inputPtrs,
          inputNames.length,
          outName,
          1,
          outputPtrs,
        ),
      );

      // Extract float32 data from output [1, seqLen, 384]
      final rawPtr = arena<Pointer<Void>>();
      check(getTensorData(outputPtrs[0], rawPtr));

      final seqLen = inputShape[1];
      const hiddenDim = 384;
      final floatPtr = rawPtr.value.cast<Float>();
      final result = List<double>.generate(
        seqLen * hiddenDim,
        (i) => floatPtr[i].toDouble(),
      );

      releaseValue(outputPtrs[0]);
      return result;
    });
  }

  void dispose() {
    final releaseSession = _slotPtr<ReleaseSessionC>(
      _api,
      /* ReleaseSession slot */ 95,
    ).asFunction<ReleaseSessionDart>();
    releaseSession(_session);
  }
}
