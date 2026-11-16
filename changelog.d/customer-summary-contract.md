### Added

- `scripts/check_customer_summary.py`, and a `release-metadata` step that runs its `--selftest` and
  then the check: every `customer-summary/X.Y.Z.json` must match the contract and a key of
  `MANIFEST.json`, and no string in it may name an internal host, a private-link name, an `msly-*`
  resource or a storage URL, or a security finding beyond counts by severity.

### Documentation

- `docs/customer-summary.md`: the schema 1 contract for the redacted customer summary published
  beside the release manifest.
