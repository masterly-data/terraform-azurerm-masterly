### Changed

- `cut-release` is the Stable path (ADR 0107 §5): `promote.yml` in `masterly-release-tests`
  dispatches it with the commit and version from the signed Stable ring record. It now refuses a
  version whose `MANIFEST.json` entry at the commit does not name `masterly.azurecr.io/release/`
  images with a `digests.api` and `digests.frontend`, so no version is tagged naming its images by
  tag alone. A tag that already exists at exactly the given commit is no longer refused: the run
  writes no tag and goes on, so a run that failed after creating the tag is finished by dispatching
  it again. A tag at another commit is still refused, now naming both commits. Once the tag is at
  the commit, the workflow sends the `repository_dispatch` `release-published` (version, tag,
  commit) to `masterly-release-tests`, with a second App token scoped to that repository.

### Documentation

- `docs/releasing.md` and the README's "Cutting a release": who dispatches `cut-release` at
  Stable, what `release-published` carries, why a re-run at the same commit is safe, and the
  owner's grants for the Stable path.
