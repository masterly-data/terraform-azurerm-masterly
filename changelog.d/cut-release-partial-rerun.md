### Fixed

- **Re-running a failed `cut-release` run with only its failed jobs now works.** That kind of
  re-run reuses the `verify` job's outputs from the earlier attempt, so after a run had created
  the tag and then failed, the `tag` job tried to create the tag again and failed with `Reference
  already exists`. The `tag` job now reads where the tag is before it writes. If the tag is at the
  release commit, it skips the write and still sends `release-published`; if it is at another
  commit, the run is refused. Internal release tooling only: no input, output or resource changes,
  so an install plans no change.
