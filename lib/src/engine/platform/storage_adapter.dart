/// Platform-agnostic file I/O abstraction used by the LSM engine.
///
/// Conditional exports select the correct implementation at compile time:
/// - Native (dart:io): [StorageAdapterNative]
/// - Web (OPFS via dart:js_interop): [StorageAdapterWeb] (Phase 8)
/// - In-memory (tests): [MemoryStorageAdapter]
library;

export 'storage_adapter_interface.dart';
export 'storage_adapter_memory.dart';
export 'storage_adapter_impl.dart'
    if (dart.library.io) 'storage_adapter_native.dart'
    if (dart.library.js_interop) 'storage_adapter_web.dart';
