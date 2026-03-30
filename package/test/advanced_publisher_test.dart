import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('AdvancedPublisher', () {
    late Session session;

    setUpAll(() {
      final config = Config();
      config.insertJson5('timestamping/enabled', 'true');
      session = Session.open(config: config);
    });

    tearDownAll(() {
      session.close();
    });

    test('declareAdvancedPublisher returns an AdvancedPublisher', () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub');
      expect(publisher, isA<AdvancedPublisher>());
      publisher.close();
    });

    test('AdvancedPublisher.keyExpr returns the declared key expression', () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub');
      expect(publisher.keyExpr, equals('demo/example/adv-pub'));
      publisher.close();
    });

    test('AdvancedPublisher.close completes without error', () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub');
      expect(() => publisher.close(), returnsNormally);
    });

    test('AdvancedPublisher.close is idempotent', () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub');
      publisher.close();
      expect(() => publisher.close(), returnsNormally);
    });

    test('declareAdvancedPublisher on closed session throws StateError', () {
      final closedConfig = Config();
      closedConfig.insertJson5('timestamping/enabled', 'true');
      final closedSession = Session.open(config: closedConfig);
      closedSession.close();
      expect(
        () => closedSession.declareAdvancedPublisher('demo/example/adv-pub'),
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
      'declareAdvancedPublisher with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.declareAdvancedPublisher(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );

    test('declareAdvancedPublisher with default options succeeds', () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub-default');
      expect(publisher, isA<AdvancedPublisher>());
      publisher.close();
    });

    test('AdvancedPublisher.put publishes a string without error', () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub-put');
      addTearDown(publisher.close);
      expect(() => publisher.put('Hello advanced'), returnsNormally);
    });

    test('AdvancedPublisher.putBytes publishes ZBytes and consumes the payload',
        () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub-putbytes');
      addTearDown(publisher.close);
      final payload = ZBytes.fromString('raw data');
      expect(() => publisher.putBytes(payload), returnsNormally);
      expect(() => payload.nativePtr, throwsA(isA<StateError>()));
    });

    test('AdvancedPublisher.deleteResource completes without error', () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub-del');
      addTearDown(publisher.close);
      expect(() => publisher.deleteResource(), returnsNormally);
    });

    test('AdvancedPublisher.put after close throws StateError', () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub-closed');
      publisher.close();
      expect(
        () => publisher.put('test'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('All AdvancedPublisher operations after close throw StateError', () {
      final publisher =
          session.declareAdvancedPublisher('demo/example/adv-pub-closed-all');
      publisher.close();
      expect(() => publisher.putBytes(ZBytes.fromString('x')),
          throwsA(isA<StateError>()));
      expect(() => publisher.deleteResource(), throwsA(isA<StateError>()));
      expect(() => publisher.keyExpr, throwsA(isA<StateError>()));
    });
  }); // AdvancedPublisher group
}
