// Copyright 2026 The KMDB Authors
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
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ort_bindings.dart';

/// Reads one function-pointer slot from an OrtApi struct and returns a typed
/// native function pointer.
///
/// [struct] is a pointer to the start of the vtable struct.
/// [slotIndex] is the zero-based slot index of the function pointer.
Pointer<NativeFunction<T>> _slotPtr<T extends Function>(
  Pointer<Void> struct,
  int slotIndex,
) => (struct.cast<Pointer<NativeFunction<T>>>() + slotIndex).value;

/// A thin FFI wrapper around an ONNX Runtime inference session.
///
/// Wraps the ORT C API vtable pattern — all function pointers are resolved
/// at session-creation time via [_slotPtr]. This avoids the need for
/// generated FFI bindings (ffigen) and keeps the integration self-contained.
///
/// ## Lifecycle
///
/// 1. Call [create] to open a model file and initialise the session.
/// 2. Call [run] one or more times to perform inference.
/// 3. Call [dispose] when finished to release native resources.
///
/// **ORT sessions are thread-affine.** All calls to [run] and [dispose] must
/// originate from the same isolate that called [create]. Spawning a separate
/// `Isolate` for inference causes ORT's internal thread pool to tear down
/// when the isolate exits, corrupting shared mutex state.
///
/// ## Input / output tensor shapes for BGE Small En v1.5
///
/// Three int64 input tensors, all shaped `[1, seqLen]`:
/// - `input_ids` — BERT token IDs produced by [BertTokenizer.encode].
/// - `attention_mask` — 1 for real tokens, 0 for padding.
/// - `token_type_ids` — all zeros for single-segment input.
///
/// Single output tensor `last_hidden_state` has shape `[1, seqLen, 384]`
/// and contains float32 per-token contextual embeddings. Callers must
/// mean-pool over non-padding positions and L2-normalise to get the sentence
/// embedding.
class OrtInferenceSession {
  final Pointer<OrtSession> _session;
  final Pointer<OrtMemoryInfo> _memInfo;
  final Pointer<OrtEnv> _env;

  /// Retained pointer to the OrtApi vtable for deferred function binding.
  final Pointer<Void> _api;

  OrtInferenceSession._(this._session, this._memInfo, this._env, this._api);

  /// Opens [modelPath] and creates an ONNX Runtime inference session.
  ///
  /// [lib] is the ORT [DynamicLibrary] opened by [openOrtLibrary].
  /// [modelPath] must be the absolute path to a `.onnx` model file.
  ///
  /// Sets intra-op and inter-op thread counts to 1 to prevent thread-pool
  /// teardown races when running from a single Dart isolate.
  ///
  /// Throws [Exception] if the ORT version is incompatible or the model file
  /// cannot be loaded.
  static OrtInferenceSession create(DynamicLibrary lib, String modelPath) {
    return using((arena) {
      // ── Step 1: get OrtApiBase* ─────────────────────────────────────────
      final getApiBase = lib.lookupFunction<OrtGetApiBaseC, OrtGetApiBaseDart>(
        'OrtGetApiBase',
      );
      final apiBase = getApiBase();
      if (apiBase == nullptr) throw Exception('OrtGetApiBase() returned null');

      // ── Step 2: get OrtApi* via slot 0 of OrtApiBase ────────────────────
      final getApi = _slotPtr<GetApiC>(apiBase, 0).asFunction<GetApiDart>();
      final api = getApi(ortApiVersion);
      if (api == nullptr) {
        throw Exception(
          'OrtApi v$ortApiVersion not supported by this library.',
        );
      }

      // ── Step 3: bind error-handling helpers ─────────────────────────────
      final getErrorMessage = _slotPtr<GetErrorMessageC>(
        api,
        2,
      ).asFunction<GetErrorMessageDart>();
      final releaseStatus = _slotPtr<ReleaseStatusC>(
        api,
        93,
      ).asFunction<ReleaseStatusDart>();

      void check(Pointer<OrtStatus> status) {
        if (status == nullptr) return;
        final msg = getErrorMessage(status).toDartString();
        releaseStatus(status);
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
          'kmdb_inferencing'.toNativeUtf8(allocator: arena),
          envPtr,
        ),
      );
      final env = envPtr.value;

      // slot 10: CreateSessionOptions
      final createOpts = _slotPtr<CreateSessionOptionsC>(
        api,
        10,
      ).asFunction<CreateSessionOptionsDart>();
      final optsPtr = arena<Pointer<OrtSessionOptions>>();
      check(createOpts(optsPtr));
      final opts = optsPtr.value;

      // Limit to single-threaded execution to avoid teardown races when
      // ORT is called from a single Dart isolate.
      final setIntra = _slotPtr<SetIntraOpNumThreadsC>(
        api,
        24,
      ).asFunction<SetIntraOpNumThreadsDart>();
      final setInter = _slotPtr<SetInterOpNumThreadsC>(
        api,
        25,
      ).asFunction<SetInterOpNumThreadsDart>();
      check(setIntra(opts, 1));
      check(setInter(opts, 1));

      // slot 7: CreateSession — loads the .onnx model file
      final createSess = _slotPtr<CreateSessionC>(
        api,
        7,
      ).asFunction<CreateSessionDart>();
      final sessPtr = arena<Pointer<OrtSession>>();
      check(
        createSess(
          env,
          modelPath.toNativeUtf8(allocator: arena),
          opts,
          sessPtr,
        ),
      );

      // slot 69: CreateCpuMemoryInfo — allocator descriptor for input tensors
      final createMem = _slotPtr<CreateMemoryInfoC>(
        api,
        69,
      ).asFunction<CreateMemoryInfoDart>();
      final memPtr = arena<Pointer<OrtMemoryInfo>>();
      check(createMem(ortDeviceAllocator, ortMemTypeCpuInput, memPtr));

      // Release session options — no longer needed after CreateSession.
      final releaseOpts = _slotPtr<ReleaseSessionOptionsC>(
        api,
        100,
      ).asFunction<ReleaseSessionOptionsDart>();
      releaseOpts(opts);

      return OrtInferenceSession._(sessPtr.value, memPtr.value, env, api);
    });
  }

  /// Runs inference on the provided int64 input tensors and returns the flat
  /// float32 output logits.
  ///
  /// [inputNames] — tensor names in model declaration order, e.g.
  /// `['input_ids', 'attention_mask', 'token_type_ids']`.
  ///
  /// [inputData] — parallel list of [Int64List] values. Each list must have
  /// `inputShape[1]` elements (one per token position).
  ///
  /// [inputShape] — `[1, seqLen]` for all BGE inputs.
  ///
  /// [outputName] — name of the output tensor, e.g. `'last_hidden_state'`.
  /// For BGE Small En v1.5 this tensor has shape `[1, seqLen, 384]`, so the
  /// returned list has `seqLen * 384` elements.
  ///
  /// All native [OrtValue] handles are released before returning.
  List<double> run({
    required List<String> inputNames,
    required List<Int64List> inputData,
    required List<int> inputShape,
    required String outputName,
  }) {
    return using((arena) {
      final getErrorMessage = _slotPtr<GetErrorMessageC>(
        _api,
        2,
      ).asFunction<GetErrorMessageDart>();
      final releaseStatus = _slotPtr<ReleaseStatusC>(
        _api,
        93,
      ).asFunction<ReleaseStatusDart>();
      void check(Pointer<OrtStatus> s) {
        if (s == nullptr) return;
        final msg = getErrorMessage(s).toDartString();
        releaseStatus(s);
        throw Exception('ONNX Runtime: $msg');
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
        96,
      ).asFunction<ReleaseValueDart>();

      // Build the shared shape array for all input tensors.
      final shapePtr = arena<Int64>(inputShape.length);
      for (var i = 0; i < inputShape.length; i++) {
        shapePtr[i] = inputShape[i];
      }

      // Allocate and populate one OrtValue per input tensor.
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

      // Build C-string arrays for input and output tensor names.
      final inNames = arena<Pointer<Utf8>>(inputNames.length);
      for (var i = 0; i < inputNames.length; i++) {
        inNames[i] = inputNames[i].toNativeUtf8(allocator: arena);
      }
      final outNameArr = arena<Pointer<Utf8>>(1);
      outNameArr[0] = outputName.toNativeUtf8(allocator: arena);

      // Run inference.
      final outputPtrs = arena<Pointer<OrtValue>>(1);
      check(
        run(
          _session,
          nullptr,
          inNames,
          inputPtrs,
          inputNames.length,
          outNameArr,
          1,
          outputPtrs,
        ),
      );

      // Extract float32 logits from the output tensor.
      final rawPtr = arena<Pointer<Void>>();
      check(getTensorData(outputPtrs[0], rawPtr));

      final seqLen = inputShape[1];
      const hiddenDim = 384;
      final floatPtr = rawPtr.value.cast<Float>();
      final result = List<double>.generate(
        seqLen * hiddenDim,
        (i) => floatPtr[i].toDouble(),
      );

      // Release all OrtValue handles before returning.
      releaseValue(outputPtrs[0]);
      for (var i = 0; i < inputNames.length; i++) {
        releaseValue(inputPtrs[i]);
      }

      return result;
    });
  }

  /// Releases the native ORT session, memory info, and environment handles.
  ///
  /// Must be called exactly once. After [dispose], [run] must not be called.
  void dispose() {
    final releaseSession = _slotPtr<ReleaseSessionC>(
      _api,
      95,
    ).asFunction<ReleaseSessionDart>();
    final releaseMem = _slotPtr<ReleaseMemoryInfoC>(
      _api,
      94,
    ).asFunction<ReleaseMemoryInfoDart>();
    final releaseEnv = _slotPtr<ReleaseEnvC>(
      _api,
      92,
    ).asFunction<ReleaseEnvDart>();

    releaseSession(_session);
    releaseMem(_memInfo);
    releaseEnv(_env);
  }
}
