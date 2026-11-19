### Security

- **Installs on the `previous` channel should move to `0.24.0`.** At module `v0.23.0` and `v0.24.0`, `previous` selects `0.22.0` or `0.23.0`, the two releases that now record a `known_issue` for known HIGH-severity findings in their images; the manifests at those tags do not record it. With both skipped, `previous` in a module sourced from `main` selects `0.21.0` (api `v0.134.0`, frontend `v0.142.0`), whose images are older, until a release newer than `0.24.0` is cut. Set `release_channel = "stable"` on module `v0.24.0` or later.
