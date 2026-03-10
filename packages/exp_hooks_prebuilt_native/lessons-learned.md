# Experiment A2: Prebuilt + @Native — Lessons Learned

## Verification Criteria

1. [ ] `fvm dart test` passes without `LD_LIBRARY_PATH`
2. [ ] `fvm dart run example/smoke.dart` succeeds without `LD_LIBRARY_PATH`
3. [ ] `fvm dart analyze` clean (no warnings/errors)
4. [ ] `readelf -d native/linux/x86_64/libzenoh_dart.so | grep RUNPATH` shows `$ORIGIN`
5. [ ] No `DynamicLibrary.open()` in any `.dart` file under `lib/`
6. [ ] Build hook declares two CodeAsset entries (libzenoh_dart.so + libzenohc.so)

## A1 vs A2 Comparison

| Aspect | A1 (DynamicLibrary.open) | A2 (@Native) |
|--------|--------------------------|--------------|
| Loading mechanism | `DynamicLibrary.open('libzenoh_dart.so')` | `@DefaultAsset` + `@Native` |
| Asset resolution | Manual path lookup | Dart runtime resolves via asset ID |
| No LD_LIBRARY_PATH needed? | TBD | TBD |
| Binding style | `lookupFunction<>()` | `external` functions with `@Native` |

## Findings

(To be filled during experimentation)
