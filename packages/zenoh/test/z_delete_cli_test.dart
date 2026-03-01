import 'dart:io';

import 'package:test/test.dart';

void main() {
  final projectRoot = Directory.current.path.endsWith('packages/zenoh')
      ? Directory.current.path
      : '${Directory.current.path}/packages/zenoh';

  // Resolve to absolute monorepo root for LD_LIBRARY_PATH
  final monorepoRoot = Directory(projectRoot).parent.parent.path;
  final ldLibraryPath =
      '$monorepoRoot/extern/zenoh-c/target/release:$monorepoRoot/build';

  /// Runs the z_delete CLI with [args] and returns the process result.
  Future<ProcessResult> runZDelete([List<String> args = const []]) {
    return Process.run(
      'fvm',
      ['dart', 'run', 'bin/z_delete.dart', ...args],
      workingDirectory: projectRoot,
      environment: {'LD_LIBRARY_PATH': ldLibraryPath},
    ).timeout(const Duration(seconds: 30));
  }

  group('z_delete CLI', () {
    test('runs with default arguments and prints confirmation', () async {
      final result = await runZDelete();

      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      expect(stdout, contains('Deleting'));
      expect(stdout, contains('demo/example/zenoh-dart-put'));
    });

    test('accepts custom key argument', () async {
      final result = await runZDelete(['-k', 'demo/custom/key']);

      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      expect(stdout, contains('demo/custom/key'));
    });

    test('--help shows usage information', () async {
      final result = await runZDelete(['--help']);

      expect(result.exitCode, equals(0), reason: 'stderr: ${result.stderr}');
      final stdout = result.stdout as String;
      expect(stdout, contains('-k'));
    });
  });
}
