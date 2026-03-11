import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Known issue: Inter-process TCP connections crash the listener process.
///
/// The crash occurs on a tokio worker thread (pc=0, si_addr=nil) when a
/// remote Dart process connects via TCP. The `zd_promote_zenohc_global()`
/// function successfully promotes libzenohc.so symbols to RTLD_GLOBAL scope
/// (verified via DynamicLibrary.process().lookup()), but the tokio runtime's
/// waker vtable dispatch still fails.
///
/// Root cause: The tokio runtime is initialized when the session opens.
/// At that point, libzenohc.so is loaded with RTLD_LOCAL. The waker vtable
/// pointers are set up using the RTLD_LOCAL symbol addresses. Promoting to
/// RTLD_GLOBAL after initialization does not retroactively fix existing
/// vtable pointers. The crash triggers when a remote TCP connection causes
/// tokio to dispatch on a worker thread using the stale vtable.
///
/// This affects ALL loading mechanisms: @Native, LD_LIBRARY_PATH, and
/// LD_PRELOAD with both libraries all produce the same crash.
///
/// Blocked on: zenoh-c or Dart VM fix for dlopen-loaded tokio runtimes.
const _interprocessSkipReason =
    'Inter-process TCP connection crashes listener — '
    'tokio waker vtable dispatch fails when libzenohc.so loaded via dlopen. '
    'See docs/reviews/rtld-local-crash-investigation.md';

/// Starts the interprocess_connect helper in the given mode.
///
/// Returns the [Process] after the ready signal has been received.
Future<Process> _startHelper({
  required String mode,
  required String port,
  int duration = 5,
  Map<String, String>? environment,
}) async {
  final helper = await Process.start(
    'fvm',
    [
      'dart',
      'run',
      'test/helpers/interprocess_connect.dart',
      mode,
      '--port',
      port,
      '--duration',
      '$duration',
    ],
    workingDirectory: '.',
    environment: environment,
  );

  final readySignal = mode == '--listen' ? 'LISTENING' : 'CONNECTED';
  final stdoutLines = helper.stdout
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter());
  await stdoutLines
      .firstWhere((line) => line.contains(readySignal))
      .timeout(Duration(seconds: 15));

  return helper;
}

void main() {
  group('Inter-process connection', () {
    test(
      'two Dart processes connect via TCP without crashing',
      () async {
        const port = '19001';

        final listener =
            await _startHelper(mode: '--listen', port: port, duration: 8);
        final connector =
            await _startHelper(mode: '--connect', port: port, duration: 3);

        final connectorExit =
            await connector.exitCode.timeout(Duration(seconds: 15));
        expect(connectorExit, equals(0),
            reason: 'Connector process should exit cleanly');

        final listenerExit =
            await listener.exitCode.timeout(Duration(seconds: 20));
        expect(listenerExit, equals(0),
            reason: 'Listener process should exit cleanly');
      },
      skip: _interprocessSkipReason,
    );

    test(
      'both processes exit with code 0',
      () async {
        const port = '19002';

        final listener =
            await _startHelper(mode: '--listen', port: port, duration: 8);
        final connector =
            await _startHelper(mode: '--connect', port: port, duration: 3);

        final connectorExit =
            await connector.exitCode.timeout(Duration(seconds: 15));
        final listenerExit =
            await listener.exitCode.timeout(Duration(seconds: 20));

        expect(connectorExit, equals(0),
            reason: 'Connector should exit cleanly (no SIGSEGV/SIGBUS)');
        expect(listenerExit, equals(0),
            reason: 'Listener should exit cleanly (no SIGSEGV/SIGBUS)');
      },
      skip: _interprocessSkipReason,
    );

    test(
      'connection works without LD_LIBRARY_PATH or LD_PRELOAD',
      () async {
        const port = '19003';

        final env = Map<String, String>.from(Platform.environment);
        env.remove('LD_LIBRARY_PATH');
        env.remove('LD_PRELOAD');

        final listener = await _startHelper(
          mode: '--listen',
          port: port,
          duration: 8,
          environment: env,
        );
        final connector = await _startHelper(
          mode: '--connect',
          port: port,
          duration: 3,
          environment: env,
        );

        final connectorExit =
            await connector.exitCode.timeout(Duration(seconds: 15));
        final listenerExit =
            await listener.exitCode.timeout(Duration(seconds: 20));

        expect(connectorExit, equals(0));
        expect(listenerExit, equals(0));
      },
      skip: _interprocessSkipReason,
    );

    test('standalone helper process exits cleanly without connection',
        () async {
      const port = '19004';

      final listener =
          await _startHelper(mode: '--listen', port: port, duration: 2);

      // No connector — just verify the listener exits on its own
      final listenerExit =
          await listener.exitCode.timeout(Duration(seconds: 15));
      expect(listenerExit, equals(0),
          reason: 'Standalone listener should exit cleanly');
    });
  });
}
