import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bytes.dart';
import 'consolidation_mode.dart';
import 'encoding.dart';
import 'exceptions.dart';
import 'native_lib.dart';
import 'query_target.dart';
import 'reply.dart';
import 'sample.dart';

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

  /// Sends a query via this querier and returns a stream of replies.
  ///
  /// Optional [parameters] are passed as query parameters.
  /// Optional [payload] is consumed (ownership transferred to zenoh-c).
  /// Optional [encoding] specifies the payload encoding.
  ///
  /// Throws [StateError] if the querier has been closed.
  Stream<Reply> get({
    String? parameters,
    ZBytes? payload,
    Encoding? encoding,
  }) {
    if (_closed) throw StateError('Querier is closed');

    final controller = StreamController<Reply>();
    final receivePort = ReceivePort();

    receivePort.listen((dynamic message) {
      if (message == null) {
        // Null sentinel: query complete
        receivePort.close();
        controller.close();
      } else if (message is List) {
        final tag = message[0] as int;
        if (tag == 1) {
          // Ok reply: [1, keyexpr, payload_bytes, kind, attachment, encoding]
          final keyExprStr = message[1] as String;
          final payloadBytes = message[2] as Uint8List;
          final kind = message[3] as int;
          final attachmentBytes = message[4] as Uint8List?;
          final encodingStr =
              message.length > 5 ? message[5] as String? : null;

          final sample = Sample(
            keyExpr: keyExprStr,
            payload: utf8.decode(payloadBytes),
            payloadBytes: payloadBytes,
            kind: kind == 0 ? SampleKind.put : SampleKind.delete,
            attachment: attachmentBytes != null
                ? utf8.decode(attachmentBytes)
                : null,
            encoding: encodingStr,
          );
          controller.add(Reply.ok(sample));
        } else if (tag == 0) {
          // Error reply: [0, error_payload_bytes, error_encoding]
          final errorPayloadBytes = message[1] as Uint8List;
          final errorEncoding =
              message.length > 2 ? message[2] as String? : null;

          final replyError = ReplyError(
            payloadBytes: errorPayloadBytes,
            payload: utf8.decode(errorPayloadBytes),
            encoding: errorEncoding,
          );
          controller.add(Reply.error(replyError));
        }
      }
    });

    Pointer<Utf8> parametersNative = nullptr;
    Pointer<Utf8> encodingNative = nullptr;

    if (parameters != null) {
      parametersNative = parameters.toNativeUtf8();
    }
    if (encoding != null) {
      encodingNative = encoding.mimeType.toNativeUtf8();
    }

    try {
      final rc = bindings.zd_querier_get(
        _ptr.cast(),
        parameters != null ? parametersNative.cast() : nullptr,
        receivePort.sendPort.nativePort,
        payload != null ? payload.nativePtr.cast() : nullptr,
        encoding != null ? encodingNative.cast() : nullptr,
      );

      if (rc != 0) {
        receivePort.close();
        controller.close();
        throw ZenohException('Querier get failed', rc);
      }

      // Mark ZBytes as consumed -- ownership transferred to zenoh-c
      if (payload != null) {
        payload.markConsumed();
      }
    } finally {
      if (parameters != null) calloc.free(parametersNative);
      if (encoding != null) calloc.free(encodingNative);
    }

    return controller.stream;
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
