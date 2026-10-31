output "version" {
  value       = local.version
  description = "The manifest release the channel resolved to, as a bare semver. Null when the channel has no release (\"previous\" with no older release free of a known_issue)."
}

output "images" {
  value = {
    api      = local.api_image
    frontend = local.frontend_image
  }
  description = "The api and frontend image references the apps are created with: an image set explicitly as given, otherwise <registry>/release/<role>@<digest> for the channel's release, or <registry>/release/<role>:<tag> when that release records no digest."

  precondition {
    condition     = local.api_image != null && local.frontend_image != null
    error_message = "release_channel = \"${var.channel}\" resolves to no release in this module version's MANIFEST.json, so api_image and frontend_image have no default. Set release_channel = \"stable\", or set api_image and frontend_image."
  }
}
