import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('Publisher lifecycle', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declarePublisher returns a Publisher on valid key expression', () {
      final publisher = session.declarePublisher('demo/example/pub');
      expect(publisher, isA<Publisher>());
      publisher.close();
    });

    test('Publisher.keyExpr returns the declared key expression', () {
      final publisher = session.declarePublisher('demo/example/pub');
      expect(publisher.keyExpr, equals('demo/example/pub'));
      publisher.close();
    });

    test('Publisher.close completes without error', () {
      final publisher = session.declarePublisher('demo/example/pub');
      expect(() => publisher.close(), returnsNormally);
    });

    test('Publisher.close is idempotent (double-close safe)', () {
      final publisher = session.declarePublisher('demo/example/pub');
      publisher.close();
      expect(() => publisher.close(), returnsNormally);
    });

    test('declarePublisher on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.declarePublisher('demo/example/pub'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test(
      'declarePublisher with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.declarePublisher(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );

    test('Publisher.put publishes a string value without error', () {
      final publisher = session.declarePublisher('demo/example/pub-put');
      addTearDown(publisher.close);
      expect(() => publisher.put('Hello from publisher'), returnsNormally);
    });

    test('Publisher.putBytes publishes ZBytes and consumes the payload', () {
      final publisher = session.declarePublisher('demo/example/pub-bytes');
      addTearDown(publisher.close);
      final payload = ZBytes.fromString('raw data');
      expect(() => publisher.putBytes(payload), returnsNormally);
      expect(
        () => payload.nativePtr,
        throwsA(isA<StateError>()),
      );
    });

    test('Publisher.put with encoding override succeeds', () {
      final publisher = session.declarePublisher('demo/example/pub-enc');
      addTearDown(publisher.close);
      expect(
        () => publisher.put(
          'json data',
          encoding: Encoding.applicationJson,
        ),
        returnsNormally,
      );
    });

    test('Publisher.put with attachment succeeds and consumes attachment', () {
      final publisher = session.declarePublisher('demo/example/pub-att');
      addTearDown(publisher.close);
      final attachment = ZBytes.fromString('metadata');
      expect(
        () => publisher.put('value', attachment: attachment),
        returnsNormally,
      );
      expect(
        () => attachment.nativePtr,
        throwsA(isA<StateError>()),
      );
    });

    test('Publisher.putBytes with encoding and attachment succeeds', () {
      final publisher = session.declarePublisher('demo/example/pub-full');
      addTearDown(publisher.close);
      final payload = ZBytes.fromString('data');
      final attachment = ZBytes.fromString('meta');
      expect(
        () => publisher.putBytes(
          payload,
          encoding: Encoding.textPlain,
          attachment: attachment,
        ),
        returnsNormally,
      );
      expect(() => payload.nativePtr, throwsA(isA<StateError>()));
      expect(() => attachment.nativePtr, throwsA(isA<StateError>()));
    });

    test('Publisher.put after close throws StateError', () {
      final publisher = session.declarePublisher('demo/example/pub-closed');
      publisher.close();
      expect(() => publisher.put('test'), throwsA(isA<StateError>()));
    });

    test('Publisher operations after close throw StateError', () {
      final publisher = session.declarePublisher('demo/example/pub');
      publisher.close();

      expect(
        () => publisher.put('test'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => publisher.putBytes(ZBytes.fromString('test')),
        throwsA(isA<StateError>()),
      );
      expect(
        () => publisher.deleteResource(),
        throwsA(isA<StateError>()),
      );
      expect(
        () => publisher.keyExpr,
        throwsA(isA<StateError>()),
      );
      expect(
        () => publisher.hasMatchingSubscribers(),
        throwsA(isA<StateError>()),
      );
    });
  });
}
