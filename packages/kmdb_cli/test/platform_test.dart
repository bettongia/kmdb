import 'package:test/test.dart';
import 'package:kmdb_cli/platform_utils.dart';

void main() {
  group('PlatformUtils', () {
    test('isDesktop returns true for macOS, Windows, or Linux', () {
      // Since we are running on a desktop during development, 
      // we can at least verify that it returns true for the current platform.
      final utils = PlatformUtils();
      expect(utils.isDesktop, isTrue);
    });
  });
}
