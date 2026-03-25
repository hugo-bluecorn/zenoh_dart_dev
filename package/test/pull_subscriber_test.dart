import 'dart:async';

import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('PullSubscriber lifecycle', () {
    late Session session;

    setUpAll(() {
      session = Session.open();
    });

    tearDownAll(() {
      session.close();
    });

    test('declarePullSubscriber returns a PullSubscriber', () {
      final pullSub =
          session.declarePullSubscriber('demo/example/pull');
      expect(pullSub, isA<PullSubscriber>());
      pullSub.close();
    });

    test('PullSubscriber.keyExpr returns declared key expression', () {
      final pullSub =
          session.declarePullSubscriber('demo/example/pull/ke');
      expect(pullSub.keyExpr, equals('demo/example/pull/ke'));
      pullSub.close();
    });

    test('tryRecv returns null when buffer is empty', () {
      final pullSub =
          session.declarePullSubscriber('demo/example/pull/empty');
      addTearDown(pullSub.close);

      final sample = pullSub.tryRecv();
      expect(sample, isNull);
    });

    test('PullSubscriber.close is idempotent', () {
      final pullSub =
          session.declarePullSubscriber('demo/example/pull/idempotent');
      pullSub.close();
      expect(() => pullSub.close(), returnsNormally);
    });

    test('tryRecv on closed PullSubscriber throws StateError', () {
      final pullSub =
          session.declarePullSubscriber('demo/example/pull/closed');
      pullSub.close();
      expect(() => pullSub.tryRecv(), throwsA(isA<StateError>()));
    });
  });

  group('PullSubscriber integration (two sessions, TCP 17480)', () {
    late Session session1;
    late Session session2;

    setUpAll(() async {
      final config1 = Config();
      config1.insertJson5('listen/endpoints', '["tcp/127.0.0.1:17480"]');
      session1 = Session.open(config: config1);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final config2 = Config();
      config2.insertJson5('connect/endpoints', '["tcp/127.0.0.1:17480"]');
      session2 = Session.open(config: config2);

      await Future<void>.delayed(const Duration(seconds: 1));
    });

    tearDownAll(() {
      session1.close();
      session2.close();
    });

    test('basic pull receives sample', () async {
      final pullSub =
          session2.declarePullSubscriber('zenoh/dart/test/pull/basic');
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/pull/basic', 'hello pull');

      // Give time for the sample to arrive in the ring buffer
      await Future<void>.delayed(const Duration(seconds: 1));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      expect(sample!.keyExpr, equals('zenoh/dart/test/pull/basic'));
      expect(sample.payload, equals('hello pull'));
      expect(sample.kind, equals(SampleKind.put));
    });

    test('sample fields correct (payloadBytes, encoding)', () async {
      final publisher = session1.declarePublisher(
        'zenoh/dart/test/pull/enc',
        encoding: Encoding.textPlain,
      );
      addTearDown(publisher.close);

      final pullSub =
          session2.declarePullSubscriber('zenoh/dart/test/pull/enc');
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      publisher.put('encoded data');

      await Future<void>.delayed(const Duration(seconds: 1));

      final sample = pullSub.tryRecv();
      expect(sample, isNotNull);
      expect(sample!.payload, equals('encoded data'));
      expect(sample.payloadBytes, isNotEmpty);
      // Encoding should be present
      expect(sample.encoding, isNotNull);
    });

    test('multiple tryRecv drains buffer', () async {
      final pullSub =
          session2.declarePullSubscriber('zenoh/dart/test/pull/multi');
      addTearDown(pullSub.close);

      await Future<void>.delayed(const Duration(seconds: 1));

      session1.put('zenoh/dart/test/pull/multi', 'msg1');
      session1.put('zenoh/dart/test/pull/multi', 'msg2');
      session1.put('zenoh/dart/test/pull/multi', 'msg3');

      await Future<void>.delayed(const Duration(seconds: 1));

      final samples = <Sample>[];
      for (var i = 0; i < 4; i++) {
        final s = pullSub.tryRecv();
        if (s == null) break;
        samples.add(s);
      }

      expect(samples, hasLength(3));
      expect(samples[0].payload, equals('msg1'));
      expect(samples[1].payload, equals('msg2'));
      expect(samples[2].payload, equals('msg3'));

      // 4th tryRecv should return null
      expect(pullSub.tryRecv(), isNull);
    });
  });
}
