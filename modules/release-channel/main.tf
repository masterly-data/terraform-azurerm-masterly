# Which images an install is created with when api_image and frontend_image are left null: the
# release the channel selects in the release manifest, as release/<role> on the selected registry.
#
# Everything here is offline. The manifest ships inside the module, so an air-gapped install
# resolves exactly as a connected one does. The root module reads its own MANIFEST.json; the
# manifest is an input here so the resolution can be proven against a synthetic one (a release
# with no digests, a channel with no release) that the shipped manifest never reaches.
#
# The channel changes only the last part of each reference, the digest or the tag. The repository
# is always release/api and release/frontend, so a mirror keeps those repository names.

locals {
  # Versions are bare semver, zero-padded here so that sort() orders them as versions ("0.10.0"
  # after "0.9.0").
  release_by_sort_key = {
    for v in keys(var.manifest.releases) : format("%05d.%05d.%05d", split(".", v)...) => v
  }
  release_versions_newest_first = [
    for k in reverse(sort(keys(local.release_by_sort_key))) : local.release_by_sort_key[k]
  ]

  # "previous" is the newest release older than `latest` that carries no known_issue; null when
  # every older release does, or there is none.
  channel_versions = {
    stable = var.manifest.latest
    previous = try([
      for v in slice(
        local.release_versions_newest_first,
        index(local.release_versions_newest_first, var.manifest.latest) + 1,
        length(local.release_versions_newest_first)
      ) : v if try(var.manifest.releases[v].known_issue, null) == null
    ][0], null)
  }
  version = local.channel_versions[var.channel]
  release = try(var.manifest.releases[local.version], null)

  # The default references: pinned by the digest the release records, or by the tag of the image
  # it names for a release that records none. Null when the channel has no release; the `images`
  # output then refuses the plan, unless both images are set explicitly.
  channel_images = {
    for role in ["api", "frontend"] : role => try(
      "${var.registry}/release/${role}@${local.release.digests[role]}",
      "${var.registry}/release/${role}:${regex(":([^:@/]+)$", local.release.images[role])[0]}",
      null
    )
  }
  api_image      = var.api_image != null ? var.api_image : local.channel_images.api
  frontend_image = var.frontend_image != null ? var.frontend_image : local.channel_images.frontend
}
