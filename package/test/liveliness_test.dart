// Liveliness token lifecycle tests (Phase 11, Slice 1)
import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('LivelinessToken lifecycle', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declareLivelinessToken returns a LivelinessToken', () {
      final token =
          session.declareLivelinessToken('demo/example/liveliness-test');
      expect(token, isA<LivelinessToken>());
      token.close();
    });

    test('LivelinessToken.keyExpr returns declared key expression', () {
      final token =
          session.declareLivelinessToken('demo/example/liveliness-test');
      expect(token.keyExpr, equals('demo/example/liveliness-test'));
      token.close();
    });

    test('LivelinessToken.close completes without error', () {
      final token =
          session.declareLivelinessToken('demo/example/liveliness-test');
      expect(() => token.close(), returnsNormally);
    });

    test('LivelinessToken.close is idempotent', () {
      final token =
          session.declareLivelinessToken('demo/example/liveliness-test');
      token.close();
      expect(() => token.close(), returnsNormally);
    });

    test('declareLivelinessToken on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession
            .declareLivelinessToken('demo/example/liveliness-test'),
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
      'declareLivelinessToken with invalid key expression throws '
      'ZenohException',
      () {
        expect(
          () => session.declareLivelinessToken(''),
          throwsA(isA<ZenohException>()),
        );
      },
    );
  });
}
