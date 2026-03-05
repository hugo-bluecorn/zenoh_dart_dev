import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final packageRoot = Directory.current.path;
  final repoRoot = '$packageRoot/../..';
  final ldLibraryPath =
      '$repoRoot/extern/zenoh-c/target/release:$repoRoot/build';

  Map<String, String> env() => {
        ...Platform.environment,
        'LD_LIBRARY_PATH': ldLibraryPath,
      };

  group('z_sub CLI', () {
    test('runs and prints subscriber declaration', () async {
      final process = await Process.start(
        'fvm',
        ['dart', 'run', 'bin/z_sub.dart'],
        workingDirectory: packageRoot,
        environment: env(),
      );

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      // Let it run for 3 seconds, then kill it
      await Future<void>.delayed(const Duration(seconds: 3));
      process.kill(ProcessSignal.sigterm);

      final exitCode = await process.exitCode
          .timeout(const Duration(seconds: 5));

      await subscription.cancel();

      // Process killed by signal may have various exit codes
      // The important thing is it printed the declaration message
      expect(stdout.toString(), contains('Declaring Subscriber'));
      expect(
        stdout.toString(),
        contains('demo/example/**'),
      );
    });

    test('receives a sample from z_put', () async {
      // Start z_sub listening on a specific key
      final subProcess = await Process.start(
        'fvm',
        ['dart', 'run', 'bin/z_sub.dart', '-k', 'demo/cli/test'],
        workingDirectory: packageRoot,
        environment: env(),
      );

      final subStdout = StringBuffer();
      final subSubscription = subProcess.stdout
          .transform(const SystemEncoding().decoder)
          .listen(subStdout.write);

      try {
        // Wait for subscriber to be ready
        await Future<void>.delayed(const Duration(seconds: 3));

        // Run z_put to send a sample
        final putResult = await Process.run(
          'fvm',
          [
            'dart', 'run', 'bin/z_put.dart',
            '-k', 'demo/cli/test',
            '-p', 'from-put',
          ],
          workingDirectory: packageRoot,
          environment: env(),
        ).timeout(const Duration(seconds: 30));
        expect(putResult.exitCode, equals(0),
            reason: 'z_put stderr: ${putResult.stderr}');

        // Wait for the sample to arrive
        await Future<void>.delayed(const Duration(seconds: 3));

        final output = subStdout.toString();
        expect(output, contains('Received PUT'));
        expect(output, contains('from-put'));
      } finally {
        subProcess.kill(ProcessSignal.sigterm);
        await subProcess.exitCode
            .timeout(const Duration(seconds: 5))
            .catchError((_) => -1);
        await subSubscription.cancel();
      }
    });

    test('accepts --key flag', () async {
      final process = await Process.start(
        'fvm',
        ['dart', 'run', 'bin/z_sub.dart', '--key', 'demo/custom/**'],
        workingDirectory: packageRoot,
        environment: env(),
      );

      final stdout = StringBuffer();
      final subscription = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);

      await Future<void>.delayed(const Duration(seconds: 3));
      process.kill(ProcessSignal.sigterm);

      await process.exitCode
          .timeout(const Duration(seconds: 5))
          .catchError((_) => -1);
      await subscription.cancel();

      expect(stdout.toString(), contains('demo/custom/**'));
    });

    test('with empty key expression fails', () async {
      final result = await Process.run(
        'fvm',
        ['dart', 'run', 'bin/z_sub.dart', '--key', ''],
        workingDirectory: packageRoot,
        environment: env(),
      ).timeout(const Duration(seconds: 30));

      expect(result.exitCode, isNot(0));
    });
  });
}
