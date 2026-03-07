import 'dart:io';

import 'package:test/test.dart';

void main() {
  // Get the package root (where pubspec.yaml lives)
  // Tests run from packages/zenoh/
  final packageRoot = Directory.current.path;
  final repoRoot = '$packageRoot/../..';
  final ldLibraryPath =
      '$repoRoot/extern/zenoh-c/target/release:$repoRoot/build';
  final dartBin = '/home/hugo-bluecorn/fvm/versions/stable/bin/dart';

  group('z_scout CLI', () {
    Future<ProcessResult> runZScout([List<String> args = const []]) async {
      return Process.run(
        'fvm',
        ['dart', 'run', 'example/z_scout.dart', ...args],
        workingDirectory: packageRoot,
        environment: {
          ...Platform.environment,
          'LD_LIBRARY_PATH': ldLibraryPath,
        },
      ).timeout(const Duration(seconds: 15));
    }

    test('runs with default arguments', () async {
      final result = await runZScout();
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      // Must contain either 'Hello' or 'Did not find any zenoh process'
      expect(
        stdout.contains('Hello') ||
            stdout.contains('Did not find any zenoh process'),
        isTrue,
        reason: 'stdout should contain Hello or no-process message: $stdout',
      );
    });

    test('accepts connect and listen flags', () async {
      final result = await runZScout(['-e', 'tcp/127.0.0.1:7447']);
      // Process completes without argument parse error
      final stderr = result.stderr as String;
      expect(stderr, isNot(contains('Could not find an option named')));
      expect(stderr, isNot(contains('FormatException')));
    });

    test('discovers a listening peer', () async {
      // Start a z_sub process listening on TCP port 18561
      final subProcess = await Process.start(
        dartBin,
        ['run', 'example/z_sub.dart', '-l', 'tcp/127.0.0.1:18561'],
        workingDirectory: packageRoot,
        environment: {
          ...Platform.environment,
          'LD_LIBRARY_PATH': ldLibraryPath,
        },
      );

      addTearDown(() {
        subProcess.kill(ProcessSignal.sigterm);
      });

      // Wait for z_sub to bind and be discoverable
      await Future<void>.delayed(const Duration(seconds: 3));

      final result = await runZScout();
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;

      // Should discover at least one Hello with zid, whatami, and locators
      expect(stdout, contains('Hello'));
      expect(stdout, matches(RegExp(r'zid: [0-9a-f]+')));
      expect(stdout, matches(RegExp(r'whatami: (router|peer|client)')));
      expect(stdout, contains('locators:'));

      subProcess.kill(ProcessSignal.sigterm);
    });

    test('handles no discoverable entities gracefully', () async {
      // With default config and short timeout, may or may not find entities
      // (depends on network). Either way, exit code should be 0.
      final result = await runZScout();
      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      // Should contain Scouting... at minimum
      expect(stdout, contains('Scouting...'));
    });
  });
}
