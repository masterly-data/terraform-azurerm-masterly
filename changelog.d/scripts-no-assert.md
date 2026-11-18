### Changed

- `scripts/check_runtime_env.py` and `scripts/check_release_manifest.py` check their internal
  invariants with explicit errors instead of `assert`, so running them under `python -O` (which
  strips asserts) no longer skips those checks. Their output and exit codes are unchanged.
