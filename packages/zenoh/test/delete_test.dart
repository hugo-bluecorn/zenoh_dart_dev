import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('Session.delete', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('delete valid key expression succeeds', () {
      // Given: an open Session
      // When: session.delete is called with a valid key expression
      // Then: the call completes without throwing any exception
      expect(
        () => session.delete('demo/example/test'),
        returnsNormally,
      );
    });

    test('delete hierarchical key expression succeeds', () {
      // Given: an open Session
      // When: session.delete is called with a hierarchical key expression
      // Then: the call completes without throwing any exception
      expect(
        () => session.delete('demo/example/zenoh-dart/test'),
        returnsNormally,
      );
    });

    test('delete with invalid key expression throws ZenohException', () {
      // Given: an open Session
      // When: session.delete is called with an empty string (invalid)
      // Then: a ZenohException is thrown
      expect(
        () => session.delete(''),
        throwsA(isA<ZenohException>()),
      );
    });

    test('delete on closed session throws StateError', () {
      // Given: a Session that has been closed
      final closedSession = Session.open();
      closedSession.close();

      // When: session.delete is called on the closed session
      // Then: a StateError is thrown with a message containing 'closed'
      expect(
        () => closedSession.delete('demo/example/test'),
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
