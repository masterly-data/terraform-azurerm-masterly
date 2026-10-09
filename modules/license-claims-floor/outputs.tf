output "token_claims_version" {
  value       = local.token_claims_version
  description = "The claims version the licence was minted under, from its signed header. 0 when the header carries none, or when there is no licence."
}

output "token_claims_floor" {
  value       = local.token_claims_floor
  description = "The lowest claims version that may verify the licence, from its signed header. 0 when the header carries none, or when there is no licence."
}

output "image_claims_version" {
  value       = local.image_claims_version
  description = "The claims version the pinned api image verifies, as the release manifest records it. Null when the manifest records no release on the image's tag, and then nothing is checked."
}

output "move_to_tag" {
  value       = local.move_to_tag
  description = "The oldest api tag the manifest records whose claims version is at or above the licence's floor. Null when no recorded release reaches it."
}

output "refused" {
  value       = local.refused
  description = "True when the pinned api image would refuse the licence at startup: the licence's floor is above the image's claims version."
}

output "message" {
  value = local.refused ? format(
    "This licence cannot run on the pinned api image: its signed header sets a claims floor of %d, and %s verifies claims version %d, so the application would refuse the licence at startup and not come up. %s Set api_image to it, roll the running api and workers apps to it (terraform apply does not roll a running image; see Upgrades in the install documentation), then apply this licence. Until then, keep the licence the install runs now.",
    local.token_claims_floor,
    var.api_image,
    coalesce(local.image_claims_version, 0),
    local.move_to_tag != null ? format("The oldest api release that verifies it is %s.", local.move_to_tag) : format("No api release this module version records verifies claims version %d: upgrade the module to a release whose MANIFEST.json names one, and take its api image.", local.token_claims_floor),
  ) : null
  description = "Why the plan is refused, naming the image's claims version, the licence's floor and the api tag to move to. Null when it is not refused."
}
