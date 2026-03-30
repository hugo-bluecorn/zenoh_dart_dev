import 'dart:typed_data';

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

  group('ZDeserializer round-trip', () {
    test('uint8 round-trip', () {
      final ser = ZSerializer();
      ser.serializeUint8(42);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint8(), equals(42));
      expect(deser.isDone, isTrue);
    });

    test('uint16 round-trip', () {
      final ser = ZSerializer();
      ser.serializeUint16(1000);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint16(), equals(1000));
      expect(deser.isDone, isTrue);
    });

    test('uint32 round-trip', () {
      final ser = ZSerializer();
      ser.serializeUint32(51000000);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint32(), equals(51000000));
      expect(deser.isDone, isTrue);
    });

    test('uint64 round-trip', () {
      final ser = ZSerializer();
      ser.serializeUint64(1000000000005);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint64(), equals(1000000000005));
      expect(deser.isDone, isTrue);
    });

    test('int8 round-trip', () {
      final ser = ZSerializer();
      ser.serializeInt8(-5);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt8(), equals(-5));
      expect(deser.isDone, isTrue);
    });

    test('int16 round-trip', () {
      final ser = ZSerializer();
      ser.serializeInt16(-1000);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt16(), equals(-1000));
      expect(deser.isDone, isTrue);
    });

    test('int32 round-trip', () {
      final ser = ZSerializer();
      ser.serializeInt32(51000000);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt32(), equals(51000000));
      expect(deser.isDone, isTrue);
    });

    test('int64 round-trip', () {
      final ser = ZSerializer();
      ser.serializeInt64(-1000000000005);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeInt64(), equals(-1000000000005));
      expect(deser.isDone, isTrue);
    });

    test('float round-trip with tolerance', () {
      final ser = ZSerializer();
      ser.serializeFloat(10.1);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeFloat(), closeTo(10.1, 0.01));
      expect(deser.isDone, isTrue);
    });

    test('double round-trip exact', () {
      final ser = ZSerializer();
      ser.serializeDouble(-105.001);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeDouble(), equals(-105.001));
      expect(deser.isDone, isTrue);
    });

    test('bool round-trip', () {
      final ser = ZSerializer();
      ser.serializeBool(true);
      ser.serializeBool(false);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeBool(), isTrue);
      expect(deser.deserializeBool(), isFalse);
      expect(deser.isDone, isTrue);
    });

    test('string round-trip', () {
      final ser = ZSerializer();
      ser.serializeString('hello zenoh');
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeString(), equals('hello zenoh'));
      expect(deser.isDone, isTrue);
    });

    test('bytes/slice round-trip', () {
      final ser = ZSerializer();
      ser.serializeBytes(Uint8List.fromList([1, 2, 3, 4]));
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeBytes(), equals([1, 2, 3, 4]));
      expect(deser.isDone, isTrue);
    });

    test('empty string round-trip', () {
      final ser = ZSerializer();
      ser.serializeString('');
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeString(), equals(''));
      expect(deser.isDone, isTrue);
    });

    test('empty bytes round-trip', () {
      final ser = ZSerializer();
      ser.serializeBytes(Uint8List(0));
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeBytes(), equals(<int>[]));
      expect(deser.isDone, isTrue);
    });

    test('zero values round-trip', () {
      final ser = ZSerializer();
      ser.serializeUint8(0);
      ser.serializeInt64(0);
      ser.serializeDouble(0.0);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint8(), equals(0));
      expect(deser.deserializeInt64(), equals(0));
      expect(deser.deserializeDouble(), equals(0.0));
      expect(deser.isDone, isTrue);
    });

    test('boundary values round-trip', () {
      final ser = ZSerializer();
      ser.serializeUint8(255);
      ser.serializeInt8(-128);
      ser.serializeInt8(127);
      ser.serializeInt64(0x7FFFFFFFFFFFFFFF);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint8(), equals(255));
      expect(deser.deserializeInt8(), equals(-128));
      expect(deser.deserializeInt8(), equals(127));
      expect(deser.deserializeInt64(), equals(0x7FFFFFFFFFFFFFFF));
      expect(deser.isDone, isTrue);
    });

    test('isDone false with remaining data', () {
      final ser = ZSerializer();
      ser.serializeUint32(42);
      ser.serializeString('extra');
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      addTearDown(deser.dispose);
      expect(deser.deserializeUint32(), equals(42));
      expect(deser.isDone, isFalse);
    });

    test('dispose frees deserializer', () {
      final ser = ZSerializer();
      ser.serializeUint8(1);
      final bytes = ser.finish();
      addTearDown(bytes.dispose);

      final deser = ZDeserializer(bytes);
      expect(() => deser.dispose(), returnsNormally);
    });
  });
}
