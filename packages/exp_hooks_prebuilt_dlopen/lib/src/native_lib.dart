import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Native function typedefs for zenoh_dart C shim.
typedef ZdInitDartApiDlNative = IntPtr Function(Pointer<Void>);
typedef ZdInitDartApiDl = int Function(Pointer<Void>);
typedef ZdInitLogNative = Void Function(Pointer<Utf8>);
typedef ZdInitLog = void Function(Pointer<Utf8>);

/// Initializes the zenoh_dart native library via [DynamicLibrary.open].
///
/// Loads `libzenoh_dart.so`, calls `zd_init_dart_api_dl` to initialize the
/// Dart API DL, and `zd_init_log` with the 'error' log level.
///
/// Returns `true` on success. Throws on failure to load or initialize.
bool initZenohDart() {
  final lib = DynamicLibrary.open('libzenoh_dart.so');

  final initDartApiDl =
      lib.lookupFunction<ZdInitDartApiDlNative, ZdInitDartApiDl>(
    'zd_init_dart_api_dl',
  );
  final result = initDartApiDl(NativeApi.initializeApiDLData);
  if (result != 0) {
    throw StateError('Failed to initialize Dart API DL (code: $result)');
  }

  final initLog = lib.lookupFunction<ZdInitLogNative, ZdInitLog>(
    'zd_init_log',
  );
  final level = 'error'.toNativeUtf8();
  try {
    initLog(level);
  } finally {
    calloc.free(level);
  }

  return true;
}
