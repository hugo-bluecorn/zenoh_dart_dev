import 'dart:io';

import 'package:exp_hooks_prebuilt_dlopen/exp_hooks_prebuilt_dlopen.dart';
import 'package:test/test.dart';

void main() {
  group('package scaffold', () {
    test('barrel file exports initZenohDart function', () {
      // Verify the function exists and is callable
      expect(initZenohDart, isA<bool Function()>());
    });

    test('package resolves in workspace', () {
      // Verify package_config.json exists after pub get
      final packageConfigPath =
          '${Directory.current.path}/.dart_tool/package_config.json';
      expect(File(packageConfigPath).existsSync(), isTrue);
    });
  });
}
