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

import 'dart:io' show Platform;

import 'cache_tier.dart';

/// Detects the [CacheTier] for the current native (dart:io) environment.
///
/// Returns [CacheTier.mobile] on Android or iOS, [CacheTier.desktop] otherwise.
CacheTier detectCacheTier() {
  if (Platform.isAndroid || Platform.isIOS)
    return CacheTier.mobile; // coverage:ignore-line
  return CacheTier.desktop;
}
