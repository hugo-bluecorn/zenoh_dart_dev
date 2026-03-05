import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('Zenoh', () {
    test('initLog does not throw', () {
      // initLog is idempotent — safe to call in tests.
      expect(() => Zenoh.initLog('error'), returnsNormally);
    });

    test('initLog accepts various filter levels', () {
      // Subsequent calls are no-ops in zenoh-c, but should not throw.
      expect(() => Zenoh.initLog('warn'), returnsNormally);
      expect(() => Zenoh.initLog('info'), returnsNormally);
    });
  });
}
