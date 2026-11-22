### Added

- **`MANIFEST.json`: an optional `edge_image` in each release entry.** It names the module's
  default `ca-edge` (Envoy) image for that release beside its `api` and `frontend`, as one full
  reference pinned by digest, `registry/repository:tag@sha256:<64 lowercase hex>`. An install that
  sets `edge.image` runs that image instead. The field is outside `images` and `digests` (the edge
  is upstream's image, not published under `release/`, and `images` still refuses an `edge` key),
  and is added within `schema_version` 1: existing entries are unchanged and not back-filled. The
  release check refuses a value with no digest or in any other shape, and on a tag refuses a newest
  entry whose `edge_image` is not `edge_default_image` in `edge.tf`, or an `edge.tf` whose default
  it cannot read. See `docs/release-manifest.md`.
