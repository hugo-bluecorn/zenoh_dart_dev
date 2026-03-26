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
}
