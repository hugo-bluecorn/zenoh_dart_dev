import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bytes.dart';
import 'native_lib.dart';

/// A zenoh serializer for building structured payloads.
///
/// Wraps `ze_owned_serializer_t`. Call [finish] to produce a [ZBytes],
/// or [dispose] to release native resources without finishing.
class ZSerializer {
  final Pointer<Void> _ptr;
  bool _finished = false;
  bool _disposed = false;

  /// Creates an empty serializer.
  ZSerializer() : _ptr = _create();

  static Pointer<Void> _create() {
    final size = bindings.zd_serializer_sizeof();
    final Pointer<Void> ptr = calloc.allocate(size);
    bindings.zd_serializer_empty(ptr.cast());
    return ptr;
  }

  void _checkState() {
    if (_disposed) throw StateError('ZSerializer has been disposed');
    if (_finished) throw StateError('ZSerializer has been finished');
  }

  /// Finishes the serializer and returns the produced [ZBytes].
  ///
  /// The serializer is consumed by this call. After finishing,
  /// no further operations are allowed.
  ///
  /// Throws [StateError] if already finished or disposed.
  ZBytes finish() {
    _checkState();
    _finished = true;
    final Pointer<Void> bytesPtr =
        calloc.allocate(bindings.zd_bytes_sizeof());
    bindings.zd_serializer_finish(_ptr.cast(), bytesPtr.cast());
    calloc.free(_ptr);
    return ZBytes.fromNative(bytesPtr);
  }

  /// Releases native resources held by this serializer.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  /// Safe to call after [finish] -- no-op since resources were
  /// already transferred.
  void dispose() {
    if (_disposed) return;
    if (_finished) {
      _disposed = true;
      return;
    }
    _disposed = true;
    bindings.zd_serializer_drop(_ptr.cast());
    calloc.free(_ptr);
  }
}
