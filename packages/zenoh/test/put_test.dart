import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('Session.put', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('put string on valid key expression succeeds', () {
      // Given: an open Session
      // When: session.put is called with a valid key and string value
      // Then: the call completes without throwing any exception
      expect(
        () => session.put('demo/example/test', 'Hello from Dart!'),
        returnsNormally,
      );
    });

    test('put empty string payload succeeds', () {
      // Given: an open Session
      // When: session.put is called with an empty string value
      // Then: the call completes without throwing any exception
      expect(
        () => session.put('demo/example/test', ''),
        returnsNormally,
      );
    });

    test('put with unicode payload succeeds', () {
      // Given: an open Session
      // When: session.put is called with a unicode string value
      // Then: the call completes without throwing any exception
      expect(
        () => session.put('demo/example/test', 'Hola Mundo!'),
        returnsNormally,
      );
    });

    test('put with invalid key expression throws ZenohException', () {
      // Given: an open Session
      // When: session.put is called with an empty key expression
      // Then: a ZenohException is thrown
      expect(
        () => session.put('', 'value'),
        throwsA(isA<ZenohException>()),
      );
    });

    test('put on closed session throws StateError', () {
      // Given: a Session that has been closed
      final closedSession = Session.open();
      closedSession.close();

      // When: session.put is called on the closed session
      // Then: a StateError is thrown with a message containing 'closed'
      expect(
        () => closedSession.put('demo/example/test', 'value'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });
  });
}
