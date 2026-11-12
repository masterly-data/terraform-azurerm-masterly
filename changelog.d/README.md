# Changelog fragments

A change to the module adds one file here instead of editing `CHANGELOG.md`, so two changes never
conflict on the changelog. `## [Unreleased]` in `CHANGELOG.md` stays empty; `scripts/check_release_manifest.py`
fails the build if an entry is written there.

## A fragment

* **Name:** `changelog.d/<short-name>.md`, for example `MAS-1234.md` or `cert-renewal.md`. Fragments
  are folded in filename order.
* **Content:** only `### <Type>` subsections, each followed by its body (the bullets exactly as they
  should read in `CHANGELOG.md`). No title, no `##` heading, no text before the first subsection.
* **Allowed headings:** `### Added`, `### Changed`, `### Deprecated`, `### Removed`, `### Fixed`,
  `### Security`, `### Documentation`.
* **Lines the fold reads as structure:** a line starting with `#` and a space (even inside a code
  fence) is refused as a heading, and a line like `[name]: url` ends the section. Indent or
  reword such a line.
* **A breaking change** carries its migration note in the fragment, as it would in the changelog.

```markdown
### Fixed

- The thing that was wrong, and what an install sees now.
```

## At release-cut

The release-preparation commit runs `python3 scripts/fold_changelog.py X.Y.Z YYYY-MM-DD`. It moves
every fragment under `## [X.Y.Z] - YYYY-MM-DD` directly below `## [Unreleased]`, merges the
subsections in the order above, and deletes the folded fragments, all in that commit. It refuses,
and writes nothing, on an unknown heading or text outside a subsection, naming the file.
`check_release_manifest.py --tag` refuses a tree that still has a fragment; this README and
`.gitkeep` are the only files that stay.
