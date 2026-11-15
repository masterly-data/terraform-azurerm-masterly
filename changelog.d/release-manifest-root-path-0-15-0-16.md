### Fixed

- **MANIFEST.json: `0.15.0` and `0.16.0` name their images where they are.** Their builds (api `v0.133.2`/`v0.133.5`, frontend `v0.138.2`/`v0.139.0`) were never published under `release/`: they exist only at the registry root, `masterly.azurecr.io/api:<tag>` and `masterly.azurecr.io/frontend:<tag>`, and are unsigned. Both entries now name those root-path references with the same tags, and each records a `known_issue` saying so and to move to `0.18.0` or later. An install pinned to either pair should move. No other entry changes, and `latest` and the channel defaults do not move.

### Changed

- **The release check accepts a root-path api or frontend image in an older entry with a `known_issue`.** `scripts/check_release_manifest.py` allows `<registry>/api:<tag>` or `<registry>/frontend:<tag>` beside the never-published exception, only in an entry other than `latest` that records a `known_issue`. The newest release, a per-role image, and any other repository (`candidate/api`) are still refused, each pinned by a `--selftest` case.

### Documentation

- **docs/release-manifest.md** names both exceptions to the `release/` rule in the field table, "The image path" and "Compatibility", and says where each range of entries has its images: `0.22.0` and later under `release/` from release, `0.18.0` to `0.21.0` under `release/` by backfill, `0.17.0`'s api never published, and `0.15.0`/`0.16.0` only at the root, unsigned.
