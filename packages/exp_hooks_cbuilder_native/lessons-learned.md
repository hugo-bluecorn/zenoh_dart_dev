# Experiment B2: CBuilder + @Native — Lessons Learned

## Criteria Evaluation

### 1. Build hook correctness
- [ ] `hook/build.dart` compiles C shim via CBuilder and registers CodeAssets

### 2. @Native symbol resolution
- [ ] `@DefaultAsset` URI matches CBuilder assetName after auto-prefix
- [ ] `zd_init_dart_api_dl` and `zd_init_log` resolve without LD_LIBRARY_PATH

### 3. DT_NEEDED resolution
- [ ] libzenohc.so resolves via co-location (RUNPATH=$ORIGIN on libzenoh_dart.so)

### 4. No DynamicLibrary.open
- [ ] All lib/ source uses @Native annotations exclusively

### 5. Workspace integration
- [ ] Package resolves in monorepo workspace
- [ ] `fvm dart test` passes
- [ ] `fvm dart analyze` clean

### 6. Smoke test
- [ ] `fvm dart run example/smoke.dart` prints `initZenohDart() returned: true`

## Cross-Experiment Comparison

| Criterion | A1 (prebuilt+dlopen) | A2 (prebuilt+native) | B1 (cbuilder+dlopen) | B2 (cbuilder+native) |
|-----------|---------------------|---------------------|---------------------|---------------------|
| Build hook complexity | | | | |
| Symbol resolution | | | | |
| LD_LIBRARY_PATH needed | | | | |
| DT_NEEDED handling | | | | |
| Lines of Dart code | | | | |
| Test pass/fail | | | | |

## Notes

(To be filled after experiment completion)
