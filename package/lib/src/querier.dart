import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'consolidation_mode.dart';
import 'exceptions.dart';
import 'native_lib.dart';
import 'query_target.dart';

/// A zenoh querier for efficiently sending multiple queries on a single
/// key expression with pre-configured options.
///
/// Wraps `z_owned_querier_t`. Call [close] when done to undeclare the
/// querier and release native resources.
class Querier {
  final Pointer<Void> _ptr;
  final String _keyExpr;
  bool _closed = false;

  Querier._(this._ptr, this._keyExpr);

  /// Creates a querier on the given session and key expression.
  ///
  /// This is called internally by [Session.declareQuerier].
  static Querier declare(
    Pointer<Void> loanedSession,
    String keyExpr, {
    QueryTarget target = QueryTarget.bestMatching,
    ConsolidationMode consolidation = ConsolidationMode.auto,
    Duration? timeout,
  }) {
    final size = bindings.zd_querier_sizeof();
    final Pointer<Void> ptr = calloc.allocate(size);

    final keyExprNative = keyExpr.toNativeUtf8();

    try {
      final rc = bindings.zd_declare_querier(
        ptr.cast(),
        loanedSession.cast(),
        keyExprNative.cast(),
        target.index,
        consolidation.value,
        timeout != null ? timeout.inMilliseconds : 0,
      );

      if (rc != 0) {
        calloc.free(ptr);
        throw ZenohException('Failed to declare querier', rc);
      }
    } finally {
      calloc.free(keyExprNative);
    }

    return Querier._(ptr, keyExpr);
  }

  /// The key expression this querier is declared on.
  String get keyExpr {
    if (_closed) throw StateError('Querier has been closed');
    return _keyExpr;
  }

  /// Undeclares the querier and releases native resources.
  ///
  /// Safe to call multiple times -- subsequent calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    bindings.zd_querier_drop(_ptr.cast());
    calloc.free(_ptr);
  }
}
