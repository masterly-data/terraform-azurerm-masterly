### Changed

- Internal tooling and contributor docs: a change adds a changelog fragment, `changelog.d/<short-name>.md`, instead of editing `## [Unreleased]`, which stays empty. The release-preparation commit runs `scripts/fold_changelog.py X.Y.Z YYYY-MM-DD`, which folds the fragments into the version's section and deletes them. `scripts/check_release_manifest.py` refuses an entry under Unreleased, and `--tag` refuses a tree that still has a fragment. No input, output or resource changes, so an install plans no change.
