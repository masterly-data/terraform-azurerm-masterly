# Inputs read by identity.tf: the app images, the release channel and the registry pull credential.

variable "api_image" {
  type        = string
  default     = null
  description = "Fully-qualified api image, as registry/repository:tag, registry/repository:tag@sha256:<digest> or registry/repository@sha256:<digest> (64 lowercase hex), where the registry is a host containing \".\" or \":\", or localhost, and the repository's last segment is api (e.g. masterly.azurecr.io/release/api). Null (the default) takes the api image MANIFEST.json records for release_channel, as <registry>/release/api@sha256:<digest> on the registry registry_location names. The licence claims-floor check reads the tag, or the digest when there is no tag or no release in MANIFEST.json records the tag; a reference whose tag and digest no release records passes unchecked. Seeds the app; CD owns the running tag thereafter."

  validation {
    condition     = var.api_image == null ? true : can(regex("^(?:[^\\s/@]*[.:][^\\s/@]*|localhost)(?:/[^\\s/:@]+)*/api(?::\\w[\\w.-]{0,127}(?:@sha256:[0-9a-f]{64})?|@sha256:[0-9a-f]{64})$", var.api_image))
    error_message = "api_image must be registry/repository:tag, registry/repository:tag@sha256:<digest> or registry/repository@sha256:<digest>, with the registry a host containing \".\" or \":\" (or \"localhost\"), the digest as 64 lowercase hex characters after \"sha256:\", and \"api\" as the repository's last segment (e.g. masterly.azurecr.io/release/api@sha256:<digest>)."
  }
}

variable "frontend_image" {
  type        = string
  default     = null
  description = "Fully-qualified frontend image, as registry/repository:tag, registry/repository:tag@sha256:<digest> or registry/repository@sha256:<digest> (64 lowercase hex), where the registry is a host containing \".\" or \":\", or localhost, and the repository's last segment is frontend (e.g. masterly.azurecr.io/release/frontend). Null (the default) takes the frontend image MANIFEST.json records for release_channel, as <registry>/release/frontend@sha256:<digest> on the registry registry_location names. Seeds the app; CD owns the running tag thereafter."

  validation {
    condition     = var.frontend_image == null ? true : can(regex("^(?:[^\\s/@]*[.:][^\\s/@]*|localhost)(?:/[^\\s/:@]+)*/frontend(?::\\w[\\w.-]{0,127}(?:@sha256:[0-9a-f]{64})?|@sha256:[0-9a-f]{64})$", var.frontend_image))
    error_message = "frontend_image must be registry/repository:tag, registry/repository:tag@sha256:<digest> or registry/repository@sha256:<digest>, with the registry a host containing \".\" or \":\" (or \"localhost\"), the digest as 64 lowercase hex characters after \"sha256:\", and \"frontend\" as the repository's last segment (e.g. masterly.azurecr.io/release/frontend@sha256:<digest>)."
  }
}

variable "release_channel" {
  type        = string
  default     = "stable"
  description = "Which release in MANIFEST.json the default image references (api_image and frontend_image left null) resolve to. \"stable\" (the default) is the newest release, the image pair this module version was released against. \"previous\" is the newest older release with no known issue. The channel changes only the digest (or tag) of each image: the repository stays release/api and release/frontend on the registry that registry_location names. An image you set explicitly is used as given. Like api_image and frontend_image, the channel's references seed each app when it is created; CD owns the running image thereafter, so changing the channel on an existing install rolls nothing (terraform apply does not roll a running image). To roll a running install back, redeploy the previous image with az containerapp update --image, as the Upgrades section of the install documentation describes. The channel is not release_ring: it picks an image pair from MANIFEST.json, and says nothing about the install's release ring."

  validation {
    condition     = contains(["stable", "previous"], var.release_channel)
    error_message = "release_channel must be \"stable\" or \"previous\". A Canary or Beta build is not in MANIFEST.json: set api_image and frontend_image to the references Masterly gives you instead."
  }
}

variable "release_ring" {
  type        = string
  default     = "stable"
  nullable    = false
  description = "The release ring this install declares (ADR 0107): \"canary\", \"beta\" or \"stable\" (the default). Reported in the deployment_stamp output and nowhere else: it changes no image and no resource. It is a declaration, not a permission: your licence's release_ring claim decides which releases the install may run, and the module does not check this input against it. It is not release_channel, which picks the stable or previous image pair from MANIFEST.json."

  validation {
    condition     = contains(["canary", "beta", "stable"], var.release_ring)
    error_message = "release_ring must be \"canary\", \"beta\" or \"stable\", in lowercase. It is not release_channel: \"previous\" is a channel, not a ring."
  }
}

variable "registry_location" {
  type        = string
  default     = null
  description = "Login server of the registry the apps pull from, as a bare host with an optional port and no scheme or path (e.g. masterly.azurecr.io, or your own registry such as acme.azurecr.io). Null (the default) is Masterly's registry, masterly.azurecr.io, when registry_credential_mode, a pull credential or acr_id is set; with none of them it renders no registry block on the apps, which then pull public images (the default image references still name masterly.azurecr.io/release/<role>). Replaces acr_login_server; set one of the two, not both. An empty string is refused: omit the input instead."

  validation {
    condition     = var.registry_location == null ? true : can(regex("^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+|localhost)(?::[0-9]{1,5})?$", var.registry_location))
    error_message = "registry_location must be a lowercase registry host such as masterly.azurecr.io (a port is allowed), with no scheme, path or trailing slash. To pull public images with no registry block, omit it instead of setting \"\"."
  }

  validation {
    condition     = var.registry_location == null || var.acr_login_server == null
    error_message = "Set registry_location or the deprecated acr_login_server, not both. Move the value to registry_location and remove acr_login_server."
  }
}

variable "acr_login_server" {
  type        = string
  default     = null
  description = "Deprecated: use registry_location. The registry the install pulls images from. Null (the default) defers to registry_location; an empty string renders no registry block on the apps (public images only), which registry_location expresses by being omitted."
}

variable "registry_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Deprecated: use registry_token. The pull principal's client secret (ADR 0067), stored as the Container App secret registry-password on every app."
}

variable "registry_identity_id" {
  type        = string
  default     = null
  description = "Resource ID of an existing user-assigned managed identity that every Container App and Container Apps job this module creates (ca-api, ca-frontend, ca-workers, caj-migrate, and ca-edge when its image is on the install's registry) pulls its image with, instead of its own identity. One pull identity per registry, created and granted pull once, out of band: the module attaches it to each of them beside the app's own identity and names it in the registry block, and that is all. It writes no role assignment for it, whatever acr_id says; grant it pull on your registry yourself (AcrPull, or under the registry's repository permissions mode its repository reader role, directly or through a group). Each app still runs as its own identity: every grant, AZURE_CLIENT_ID, Key Vault reference, scale rule and database role stays there. With it set, the module writes no AcrPull for the apps' own identities either, because none of them pulls; acr_id is then used only for the registry's private endpoint (registry_private_endpoint), and ca-workers runs as its own identity on an install without the Key Vault too, where it would otherwise stay on the apps identity until a pull grant could reach it. Pulls as an identity, so it is used in the managed_identity and customer_registry modes; the plan refuses it with registry_credential_mode = \"token\", a registry_token or the deprecated registry_username and registry_password, and with acr_login_server = \"\" (no registry block, nothing pulls). Set without registry_location or a mode, the registry is Masterly's, as when a mode is set. Null (the default) pulls each app as its own identity, as before this input existed."

  validation {
    condition     = var.registry_identity_id == null ? true : can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$", var.registry_identity_id))
    error_message = "registry_identity_id must be the resource ID of a user-assigned managed identity: /subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>."
  }

  validation {
    condition     = var.registry_identity_id == null || (var.registry_credential_mode != "token" && nonsensitive(var.registry_token == null) && var.registry_username == null)
    error_message = "registry_identity_id pulls as an identity, and the token mode pulls with a credential: set one or the other. Remove registry_identity_id, or remove registry_token (or registry_username and registry_password) and registry_credential_mode = \"token\"."
  }

  validation {
    condition     = var.registry_identity_id == null || var.acr_login_server != ""
    error_message = "registry_identity_id needs a registry to pull from, and acr_login_server = \"\" renders none. Set registry_location to the registry the identity pulls from, or remove registry_identity_id."
  }
}
