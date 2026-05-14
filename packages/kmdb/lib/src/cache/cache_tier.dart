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

// Conditional export selects the correct [detectCacheTier] implementation.
export '_cache_tier_detect_stub.dart'
    if (dart.library.io) '_cache_tier_detect_native.dart'
    if (dart.library.js_interop) '_cache_tier_detect_web.dart';

/// Describes the caching strategy tier for a given platform.
///
/// The tier controls two tuneable values:
///
/// - **[maxSessionObjects]** — capacity of the in-memory session object cache.
///   Desktop has more RAM and longer process lifetimes so the cap is higher.
/// - **[requiresPersistentCache]** — whether the materialised view cache
///   (`$cache` namespace) is required. Mobile and web processes are killed
///   silently so the persistent cache is needed for a warm cold-start.
///
/// ## Auto-detection
///
/// Call [detectCacheTier] to get the tier for the current runtime environment.
/// The implementation is platform-conditional:
///
/// - **Web** (`dart.library.js_interop`): always [CacheTier.web].
/// - **Native** (`dart.library.io`): checks [Platform.isAndroid] /
///   [Platform.isIOS] for [CacheTier.mobile]; otherwise [CacheTier.desktop].
///
/// ## Overriding in tests
///
/// Pass `tier:` explicitly to [CacheLayer] to bypass auto-detection.
enum CacheTier {
  /// macOS, Windows, or Linux desktop.
  ///
  /// Long-lived process; large session cache; persistent materialised view
  /// cache is optional.
  desktop,

  /// iOS or Android mobile.
  ///
  /// Process silently killed; small session cache; persistent materialised view
  /// cache required.
  mobile,

  /// Web (dart2js or Wasm).
  ///
  /// Every page reload is a cold start; small session cache; persistent
  /// materialised view cache required.
  web;

  /// Maximum number of decoded objects held in the session cache.
  int get maxSessionObjects => switch (this) {
    CacheTier.desktop => 2000,
    CacheTier.mobile || CacheTier.web => 256,
  };

  /// Whether the persistent materialised view cache (`$cache`) is required.
  ///
  /// `true` on mobile and web; `false` on desktop.
  bool get requiresPersistentCache => this != CacheTier.desktop;
}
