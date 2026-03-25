---
description: Sync dev repo (zenoh_dart_dev) to prod repo (zenoh_dart) and verify
user_invocable: true
---

Spawn a background agent to sync the dev repo to prod and verify. Do NOT commit or push — the user reviews first.

The agent must execute these steps in order:

1. Run `./scripts/sync-to-prod.sh` from the dev repo root
2. Run `cd ../zenoh_dart/package && fvm dart pub get && fvm dart analyze && fvm dart test`
3. Report back:
   - Files changed (from git diff --stat in prod)
   - Analysis result (0 issues expected)
   - Test result (193+ tests expected)
   - Any errors or warnings

If any step fails, stop and report the failure. Do not attempt to fix issues — report them for the user to decide.
