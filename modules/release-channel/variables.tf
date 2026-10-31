variable "manifest" {
  type        = any
  description = "The decoded release manifest (MANIFEST.json, docs/release-manifest.md): `latest`, and per release its `images`, its `digests` when recorded, and a `known_issue` when one was found."
}

variable "channel" {
  type        = string
  description = "The release channel (the root module's release_channel): \"stable\" is the manifest's `latest`; \"previous\" is the newest release older than `latest` that carries no known_issue."

  validation {
    condition     = contains(["stable", "previous"], var.channel)
    error_message = "channel must be \"stable\" or \"previous\"."
  }
}

variable "registry" {
  type        = string
  description = "The registry host the default references are built on, e.g. masterly.azurecr.io: the release/<role> repositories live there."
}

variable "api_image" {
  type        = string
  default     = null
  description = "An api image set explicitly (the root module's api_image). Null resolves the channel's release/api reference instead."
}

variable "frontend_image" {
  type        = string
  default     = null
  description = "A frontend image set explicitly (the root module's frontend_image). Null resolves the channel's release/frontend reference instead."
}
