// Liveliness token and subscriber tests (Phase 11)
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

  group('Liveliness Subscriber (TCP 17500)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17500"]'),
      );
      await Future.delayed(const Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17500"]'),
      );
      await Future.delayed(const Duration(milliseconds: 500));
    });

    tearDown(() {
      sessionB.close();
      sessionA.close();
    });

    test('declareLivelinessSubscriber returns a Subscriber', () {
      final sub = sessionB.declareLivelinessSubscriber(
        'zenoh/liveliness/test/**',
      );
      expect(sub, isA<Subscriber>());
      sub.close();
    });

    test('Subscriber receives PUT when token is declared', () async {
      final sub = sessionB.declareLivelinessSubscriber(
        'zenoh/liveliness/test/*',
      );
      addTearDown(sub.close);
      await Future.delayed(const Duration(milliseconds: 500));

      final token = sessionA.declareLivelinessToken(
        'zenoh/liveliness/test/1',
      );
      addTearDown(token.close);

      final sample = await sub.stream.first.timeout(
        const Duration(seconds: 5),
      );
      expect(sample.kind, equals(SampleKind.put));
      expect(sample.keyExpr, contains('zenoh/liveliness/test/1'));
    });

    test('Subscriber receives DELETE when token is closed', () async {
      final sub = sessionB.declareLivelinessSubscriber(
        'zenoh/liveliness/test/*',
      );
      addTearDown(sub.close);
      await Future.delayed(const Duration(milliseconds: 500));

      final token = sessionA.declareLivelinessToken(
        'zenoh/liveliness/test/1',
      );

      // Wait for the PUT notification first
      await sub.stream.first.timeout(const Duration(seconds: 5));

      // Close the token -- should trigger DELETE
      token.close();

      final deleteSample = await sub.stream.first.timeout(
        const Duration(seconds: 5),
      );
      expect(deleteSample.kind, equals(SampleKind.delete));
      expect(deleteSample.keyExpr, contains('zenoh/liveliness/test/1'));
    });

    test('Multiple tokens produce multiple PUT and individual DELETE',
        () async {
      final sub = sessionB.declareLivelinessSubscriber(
        'zenoh/liveliness/test/*',
      );
      addTearDown(sub.close);
      await Future.delayed(const Duration(milliseconds: 500));

      final token1 = sessionA.declareLivelinessToken(
        'zenoh/liveliness/test/1',
      );
      final token2 = sessionA.declareLivelinessToken(
        'zenoh/liveliness/test/2',
      );

      // Collect 2 PUT samples
      final puts = await sub.stream
          .where((s) => s.kind == SampleKind.put)
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 5));
      expect(puts, hasLength(2));

      // Close token1 -- expect DELETE for token1
      token1.close();
      final del1 = await sub.stream.first.timeout(
        const Duration(seconds: 5),
      );
      expect(del1.kind, equals(SampleKind.delete));
      expect(del1.keyExpr, contains('zenoh/liveliness/test/1'));

      // Close token2 -- expect DELETE for token2
      token2.close();
      final del2 = await sub.stream.first.timeout(
        const Duration(seconds: 5),
      );
      expect(del2.kind, equals(SampleKind.delete));
      expect(del2.keyExpr, contains('zenoh/liveliness/test/2'));
    });

    test('declareLivelinessSubscriber on closed session throws StateError',
        () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.declareLivelinessSubscriber(
          'zenoh/liveliness/test/**',
        ),
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
        'declareLivelinessSubscriber with invalid key expression throws '
        'ZenohException', () {
      expect(
        () => sessionA.declareLivelinessSubscriber(''),
        throwsA(isA<ZenohException>()),
      );
    });

    test('Liveliness subscriber close is idempotent', () {
      final sub = sessionA.declareLivelinessSubscriber(
        'zenoh/liveliness/test/**',
      );
      sub.close();
      expect(() => sub.close(), returnsNormally);
    });
  });
}
