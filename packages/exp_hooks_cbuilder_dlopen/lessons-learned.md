# Experiment B1: CBuilder + DynamicLibrary.open()

## Hypothesis
CBuilder.library() from native_toolchain_c can compile a minimal C shim from
source at hook time, linking against a prebuilt libzenohc.so. The loading
mechanism (DynamicLibrary.open) is expected to fail the same way as A1.

## Observations

### Build Hook (CBuilder)
- TODO: Does CBuilder compile the C shim successfully?
- TODO: Does CBuilder handle include paths correctly?
- TODO: Does CBuilder link against the prebuilt libzenohc.so?
- TODO: Is RUNPATH set to $ORIGIN automatically?

### Loading (DynamicLibrary.open)
- TODO: Same failure mode as A1? (Expected: yes)

## Conclusions
- TODO: Fill in after running experiments
