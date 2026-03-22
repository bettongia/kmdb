import 'dart:io';

class PlatformUtils {
  /// Returns true if the current platform is a desktop platform (macOS, Windows, or Linux).
  bool get isDesktop {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }
}
