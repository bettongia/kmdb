// Copyright 2026 The Authors
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
import 'package:ffi/ffi.dart';

// ── Opaque handle types ───────────────────────────────────────────────────────

final class OrtEnv extends Opaque {}

final class OrtSession extends Opaque {}

final class OrtSessionOptions extends Opaque {}

final class OrtValue extends Opaque {}

final class OrtStatus extends Opaque {}

final class OrtMemoryInfo extends Opaque {}

// ── OrtApiBase: the one real exported symbol ──────────────────────────────────

// OrtApiBase* OrtGetApiBase()
typedef OrtGetApiBaseC = Pointer<Void> Function();
typedef OrtGetApiBaseDart = Pointer<Void> Function();

// slot 0 of OrtApiBase: const OrtApi* GetApi(uint32_t version)
typedef GetApiC = Pointer<Void> Function(Uint32);
typedef GetApiDart = Pointer<Void> Function(int);

// ── OrtApi vtable slot typedefs ───────────────────────────────────────────────
// These match the field ORDER in struct OrtApi in onnxruntime_c_api.h.
// Slots we don't call are noted but not bound.

// slot 0: CreateStatus
typedef CreateStatusC = Pointer<OrtStatus> Function(Int32, Pointer<Utf8>);
typedef CreateStatusDart = Pointer<OrtStatus> Function(int, Pointer<Utf8>);

// slot 1: GetErrorCode  (unused, but occupies a slot)
// slot 2: GetErrorMessage
typedef GetErrorMessageC = Pointer<Utf8> Function(Pointer<OrtStatus>);
typedef GetErrorMessageDart = Pointer<Utf8> Function(Pointer<OrtStatus>);

// slot 3: CreateEnv
typedef CreateEnvC =
    Pointer<OrtStatus> Function(Int32, Pointer<Utf8>, Pointer<Pointer<OrtEnv>>);
typedef CreateEnvDart =
    Pointer<OrtStatus> Function(int, Pointer<Utf8>, Pointer<Pointer<OrtEnv>>);

// slots 4-6: CreateEnvWithCustomLogger, EnableTelemetryEvents,
//            DisableTelemetryEvents  (all unused)

// slot 7: CreateSession
typedef CreateSessionC =
    Pointer<OrtStatus> Function(
      Pointer<OrtEnv>,
      Pointer<Utf8>,
      Pointer<OrtSessionOptions>,
      Pointer<Pointer<OrtSession>>,
    );
typedef CreateSessionDart =
    Pointer<OrtStatus> Function(
      Pointer<OrtEnv>,
      Pointer<Utf8>,
      Pointer<OrtSessionOptions>,
      Pointer<Pointer<OrtSession>>,
    );

// slot 8: CreateSessionFromArray  (unused)

// slot 9: Run
typedef RunC =
    Pointer<OrtStatus> Function(
      Pointer<OrtSession>,
      Pointer<Void>,
      Pointer<Pointer<Utf8>>,
      Pointer<Pointer<OrtValue>>,
      Size,
      Pointer<Pointer<Utf8>>,
      Size,
      Pointer<Pointer<OrtValue>>,
    );
typedef RunDart =
    Pointer<OrtStatus> Function(
      Pointer<OrtSession>,
      Pointer<Void>,
      Pointer<Pointer<Utf8>>,
      Pointer<Pointer<OrtValue>>,
      int,
      Pointer<Pointer<Utf8>>,
      int,
      Pointer<Pointer<OrtValue>>,
    );

// slot 10: CreateSessionOptions
typedef CreateSessionOptionsC =
    Pointer<OrtStatus> Function(Pointer<Pointer<OrtSessionOptions>>);
typedef CreateSessionOptionsDart =
    Pointer<OrtStatus> Function(Pointer<Pointer<OrtSessionOptions>>);

// slot 24: SetIntraOpNumThreads — forces single-threaded intra-op execution,
//          avoiding thread-pool teardown races during ReleaseSession.
typedef SetIntraOpNumThreadsC =
    Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>, Int32);
typedef SetIntraOpNumThreadsDart =
    Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>, int);

// slot 25: SetInterOpNumThreads
typedef SetInterOpNumThreadsC =
    Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>, Int32);
typedef SetInterOpNumThreadsDart =
    Pointer<OrtStatus> Function(Pointer<OrtSessionOptions>, int);

// slots 11-23, 26-48: various functions we don't use here

// slot 49: CreateTensorWithDataAsOrtValue
typedef CreateTensorC =
    Pointer<OrtStatus> Function(
      Pointer<OrtMemoryInfo>,
      Pointer<Void>,
      Size,
      Pointer<Int64>,
      Size,
      Int32,
      Pointer<Pointer<OrtValue>>,
    );
typedef CreateTensorDart =
    Pointer<OrtStatus> Function(
      Pointer<OrtMemoryInfo>,
      Pointer<Void>,
      int,
      Pointer<Int64>,
      int,
      int,
      Pointer<Pointer<OrtValue>>,
    );

// slot 50: IsTensor (unused)

// slot 51: GetTensorMutableData
typedef GetTensorDataC =
    Pointer<OrtStatus> Function(Pointer<OrtValue>, Pointer<Pointer<Void>>);
typedef GetTensorDataDart =
    Pointer<OrtStatus> Function(Pointer<OrtValue>, Pointer<Pointer<Void>>);

// slots 52-68: various functions we don't use here

// slot 69: CreateCpuMemoryInfo
typedef CreateMemoryInfoC =
    Pointer<OrtStatus> Function(Int32, Int32, Pointer<Pointer<OrtMemoryInfo>>);
typedef CreateMemoryInfoDart =
    Pointer<OrtStatus> Function(int, int, Pointer<Pointer<OrtMemoryInfo>>);

// slots 70-94: various functions we don't use here

// Release functions (void, no OrtStatus return)
// slot 92: ReleaseEnv
typedef ReleaseEnvC = Void Function(Pointer<OrtEnv>);
typedef ReleaseEnvDart = void Function(Pointer<OrtEnv>);

// slot 93: ReleaseStatus
typedef ReleaseStatusC = Void Function(Pointer<OrtStatus>);
typedef ReleaseStatusDart = void Function(Pointer<OrtStatus>);

// slot 94: ReleaseMemoryInfo
typedef ReleaseMemoryInfoC = Void Function(Pointer<OrtMemoryInfo>);
typedef ReleaseMemoryInfoDart = void Function(Pointer<OrtMemoryInfo>);

// slot 95: ReleaseSession
typedef ReleaseSessionC = Void Function(Pointer<OrtSession>);
typedef ReleaseSessionDart = void Function(Pointer<OrtSession>);

// slot 96: ReleaseValue
typedef ReleaseValueC = Void Function(Pointer<OrtValue>);
typedef ReleaseValueDart = void Function(Pointer<OrtValue>);

// slot 97: ReleaseRunOptions (unused here)

// slot 100: ReleaseSessionOptions
typedef ReleaseSessionOptionsC = Void Function(Pointer<OrtSessionOptions>);
typedef ReleaseSessionOptionsDart = void Function(Pointer<OrtSessionOptions>);

// ── Constants ─────────────────────────────────────────────────────────────────

const int onnxInt64 = 7; // ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
const int onnxFloat = 1; // ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
const int ortLoggingWarning = 2;
const int ortDeviceAllocator = 0;
const int ortMemTypeCpuInput = -2;

// Must match the library version you downloaded in ort_library.dart
const int ortApiVersion = 22; // ORT 1.22.x
