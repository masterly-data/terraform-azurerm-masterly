# Whether the pinned api image can verify the licence it is about to be given (ADR 0013, amendment
# of 2026-10-06, point 5 "By a re-issued bundle").
#
# A licence states, in its signed JOSE header, the claims version it was minted under
# (masterly_claims_version) and the lowest claims version an install may verify it with
# (masterly_claims_floor). An api build declares the one claims version it knows, and refuses at
# startup any licence whose floor is above it. A re-issued licence applied with `terraform apply`
# reaches that startup check directly, so this module answers the same question at plan time,
# before anything is applied, and names the api release to move to.
#
# Everything here is offline. The image's claims version is read from the release manifest that
# ships inside this module (api_claims_version, per release), never from a registry, so an
# air-gapped install plans exactly as a connected one does.
#
# What is deliberately NOT checked, and passes as it always has:
#   - no licence, or a token whose header carries neither parameter (version 0, floor 0);
#   - a token whose header cannot be decoded — the application's own verification at startup
#     refuses a malformed token, and a plan-time guess about one would only add a second opinion;
#   - an api image whose tag no release in the manifest records (a hand-built or retagged image,
#     or an image newer than this module version) and which carries no digest a release records
#     (a Canary or Beta build, or a release cut before digests were recorded) — its claims version
#     is not known here, and the application's startup check remains the backstop.

locals {
  # The token's first segment is its JOSE header: base64url, unpadded (RFC 7515). Terraform's
  # base64decode reads the standard alphabet with padding, so translate the two characters that
  # differ and restore the padding.
  header_segment = var.license_token == null ? "" : split(".", var.license_token)[0]
  header_base64 = format(
    "%s%s",
    replace(replace(local.header_segment, "-", "+"), "_", "/"),
    substr("===", 0, (4 - length(local.header_segment) % 4) % 4),
  )
  header = try(jsondecode(base64decode(local.header_base64)), {})

  # The two header parameters are public metadata, not secrets: they say which contract the
  # licence speaks, nothing about what it grants. They are unmarked so the plan can name them.
  token_claims_version = nonsensitive(try(floor(tonumber(local.header["masterly_claims_version"])), 0))
  token_claims_floor   = nonsensitive(try(floor(tonumber(local.header["masterly_claims_floor"])), 0))

  # An api image reference is registry/.../api:tag, registry/.../api:tag@sha256:<digest> or
  # registry/.../api@sha256:<digest>. The groups capture the tag and the digest; one that is absent
  # captures nothing, which coalesce turns into null.
  api_ref_pattern   = "^[^\\s/]+(?:/[^\\s/:]+)*/api(?::([^\\s/:@]+))?(?:@(sha256:[0-9a-f]{64}))?$"
  pinned_api_ref    = try(regex(local.api_ref_pattern, var.api_image), [null, null])
  pinned_api_tag    = try(coalesce(local.pinned_api_ref[0]), null)
  pinned_api_digest = try(coalesce(local.pinned_api_ref[1]), null)

  # Every api tag and api digest the manifest records, with the claims version its build verifies.
  # A release entry cut before api_claims_version existed records none; every api image released
  # before it existed verifies claims version 0, so that is what an absent value means (the
  # manifest's own contract says so). Two module releases on the same api tag record the same
  # build. A release entry cut before digests were recorded names no digest.
  recorded = [
    for version, release in try(var.manifest.releases, {}) : {
      tag            = try(coalesce(regex(local.api_ref_pattern, release.images.api)[0]), null)
      digest         = try(lower(release.digests.api), null)
      claims_version = try(floor(tonumber(release.api_claims_version)), 0)
    }
  ]
  claims_version_by_tag = {
    for r in local.recorded : r.tag => r.claims_version... if r.tag != null
  }
  claims_version_by_digest = {
    for r in local.recorded : r.digest => r.claims_version... if r.digest != null
  }

  # A tag a release records decides, as it always has, so a mirror that kept the tag is
  # recognised whatever its digest. A reference with no tag, or with a tag no release records (a
  # release mirrored under a tag of your own), is resolved by its digest.
  tag_claims_version    = local.pinned_api_tag == null ? null : try(max(local.claims_version_by_tag[local.pinned_api_tag]...), null)
  digest_claims_version = local.pinned_api_digest == null ? null : try(max(local.claims_version_by_digest[local.pinned_api_digest]...), null)
  image_claims_version  = local.tag_claims_version != null ? local.tag_claims_version : local.digest_claims_version

  # The oldest recorded api release that verifies the token's floor: the tag to move to. Ordered
  # by semver, so v0.9.0 sorts before v0.10.0; a tag that is not vX.Y.Z cannot be ordered and is
  # never proposed.
  candidate_keys = sort([
    for tag, versions in local.claims_version_by_tag : format(
      "%08d.%08d.%08d %s",
      tonumber(regex("^v(\\d+)\\.(\\d+)\\.(\\d+)$", tag)[0]),
      tonumber(regex("^v(\\d+)\\.(\\d+)\\.(\\d+)$", tag)[1]),
      tonumber(regex("^v(\\d+)\\.(\\d+)\\.(\\d+)$", tag)[2]),
      tag,
    ) if can(regex("^v\\d+\\.\\d+\\.\\d+$", tag)) && max(versions...) >= local.token_claims_floor
  ])
  move_to_tag = length(local.candidate_keys) > 0 ? split(" ", local.candidate_keys[0])[1] : null

  checked = local.image_claims_version != null
  refused = local.checked && local.token_claims_floor > coalesce(local.image_claims_version, 0)
}
