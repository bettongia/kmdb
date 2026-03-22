/*
 Copyright 2026 The Aurochs KMesh Authors

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

      https://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import 'dart:convert';
import 'dart:io';

/// Utility methods for platform-specific information.
class PlatformUtils {
  /// Returns `true` if the current platform is a desktop platform (macOS, Windows, or Linux).
  bool get isDesktop {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlatformUtils && runtimeType == other.runtimeType;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => json.encode(toMap());

  /// Returns a [Map] representation of this instance.
  Map<String, dynamic> toMap() => {
        'isDesktop': isDesktop,
      };
}
