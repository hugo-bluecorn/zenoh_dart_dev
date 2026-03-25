import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('Get/Queryable integration (TCP 17470)', () {
    late Session sessionA;
    late Session sessionB;

    setUp(() async {
      sessionA = Session.open(
        config: Config()
          ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:17470"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
      sessionB = Session.open(
        config: Config()
          ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:17470"]'),
      );
      await Future.delayed(Duration(milliseconds: 500));
    });

    tearDown(() async {
      sessionB.close();
      sessionA.close();
    });

    test('basic get receives reply from queryable', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/basic');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q/basic', 'hello from queryable');
        query.dispose();
      });

      // Small delay to let queryable register
      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/basic').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payload, equals('hello from queryable'));
    });

    test('get with parameters', () async {
      final receivedParams = Completer<String>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/params');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedParams.complete(query.parameters);
        query.reply('zenoh/dart/test/q/params', 'ok');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB
          .get('zenoh/dart/test/q/params', parameters: 'key=value')
          .toList();

      final params = await receivedParams.future.timeout(Duration(seconds: 5));
      expect(params, equals('key=value'));
    });

    test('get with payload', () async {
      final receivedPayload = Completer<Uint8List>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/payload');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        if (query.payloadBytes != null) {
          receivedPayload.complete(query.payloadBytes!);
        } else {
          receivedPayload.completeError('No payload received');
        }
        query.reply('zenoh/dart/test/q/payload', 'ok');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB
          .get(
            'zenoh/dart/test/q/payload',
            payload: Uint8List.fromList([1, 2, 3]),
          )
          .toList();

      final payload = await receivedPayload.future.timeout(
        Duration(seconds: 5),
      );
      expect(payload, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('empty parameters', () async {
      final receivedParams = Completer<String>();
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/noparams');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        receivedParams.complete(query.parameters);
        query.reply('zenoh/dart/test/q/noparams', 'ok');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB.get('zenoh/dart/test/q/noparams').toList();

      final params = await receivedParams.future.timeout(Duration(seconds: 5));
      expect(params, isEmpty);
    });

    test('get timeout with no queryable', () async {
      final replies = await sessionB
          .get('zenoh/dart/test/q/nonexistent', timeout: Duration(seconds: 1))
          .toList();

      expect(replies, isEmpty);
    });

    test('query dispose without reply', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/noreply');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        // Dispose without replying
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/noreply', timeout: Duration(seconds: 2))
          .toList();

      expect(replies, isEmpty);
    });

    test('query dispose after reply is idempotent', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q/idempotent',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q/idempotent', 'ok');
        query.dispose();
        // Second dispose should be a no-op
        expect(() => query.dispose(), returnsNormally);
      });

      await Future.delayed(Duration(milliseconds: 200));

      await sessionB.get('zenoh/dart/test/q/idempotent').toList();
    });

    test('reply keyExpr matches query keyExpr', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/keycheck');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q/keycheck', 'response');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/keycheck').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.keyExpr, equals('zenoh/dart/test/q/keycheck'));
    });

    test('Session.get() on closed session throws StateError', () {
      final closedSession = Session.open();
      closedSession.close();
      expect(
        () => closedSession.get('zenoh/dart/test/q/closed'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    });

    test('queryable close stops receiving queries', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/closedq');
      // Close queryable immediately
      queryable.close();

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/closedq', timeout: Duration(seconds: 1))
          .toList();

      expect(replies, isEmpty);
    });

    test('Query.reply with string value', () async {
      final queryable = sessionA.declareQueryable('zenoh/dart/test/q/strreply');
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.reply('zenoh/dart/test/q/strreply', 'hello string reply');
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB.get('zenoh/dart/test/q/strreply').toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(replies.first.ok.payload, equals('hello string reply'));
    });

    test('Query.replyBytes with raw bytes', () async {
      final queryable = sessionA.declareQueryable(
        'zenoh/dart/test/q/bytereply',
      );
      addTearDown(queryable.close);

      queryable.stream.listen((query) {
        query.replyBytes(
          'zenoh/dart/test/q/bytereply',
          Uint8List.fromList([0xDE, 0xAD]),
        );
        query.dispose();
      });

      await Future.delayed(Duration(milliseconds: 200));

      final replies = await sessionB
          .get('zenoh/dart/test/q/bytereply')
          .toList();

      expect(replies, hasLength(1));
      expect(replies.first.isOk, isTrue);
      expect(
        replies.first.ok.payloadBytes,
        equals(Uint8List.fromList([0xDE, 0xAD])),
      );
    });
  });
}
