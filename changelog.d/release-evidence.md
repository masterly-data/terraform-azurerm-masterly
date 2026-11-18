### Added

- `scripts/release_evidence.py`: turns a version's customer summary into release-note text. It runs
  the customer-summary contract check first and refuses on any failure, then renders the ring
  dates, gates passed, upgrade versions, performance per profile against the baseline version and
  the security counts. `--write` puts the block into the version's `CHANGELOG.md` section, and
  `--check`, run by `release-metadata`, fails on a hand-edited block, a summary with no block or
  a block with no summary.

### Documentation

- `docs/customer-summary.md`: a version's summary is read from `main`, is added after the tag and
  never appears in the tagged tree. `docs/releasing.md` and the README's "Cutting a release" gain
  the "At Stable" step.
