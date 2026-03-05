import 'package:test/test.dart';
import 'package:zenoh/src/exceptions.dart';
import 'package:zenoh/src/sample.dart';
import 'package:zenoh/src/session.dart';
import 'package:zenoh/src/subscriber.dart';

void main() {
  group('SampleKind', () {
    test('has put and delete values that are distinct', () {
      expect(SampleKind.put, isNotNull);
      expect(SampleKind.delete, isNotNull);
      expect(SampleKind.put, isNot(equals(SampleKind.delete)));
    });
  });

  group('Sample', () {
    test('roundtrips all fields including nullable attachment', () {
      final sample = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        kind: SampleKind.put,
        attachment: 'metadata',
      );
      expect(sample.keyExpr, equals('demo/test'));
      expect(sample.payload, equals('hello'));
      expect(sample.kind, equals(SampleKind.put));
      expect(sample.attachment, equals('metadata'));

      final sampleNoAttachment = Sample(
        keyExpr: 'demo/test',
        payload: 'hello',
        kind: SampleKind.put,
      );
      expect(sampleNoAttachment.attachment, isNull);
    });
  });

  group('Subscriber lifecycle', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declareSubscriber returns a Subscriber on valid key expression', () {
      final subscriber = session.declareSubscriber('demo/example/test');
      expect(subscriber, isA<Subscriber>());
      subscriber.close();
    });

    test('Subscriber.close completes without error', () {
      final subscriber = session.declareSubscriber('demo/example/test');
      expect(() => subscriber.close(), returnsNormally);
    });

    test('Subscriber.close is idempotent (double-close safe)', () {
      final subscriber = session.declareSubscriber('demo/example/test');
      subscriber.close();
      expect(() => subscriber.close(), returnsNormally);
    });

    test('declareSubscriber on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.declareSubscriber('demo/example/test'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('declareSubscriber with invalid key expression throws ZenohException',
        () {
      expect(
        () => session.declareSubscriber(''),
        throwsA(isA<ZenohException>()),
      );
    });
  });
}
