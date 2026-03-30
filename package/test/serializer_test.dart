import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('ZSerializer lifecycle', () {
    test('creates serializer and finishes to ZBytes', () {
      final serializer = ZSerializer();
      final bytes = serializer.finish();
      expect(bytes, isNotNull);
      bytes.dispose();
    });

    test('dispose releases resources without finish', () {
      final serializer = ZSerializer();
      expect(() => serializer.dispose(), returnsNormally);
    });

    test('dispose is idempotent', () {
      final serializer = ZSerializer();
      serializer.dispose();
      expect(() => serializer.dispose(), returnsNormally);
    });

    test('finish then finish again throws StateError', () {
      final serializer = ZSerializer();
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(() => serializer.finish(), throwsStateError);
    });

    test('finish then dispose is safe', () {
      final serializer = ZSerializer();
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(() => serializer.dispose(), returnsNormally);
    });

    test('operations after dispose throw StateError', () {
      final serializer = ZSerializer();
      serializer.dispose();
      expect(() => serializer.finish(), throwsStateError);
    });
  });
}
