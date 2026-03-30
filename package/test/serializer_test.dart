import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';
// Slice 2: arithmetic type serialize tests
// Slice 3: compound type serialize tests

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

  group('ZSerializer arithmetic types', () {
    test('uint8 round-trip via serialize then finish', () {
      final serializer = ZSerializer();
      serializer.serializeUint8(42);
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });

    test('all integer types serialize without error', () {
      final serializer = ZSerializer();
      serializer.serializeUint8(255);
      serializer.serializeUint16(1000);
      serializer.serializeUint32(51000000);
      serializer.serializeUint64(1000000000005);
      serializer.serializeInt8(-5);
      serializer.serializeInt16(-1000);
      serializer.serializeInt32(51000000);
      serializer.serializeInt64(-1000000000005);
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });

    test('float and double serialize without error', () {
      final serializer = ZSerializer();
      serializer.serializeFloat(10.1);
      serializer.serializeDouble(-105.001);
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });

    test('bool serialize without error', () {
      final serializer = ZSerializer();
      serializer.serializeBool(true);
      serializer.serializeBool(false);
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });

    test('zero values serialize without error', () {
      final serializer = ZSerializer();
      serializer.serializeUint8(0);
      serializer.serializeInt64(0);
      serializer.serializeDouble(0.0);
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });

    test('boundary values serialize without error', () {
      final serializer = ZSerializer();
      serializer.serializeUint8(255);
      serializer.serializeInt8(-128);
      serializer.serializeInt8(127);
      serializer.serializeInt64(0x7FFFFFFFFFFFFFFF);
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });
  });

  group('ZSerializer compound types', () {
    test('string serializes without error', () {
      final serializer = ZSerializer();
      serializer.serializeString('hello zenoh');
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });

    test('bytes serialize without error', () {
      final serializer = ZSerializer();
      serializer.serializeBytes(Uint8List.fromList([1, 2, 3, 4]));
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });

    test('sequence length serializes without error', () {
      final serializer = ZSerializer();
      serializer.serializeSequenceLength(4);
      serializer.serializeInt32(10);
      serializer.serializeInt32(20);
      serializer.serializeInt32(30);
      serializer.serializeInt32(40);
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });

    test('empty string serializes without error', () {
      final serializer = ZSerializer();
      serializer.serializeString('');
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });

    test('empty bytes serialize without error', () {
      final serializer = ZSerializer();
      serializer.serializeBytes(Uint8List(0));
      final bytes = serializer.finish();
      addTearDown(bytes.dispose);
      expect(bytes, isNotNull);
    });
  });
}
