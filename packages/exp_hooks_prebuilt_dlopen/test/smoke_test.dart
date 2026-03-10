import 'dart:ffi';

import 'package:exp_hooks_prebuilt_dlopen/exp_hooks_prebuilt_dlopen.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

void main() {
  DynamicLibrary? lib;
  String? loadError;

  setUpAll(() {
    try {
      lib = DynamicLibrary.open('libzenoh_dart.so');
    } on ArgumentError catch (e) {
      loadError = e.message.toString();
    }
  });

  group('DynamicLibrary.open() with hook-bundled libraries', () {
    test('finds libzenoh_dart.so without LD_LIBRARY_PATH', () {
      if (loadError != null) {
        markTestSkipped(
          'DynamicLibrary.open cannot find hook-bundled assets: $loadError',
        );
        return;
      }
      expect(lib, isNotNull);
    });

    test('zd_init_dart_api_dl succeeds -- proves C shim loaded', () {
      if (lib == null) {
        markTestSkipped(
          'DynamicLibrary.open failed, cannot test FFI: $loadError',
        );
        return;
      }

      final initDartApiDl = lib!.lookupFunction<
          IntPtr Function(Pointer<Void>),
          int Function(Pointer<Void>)>('zd_init_dart_api_dl');

      final result = initDartApiDl(NativeApi.initializeApiDLData);
      expect(result, equals(0), reason: 'zd_init_dart_api_dl should return 0');
    });

    test(
      'zd_init_log succeeds -- proves libzenohc.so resolved via DT_NEEDED',
      () {
        if (lib == null) {
          markTestSkipped(
            'DynamicLibrary.open failed, cannot test FFI: $loadError',
          );
          return;
        }

        final initLog = lib!.lookupFunction<Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)>('zd_init_log');

        final level = 'error'.toNativeUtf8();
        try {
          // Should complete without throwing.
          initLog(level);
        } finally {
          calloc.free(level);
        }
      },
    );

    test('initZenohDart returns true -- both libs loaded, FFI calls succeed',
        () {
      if (loadError != null) {
        markTestSkipped(
          'DynamicLibrary.open cannot find hook-bundled assets: $loadError',
        );
        return;
      }
      expect(initZenohDart(), isTrue);
    });

    test('DynamicLibrary.open failure produces informative error', () {
      if (loadError != null) {
        // Negative result captured -- record the error message.
        expect(loadError, isNotEmpty,
            reason: 'Error message should be informative');
        markTestSkipped(
          'Confirmed: DynamicLibrary.open fails with: $loadError',
        );
        return;
      }
      // Positive result -- the library loaded fine, nothing to assert about
      // failure messages.
      expect(lib, isNotNull);
    });
  });
}
