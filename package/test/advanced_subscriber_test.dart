import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('AdvancedSubscriber', () {
    late Session session;

    setUpAll(() {
      final config = Config();
      config.insertJson5('timestamping/enabled', 'true');
      session = Session.open(config: config);
    });

    tearDownAll(() {
      session.close();
    });

    test('declareAdvancedSubscriber returns an AdvancedSubscriber', () {
      final subscriber =
          session.declareAdvancedSubscriber('demo/example/adv-sub');
      expect(subscriber, isA<AdvancedSubscriber>());
      subscriber.close();
    });

    test('AdvancedSubscriber.stream is a Stream of Sample', () {
      final subscriber =
          session.declareAdvancedSubscriber('demo/example/adv-sub');
      addTearDown(subscriber.close);
      expect(subscriber.stream, isA<Stream<Sample>>());
      expect(subscriber.stream, isNotNull);
    });

    test('AdvancedSubscriber.close completes without error', () {
      final subscriber =
          session.declareAdvancedSubscriber('demo/example/adv-sub');
      expect(() => subscriber.close(), returnsNormally);
    });

    test('AdvancedSubscriber.close is idempotent', () {
      final subscriber =
          session.declareAdvancedSubscriber('demo/example/adv-sub');
      subscriber.close();
      expect(() => subscriber.close(), returnsNormally);
    });

    test('declareAdvancedSubscriber on closed session throws StateError', () {
      final closedConfig = Config();
      closedConfig.insertJson5('timestamping/enabled', 'true');
      final closedSession = Session.open(config: closedConfig);
      closedSession.close();
      expect(
        () => closedSession.declareAdvancedSubscriber('demo/example/adv-sub'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('AdvancedSubscriber.missEvents is null when miss listener not enabled',
        () {
      final subscriber =
          session.declareAdvancedSubscriber('demo/example/adv-sub');
      addTearDown(subscriber.close);
      expect(subscriber.missEvents, isNull);
    });

    test(
      'declareAdvancedSubscriber with invalid key expression throws ZenohException',
      () {
        expect(
          () => session.declareAdvancedSubscriber(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );
  }); // AdvancedSubscriber group
}
