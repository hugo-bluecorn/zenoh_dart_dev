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
  --exclude='CHANGELOG.md' \
  --exclude='LICENSE' \
  --exclude='.claude/'
rsync -av --delete "$DEV_ROOT/src/" "$PROD_ROOT/src/"
rsync -av --delete "$DEV_ROOT/scripts/" "$PROD_ROOT/scripts/" \
  --exclude='sync-to-prod.sh'

# Sync root build files
cp "$DEV_ROOT/CMakeLists.txt" "$PROD_ROOT/CMakeLists.txt"
cp "$DEV_ROOT/CMakePresets.json" "$PROD_ROOT/CMakePresets.json"

echo ""
echo "Sync complete. Review changes in prod:"
cd "$PROD_ROOT" && git status && git diff --stat
