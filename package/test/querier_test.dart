// Querier lifecycle and get tests
import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('Querier lifecycle', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declareQuerier returns a Querier instance', () {
      final querier = session.declareQuerier('demo/example/querier');
      expect(querier, isA<Querier>());
      querier.close();
    });

    test('Querier.keyExpr returns declared key expression', () {
      final querier = session.declareQuerier('demo/example/querier');
      expect(querier.keyExpr, equals('demo/example/querier'));
      querier.close();
    });

    test('Querier.close completes without error', () {
      final querier = session.declareQuerier('demo/example/querier');
      expect(() => querier.close(), returnsNormally);
    });

    test('Querier.close is idempotent', () {
      final querier = session.declareQuerier('demo/example/querier');
      querier.close();
      expect(() => querier.close(), returnsNormally);
    });

    test('declareQuerier on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.declareQuerier('demo/example/querier'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('declareQuerier with invalid key expression throws ZenohException',
        () {
      expect(
        () => session.declareQuerier(''),
        throwsA(isA<ZenohException>()),
      );
    });

    test('declareQuerier with non-default options succeeds', () {
      final querier = session.declareQuerier(
        'demo/example/querier-opts',
        target: QueryTarget.all,
        consolidation: ConsolidationMode.none,
        timeout: const Duration(seconds: 5),
      );
      expect(querier, isA<Querier>());
      expect(querier.keyExpr, equals('demo/example/querier-opts'));
      querier.close();
    });
  });

  group('Basic Querier Get (TCP 17490)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17490"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17490"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test('basic querier get receives reply from queryable', () async {
      final queryable =
          sessionA.declareQueryable('zenoh/dart/test/qr/basic');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/qr/basic', 'hello from queryable');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/basic',
        timeout: Duration(seconds: 5),
      );
      addTearDown(querier.close);

      final replies = await querier.get().toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payload, equals('hello from queryable'));
    });

    test('querier get with parameters passes parameters to queryable',
        () async {
      final receivedParams = Completer<String>();
      final queryable =
          sessionA.declareQueryable('zenoh/dart/test/qr/params');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedParams.complete(query.parameters);
        query.reply('zenoh/dart/test/qr/params', 'ok');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/params',
        timeout: Duration(seconds: 5),
      );
      addTearDown(querier.close);

      await querier.get(parameters: 'key=value').toList();

      final params =
          await receivedParams.future.timeout(Duration(seconds: 5));
      expect(params, equals('key=value'));
    });

    test('querier get timeout with no queryable returns empty stream',
        () async {
      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/timeout',
        timeout: Duration(seconds: 1),
      );
      addTearDown(querier.close);

      final replies = await querier
          .get()
          .toList()
          .timeout(Duration(seconds: 5));

      expect(replies, isEmpty);
    });

    test('querier repeated gets return correct replies each time', () async {
      final queryable =
          sessionA.declareQueryable('zenoh/dart/test/qr/repeat');
      addTearDown(queryable.close);

      var queryCount = 0;
      queryable.stream.listen((query) {
        queryCount++;
        query.reply('zenoh/dart/test/qr/repeat', 'reply-$queryCount');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/repeat',
        timeout: Duration(seconds: 5),
      );
      addTearDown(querier.close);

      for (var i = 0; i < 3; i++) {
        final replies = await querier.get().toList();
        expect(replies, hasLength(1));
        expect(replies.first.isOk, isTrue);
      }
    });

    test('querier get after close throws StateError', () {
      final querier = sessionB.declareQuerier(
        'zenoh/dart/test/qr/closed',
        timeout: Duration(seconds: 5),
      );
      querier.close();

      expect(
        () => querier.get(),
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
