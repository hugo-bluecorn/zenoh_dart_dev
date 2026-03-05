import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_lib.dart';

/// Top-level zenoh utilities.
///
/// Provides static methods for global zenoh initialization that must be
/// called before opening sessions.
class Zenoh {
  Zenoh._(); // prevent instantiation

  /// Initializes the zenoh logger from the `RUST_LOG` environment variable,
  /// falling back to [fallback] if `RUST_LOG` is not set.
  ///
  /// Must be called **before** [Session.open] for logging to take effect.
  /// This is a one-time initialization — subsequent calls are ignored by
  /// the underlying runtime.
  ///
  /// Filter syntax follows the Rust `env_logger` format:
  /// - `"error"` — errors only (recommended for production)
  /// - `"warn"` — warnings and errors
  /// - `"info"` — informational messages
  /// - `"debug"` — debug-level detail
  /// - `"trace"` — maximum verbosity
  ///
  /// See: https://docs.rs/env_logger/latest/env_logger/
  static void initLog(String fallback) {
    final cStr = fallback.toNativeUtf8();
    try {
      bindings.zd_init_log(cStr.cast<Char>());
    } finally {
      calloc.free(cStr);
    }
  }
}
