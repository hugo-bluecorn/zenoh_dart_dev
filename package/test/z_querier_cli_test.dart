import 'dart:io';

import 'package:test/test.dart';

void main() {
  final packageRoot = Directory.current.path;

  group('z_querier CLI', () {
    Future<ProcessResult> runZQuerier([List<String> args = const []]) async {
      return Process.run('fvm', [
        'dart',
        'run',
        'example/z_querier.dart',
        ...args,
      ], workingDirectory: packageRoot).timeout(const Duration(seconds: 30));
    }

    test('runs with default arguments and prints declaring message', () async {
      final result = await runZQuerier(['--timeout', '2000']);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('Declaring Querier'));
      expect(result.stdout as String, contains('demo/example/**'));
    });

    test('accepts --selector flag', () async {
      final result = await runZQuerier([
        '--selector',
        'demo/custom/**',
        '--timeout',
        '2000',
      ]);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('demo/custom/**'));
    });

    test('accepts short flags', () async {
      final result =
          await runZQuerier(['-s', 'demo/short/**', '-o', '2000']);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('demo/short/**'));
    });

    test('accepts --target flag', () async {
      final result = await runZQuerier(['-t', 'ALL', '-o', '2000']);
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      expect(result.stdout as String, contains('Querying'));
    });
  });
}
