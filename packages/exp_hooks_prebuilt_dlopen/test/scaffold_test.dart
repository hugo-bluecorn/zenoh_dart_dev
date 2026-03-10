import 'dart:convert';
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
      // The workspace root package_config.json must contain our package.
      // Walk up from the package dir to find the workspace root .dart_tool/.
      final workspaceRoot =
          Directory.current.path.contains('packages/')
              ? Directory.current.path.split('packages/').first
              : Directory.current.path;
      final packageConfigFile =
          File('$workspaceRoot/.dart_tool/package_config.json');
      // If we can't find it relative to cwd, try the monorepo root directly.
      final configFile = packageConfigFile.existsSync()
          ? packageConfigFile
          : File(
              '${Platform.environment['MONOREPO_ROOT'] ?? workspaceRoot}'
              '/.dart_tool/package_config.json',
            );
      expect(configFile.existsSync(), isTrue,
          reason: 'Workspace package_config.json should exist');

      final content = jsonDecode(configFile.readAsStringSync())
          as Map<String, dynamic>;
      final packages = content['packages'] as List<dynamic>;
      final hasPackage = packages.any(
        (p) => (p as Map<String, dynamic>)['name'] == 'exp_hooks_prebuilt_dlopen',
      );
      expect(hasPackage, isTrue,
          reason: 'exp_hooks_prebuilt_dlopen should be in package_config.json');
    });
  });
}
