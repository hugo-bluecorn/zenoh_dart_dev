# Proposal: Dev Layout Restructure & Prod Sync Workflow

**Date:** 2026-03-24
**Author:** CA (Code Architect)
**Status:** Proposal — awaiting review

---

## Problem

After the product/workshop repo split, the two repositories have different layouts:

| Aspect | zenoh_dart_dev (dev) | zenoh_dart (prod) |
|--------|---------------------|-------------------|
| Dart package | `package/` | `package/` |
| Android prebuilt path | `android/src/main/jniLibs/` (interim) + `package/native/android/` | `package/native/android/` (direct) |
| Linux prebuilt discovery | `native/linux/` (bare) | `package/native/linux/` (scoped) |
| Root pubspec | Workspace + Melos | None |
| ffigen paths | `../../src/`, `../../extern/` | `../src/`, `../extern/` |

This means code developed in dev cannot be copied to prod without path translation. Every sync requires rewriting the same paths CC already rewrote during the split. This is fragile and defeats the purpose of having matching repos.

Additionally, `native_lib.dart` has a bug discovered during Flutter desktop testing: it throws when `_resolveLibraryPath()` returns null instead of trying a bare `DynamicLibrary.open('libzenoh_dart.so')` as a last resort. The Flutter runner's `RUNPATH=$ORIGIN/lib` would resolve it, but the code never tries. This bug exists in both repos and should be fixed as part of this restructure.

---

## Why a Separate Dev Repo Exists

AI-assisted development with Claude Code generates far more structured artifacts than traditional development: phase specs, design docs with multi-pass revisions, TDD progress files, experiment results, audit documents, LaTeX papers, memory files, role definitions, proposals with review cycles. None of this belongs in a product repo, but all of it is valuable during development. The dev repo is the workshop; the prod repo is the showroom.

---

## Proposal

### Part 1: Restructure Dev Layout

Move `package/` to `package/` and update all path references so dev and prod have identical layouts for the code-bearing directories.

#### Directory change

```
# Before                          # After
packages/                         package/
  zenoh/                            lib/
    lib/                            hook/
    hook/                           native/
    native/                         example/
    example/                        test/
    test/                           pubspec.yaml
    pubspec.yaml                    ffigen.yaml
    ffigen.yaml                     analysis_options.yaml
    analysis_options.yaml
```

Everything else in dev stays as-is: `docs/`, `development/`, `experiments/`, `.claude/`, `extern/` (all 7 submodules).

#### Files requiring path rewrites

**Build infrastructure (critical — affects builds and tests):**

| File | Change |
|------|--------|
| `CMakeLists.txt` (root) | `package/native` → `package/native` |
| `src/CMakeLists.txt` | Android: `android/src/main/jniLibs/${ANDROID_ABI}` → `package/native/android/${ANDROID_ABI}`; Linux: `native/linux/` → `package/native/linux/` |
| `scripts/build_zenoh_android.sh` | Eliminate `JNILIBS_DIR` and jniLibs intermediate; `NATIVE_ANDROID_DIR` → `package/native/android` |
| `package/ffigen.yaml` | `../../src/` → `../src/`; `../../extern/` → `../extern/` |
| `package/lib/src/native_lib.dart` | Remove `package/` fallback candidates from CWD probing |
| `package/pubspec.yaml` | Remove `resolution: workspace`; update `repository` URL |
| Root `pubspec.yaml` | Delete (no workspace needed) |
| `.gitignore` | Remove `packages/*/coverage/` and `package/native/android/`; add note that `package/native/` must not be excluded |

**Documentation (non-blocking but should be updated):**

| File | Approximate changes |
|------|-------------------|
| `CLAUDE.md` | ~24 references: `cd package` → `cd package`, path references |
| `README.md` | ~7 references |
| `.claude/skills/role-ca/SKILL.md` | 5 references |
| `.claude/skills/role-cp/SKILL.md` | 1 reference |

**Design docs (`docs/design/*.md`, `development/proposals/*.md`):** 50+ references. These are historical artifacts — update only if trivial (global find-replace). Do not hand-edit each one.

#### native_lib.dart bug fix

In `ensureInitialized()`, after `_resolveLibraryPath()` returns null, try a bare `DynamicLibrary.open('libzenoh_dart.so')` before throwing. This lets the OS linker use RUNPATH (Flutter desktop `$ORIGIN/lib`) or LD_LIBRARY_PATH as a last resort:

```dart
final libPath = _resolveLibraryPath('libzenoh_dart.so');
if (libPath != null) {
  lib = DynamicLibrary.open(libPath);
} else {
  // Last resort: let the OS linker resolve via RUNPATH/LD_LIBRARY_PATH.
  // This handles Flutter desktop (RUNPATH=$ORIGIN/lib in the runner binary).
  try {
    lib = DynamicLibrary.open('libzenoh_dart.so');
  } catch (e) {
    throw StateError(
      'Could not find libzenoh_dart.so. Ensure the build hook has run.',
    );
  }
}
```

This fix applies to both dev and prod repos.

#### Verification gate

- `cd package && fvm dart pub get && fvm dart analyze && fvm dart test` — 0 issues, 193 tests pass
- `cd package && fvm dart run ffigen --config ffigen.yaml` — regenerates without drift
- `cmake --preset linux-x64 && cmake --build --preset linux-x64 --target install` — builds and installs to `package/native/linux/x86_64/`

---

### Part 2: Sync Mechanism

#### Direction

One-way: **dev → prod**. All code changes originate in dev. Prod never has direct commits except sync deliveries.

#### What syncs

| Syncs to prod | Stays in dev only |
|--------------|-------------------|
| `package/` (entire directory) | `docs/`, `development/`, `experiments/` |
| `src/` (C shim source) | `.claude/` (skills, roles, settings) |
| `scripts/` (build scripts) | `extern/` (all 7 submodules — prod has only zenoh-c) |
| `CMakeLists.txt`, `CMakePresets.json` | `.tdd-progress.md` |
| `.gitignore` | Dev-specific `CLAUDE.md` and `README.md` |

Note: prod has its own `CLAUDE.md`, `README.md`, `package/README.md`, and `package/CHANGELOG.md` that are maintained independently — they are simpler, user-facing versions.

#### Mechanism: script + manual trigger

A sync script at `scripts/sync-to-prod.sh` that:

1. Copies `package/`, `src/`, `scripts/`, `CMakeLists.txt`, `CMakePresets.json` from dev to prod
2. Preserves prod-only files (prod's `CLAUDE.md`, `README.md`, `package/README.md`, `package/CHANGELOG.md`, `.gitignore`, `LICENSE`)
3. Reports a diff summary for review before committing

```bash
#!/bin/bash
set -euo pipefail

DEV_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROD_ROOT="${DEV_ROOT}/../zenoh_dart"

if [[ ! -d "$PROD_ROOT/.git" ]]; then
  echo "Error: prod repo not found at $PROD_ROOT"
  exit 1
fi

# Sync code directories (delete stale files in destination)
rsync -av --delete "$DEV_ROOT/package/" "$PROD_ROOT/package/" \
  --exclude='README.md' \
  --exclude='CHANGELOG.md'
rsync -av --delete "$DEV_ROOT/src/" "$PROD_ROOT/src/"
rsync -av --delete "$DEV_ROOT/scripts/" "$PROD_ROOT/scripts/" \
  --exclude='sync-to-prod.sh'

# Sync root build files
cp "$DEV_ROOT/CMakeLists.txt" "$PROD_ROOT/CMakeLists.txt"
cp "$DEV_ROOT/CMakePresets.json" "$PROD_ROOT/CMakePresets.json"

echo ""
echo "Sync complete. Review changes in prod:"
cd "$PROD_ROOT" && git status && git diff --stat
```

The developer runs the script, reviews the diff in prod, then commits and pushes prod. No automation — the human is the gate.

#### Why not GitHub Actions?

At this project's scale (one developer + Claude Code, releases every few weeks), automated sync adds complexity without saving meaningful time. A script the developer runs intentionally is simpler, auditable, and doesn't require deploy keys or PAT management. If the project grows, upgrading to a GitHub Action is straightforward — the script already defines what syncs.

#### Why not Copybara / subtree / submodules?

Overkill. The sync is a flat directory copy with a few exclusions. The repos have identical layouts for the code-bearing directories. No path remapping, no content transforms, no bidirectional sync needed.

---

## Execution

**This is a CI direct-edit task, not TDD.** Same as the original split.

### Steps

1. `git mv package package` — preserves git history for the move
2. Delete root `pubspec.yaml` (workspace config)
3. Edit `package/pubspec.yaml` — remove `resolution: workspace`, update `repository` URL
4. Rewrite paths in build files — `CMakeLists.txt` (root), `src/CMakeLists.txt`, `scripts/build_zenoh_android.sh`
5. Rewrite paths in `package/ffigen.yaml`
6. Fix `package/lib/src/native_lib.dart` — remove stale fallback candidates + add bare DynamicLibrary.open fallback
7. Update `.gitignore`
8. Verify ffigen: `cd package && fvm dart run ffigen --config ffigen.yaml`
9. Verify: `cd package && fvm dart pub get && fvm dart analyze && fvm dart test`
10. Global find-replace `package` → `package` in `CLAUDE.md`, `README.md`, `.claude/skills/role-ca/SKILL.md`, `.claude/skills/role-cp/SKILL.md`
11. Global find-replace `package` → `package` in `docs/` and `development/` (best-effort, these are historical)
12. Create `scripts/sync-to-prod.sh`
13. Sync to prod: run `scripts/sync-to-prod.sh`, verify prod tests pass, commit and push both repos

### Verification gate

- Dev: 0 analysis issues, 193 tests pass, ffigen regenerates clean
- Prod: 193 tests pass after sync
- Flutter counter app: `fvm flutter run -d linux` connects successfully (validates native_lib.dart fix)

---

## Risks

| # | Risk | Mitigation |
|---|------|------------|
| 1 | `git mv` doesn't preserve history for some tools | `git log --follow package/lib/src/session.dart` works; GitHub shows the move |
| 2 | ffigen paths wrong after rewrite | Regenerate and diff — step 8 catches this |
| 3 | Sync script misses a file | Script uses `rsync --delete` for directory sync + explicit `cp` for root files. Review diff before committing. |
| 4 | Design docs have stale `package` references | Non-blocking — these are historical. Global find-replace in step 11 handles most. |
| 5 | native_lib.dart bare open catches too broadly | The `try/catch` only wraps `DynamicLibrary.open`, which throws `ArgumentError` on failure. Specific enough. |
