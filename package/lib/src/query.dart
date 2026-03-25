import 'dart:ffi';
import 'dart:typed_data';

import 'native_lib.dart';

/// A received query on a queryable key expression.
///
/// Wraps a heap-allocated `z_owned_query_t`. The query holds a cloned
/// reference to the original query from the callback. Call [dispose]
/// when done to release native resources (even if no reply was sent).
class Query {
  final int _handle;
  bool _disposed = false;

  /// The key expression of this query.
  final String keyExpr;

  /// The query parameters (selector portion after '?'). Empty if none.
  final String parameters;

  /// The optional payload attached to this query.
  final Uint8List? payloadBytes;

  /// Creates a Query from NativePort message data.
  ///
  /// This is called internally by [Queryable] stream handler.
  Query({
    required int handle,
    required this.keyExpr,
    required this.parameters,
    this.payloadBytes,
  }) : _handle = handle;

  /// The native pointer handle for this query (used by reply methods).
  int get handle {
    if (_disposed) {
      throw StateError('Query has been disposed');
    }
    return _handle;
  }

  /// Sends a reply to this query with a string value.
  ///
  /// Not yet implemented -- will be added in a later slice.
  void reply(String keyExpr, String value) {
    throw UnimplementedError('Query.reply not yet implemented');
  }

  /// Sends a reply to this query with raw bytes.
  ///
  /// Not yet implemented -- will be added in a later slice.
  void replyBytes(String keyExpr, Uint8List payload) {
    throw UnimplementedError('Query.replyBytes not yet implemented');
  }

  /// Releases the native query resources.
  ///
  /// Must be called even if no reply was sent. Safe to call multiple times.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    bindings.zd_query_drop(
      Pointer.fromAddress(_handle).cast(),
    );
  }
}
