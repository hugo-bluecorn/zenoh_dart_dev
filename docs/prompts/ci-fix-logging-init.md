# CI Prompt: Expose Zenoh.initLog() — Direct Edit

**From:** CA (Architect)
**Type:** Direct edit (no TDD — this is a Phase 0 oversight, not a new feature)
**Branch:** Create `fix/logging-init` from `main`

## Context

Phase 0 implemented the C shim function `zd_init_log(const char* fallback_filter)`
which wraps `zc_init_log_from_env_or()`. The generated FFI bindings include it.
But no Dart API wrapper was ever created, and neither CLI example calls it.

Every other zenoh binding (C, C++, Kotlin) calls log init as the **first line
of main()**. Without it, zenoh's internal logging (connection errors, protocol
issues) is completely silent.

## What to Do

### 1. Create `package/lib/src/zenoh.dart`

A minimal static utility class mirroring C++ `zenoh::init_log_from_env_or()`:

```dart
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
```

### 2. Export from `package/lib/zenoh.dart`

Add this line to the barrel export file:

```dart
export 'src/zenoh.dart';
```

### 3. Update `package/bin/z_put.dart`

Add `Zenoh.initLog('error');` as the first line inside `main()`, before the
print statement:

```dart
void main(List<String> arguments) {
  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addOption('payload', abbr: 'p', defaultsTo: defaultValue);

  final results = parser.parse(arguments);
  final keyExpr = results.option('key')!;
  final value = results.option('payload')!;

  Zenoh.initLog('error');

  print('Opening session...');
  final session = Session.open();

  print("Putting Data ('$keyExpr': '$value')...");
  session.put(keyExpr, value);

  session.close();
}
```

### 4. Update `package/bin/z_delete.dart`

Same pattern — add `Zenoh.initLog('error');` before the session open. Read the
file first to see its current structure.

### 5. Add a test to `package/test/zenoh_test.dart`

Create a new test file with minimal coverage:

```dart
import 'package:test/test.dart';
import 'package:zenoh/zenoh.dart';

void main() {
  group('Zenoh', () {
    test('initLog does not throw', () {
      // initLog is idempotent — safe to call in tests.
      expect(() => Zenoh.initLog('error'), returnsNormally);
    });

    test('initLog accepts various filter levels', () {
      // Subsequent calls are no-ops in zenoh-c, but should not throw.
      expect(() => Zenoh.initLog('warn'), returnsNormally);
      expect(() => Zenoh.initLog('info'), returnsNormally);
    });
  });
}
```

### 6. Verify

```bash
cd package

# Analyze
fvm dart analyze

# Run new test
LD_LIBRARY_PATH=../../extern/zenoh-c/target/release:../../build \
  fvm dart test test/zenoh_test.dart

# Run full suite to confirm no regressions
LD_LIBRARY_PATH=../../extern/zenoh-c/target/release:../../build \
  fvm dart test
```

### 7. Commit and push

Three commits on `fix/logging-init`:

1. `feat(zenoh): add Zenoh.initLog() for runtime logger initialization`
   — new file + export + test
2. `fix(z-put): call Zenoh.initLog before session open`
   — z_put.dart update
3. `fix(z-delete): call Zenoh.initLog before session open`
   — z_delete.dart update

Push and create a PR targeting `main`.

## Acceptance Criteria

- [ ] `Zenoh.initLog('error')` callable without throwing
- [ ] Both CLI examples call `Zenoh.initLog('error')` before `Session.open()`
- [ ] `fvm dart analyze` passes with no issues
- [ ] All existing tests still pass (56 tests)
- [ ] New test file adds at least 2 passing tests
- [ ] API mirrors C++ intent: `zenoh::init_log_from_env_or(fallback)` → `Zenoh.initLog(fallback)`

## What NOT to Do

- Do NOT add `tryInitLogFromEnv()` yet — defer to Phase 2
- Do NOT add callback-based logging — defer to Phase 2
- Do NOT add `package:logging` dependency — defer to Phase 2
- Do NOT modify `ffi/ffi` dependency — `package:ffi` is already in pubspec.yaml
- Do NOT update CLAUDE.md or README — CA will handle docs after merge
