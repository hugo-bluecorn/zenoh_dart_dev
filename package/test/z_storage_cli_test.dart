import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

/// The FVM-resolved Dart executable path.
const _dartExe = '/home/hugo-bluecorn/fvm/versions/stable/bin/dart';

/// Forcefully kills a process, using SIGKILL if SIGTERM doesn't work.
Future<void> forceKill(Process process) async {
  process.kill(ProcessSignal.sigterm);
  try {
    await process.exitCode.timeout(const Duration(seconds: 3));
  } catch (_) {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode
        .timeout(const Duration(seconds: 2))
        .catchError((_) => -1);
  }
}

void main() {
  final packageRoot = Directory.current.path;

  group('z_storage CLI', () {
    setUpAll(() {
      final scriptFile = File('$packageRoot/example/z_storage.dart');
      expect(
        scriptFile.existsSync(),
        isTrue,
        reason: 'example/z_storage.dart must exist',
      );
    });

    test('starts and prints subscriber/queryable messages', () async {
      const endpoint = 'tcp/127.0.0.1:18700';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_storage.dart',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdoutBuf.write);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderrBuf.write);

      // Let it run for 3 seconds then kill
      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);

      final stdout = stdoutBuf.toString();
      expect(stdout, contains('Declaring Subscriber'));
      expect(stdout, contains('Declaring Queryable'));
      expect(stdout, contains('demo/example/**'));
    }, timeout: Timeout(Duration(seconds: 60)));

    test('accepts --key flag', () async {
      const endpoint = 'tcp/127.0.0.1:18701';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_storage.dart',
        '-k',
        'test/storage/**',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdoutBuf.write);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderrBuf.write);

      // Let it run for 3 seconds then kill
      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);

      final stdout = stdoutBuf.toString();
      expect(stdout, contains('test/storage/**'));
    }, timeout: Timeout(Duration(seconds: 60)));

    test('accepts --complete flag', () async {
      const endpoint = 'tcp/127.0.0.1:18702';

      final process = await Process.start(_dartExe, [
        'run',
        'example/z_storage.dart',
        '--complete',
        '-l',
        endpoint,
      ], workingDirectory: packageRoot);

      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdoutBuf.write);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderrBuf.write);

      // Let it run for 3 seconds then kill
      await Future<void>.delayed(const Duration(seconds: 3));
      await forceKill(process);

      final stdout = stdoutBuf.toString();
      final stderr = stderrBuf.toString();

      // Process should have started without crashing
      // Accept either clean startup messages or a clean exit
      expect(
        stdout.contains('Declaring Subscriber') ||
            stdout.contains('Press CTRL-C'),
        isTrue,
        reason:
            'Process should start without error. stdout: $stdout, stderr: $stderr',
      );
    }, timeout: Timeout(Duration(seconds: 60)));
  });
}
