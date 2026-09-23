# Vendored from masterly-platform-iac/modules/aca-container-app and extended for the
# self-hosted install: value-based secrets (+ env secret references) and HTTP probes —
# the upstream copy defers both. Divergences are marked SELF-HOSTED EXTENSION.

variable "name" {
  type        = string
  description = "Name of the Container App."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group that holds the Container App."
}

variable "environment_id" {
  type        = string
  description = "Resource ID of the Container App Environment."
}

variable "image" {
  type        = string
  description = "Fully-qualified container image reference (registry/repo:tag). Seeds the image on create only — lifecycle.ignore_changes hands the running tag to CD thereafter."
}

variable "acr_login_server" {
  type        = string
  default     = ""
  description = "Registry login server for managed-identity image pull. Empty disables the registry block (public image)."
}

variable "user_assigned_identity_ids" {
  type        = list(string)
  default     = []
  description = "User-assigned managed identity resource IDs attached to the app. The first is used for registry pull."
}

variable "revision_mode" {
  type        = string
  default     = "Single"
  description = "Revision mode: Single or Multiple."

  validation {
    condition     = contains(["Single", "Multiple"], var.revision_mode)
    error_message = "revision_mode must be either Single or Multiple."
  }
}

variable "cpu" {
  type        = number
  default     = 0.5
  description = "CPU cores per replica."
}

variable "memory" {
  type        = string
  default     = "1Gi"
  description = "Memory per replica (e.g. \"1Gi\")."
}

variable "min_replicas" {
  type        = number
  default     = 1
  description = "Minimum replica count. Default 1: the self-hosted apps hold in-memory ephemeral state (session registry in demo profile) that scale-to-zero would drop."
}

variable "max_replicas" {
  type        = number
  default     = 3
  description = "Maximum replica count."
}

# SELF-HOSTED EXTENSION: ingress-less apps (the workers loop).
variable "ingress_enabled" {
  type        = bool
  default     = true
  description = "Create the ingress block. False = no ingress at all (a background worker); the ingress_* inputs are then ignored."
}

# SELF-HOSTED EXTENSION: command override (same image, different process).
variable "command" {
  type        = list(string)
  default     = null
  description = "Container command override (e.g. [\"python\", \"-m\", \"masterly_app.workers\"]). Null keeps the image entrypoint."
}

variable "ingress_external" {
  type        = bool
  default     = true
  description = "Expose ingress to the public internet."
}

variable "ingress_target_port" {
  type        = number
  default     = null
  description = "Container port that ingress routes to (required when ingress_enabled)."
}

variable "ingress_allow_insecure" {
  type        = bool
  default     = false
  description = "Allow plain-HTTP connections (otherwise redirect to HTTPS)."
}

variable "ingress_allowed_ip_security_restrictions" {
  type = list(object({
    name             = string
    ip_address_range = string
    action           = string
  }))
  default     = []
  description = "Ingress IP allow/deny rules. An empty list applies no restrictions (open to all)."
}

# SELF-HOSTED EXTENSION: credential-based registry auth (ADR 0067).
variable "registry_username" {
  type        = string
  default     = null
  description = "Registry username (service principal appId or token name) for credential-based pull. Null = managed-identity pull via the first user-assigned identity."
}

variable "registry_password_secret_name" {
  type        = string
  default     = null
  description = "Name of the Container App secret (a key of var.secrets) holding the registry password. Required when registry_username is set."
}

variable "env" {
  type        = map(string)
  default     = {}
  description = "Plain (non-secret) environment variables: name => value."
}

# SELF-HOSTED EXTENSION: value-based app secrets (stored encrypted in the Container App).
variable "secrets" {
  type        = map(string)
  default     = {}
  sensitive   = true
  description = "Value-based Container App secrets: secret name => value. For installs without a Key Vault; values live encrypted in the app, never in env directly."
}

# Key Vault-backed app secrets (upstream parity: masterly-platform-iac's copy of this module
# carries the same input). The app holds a REFERENCE, not the value: ACA resolves it from the
# vault with the named user-assigned identity, so `az containerapp secret show` (and anything
# else with containerApps/listSecrets, which Contributor has) returns the vault URL rather than
# the material. Data-plane read is then a Key Vault RBAC grant, which Contributor does not
# carry.
#
# Not `sensitive`, deliberately: these are resource IDs, not values — marking them would hide
# the wiring from the plan and from `terraform test`, which is the only thing that can catch a
# reference pointed at the wrong vault.
variable "secret_refs" {
  type = map(object({
    kv_secret_id = string
    identity_id  = string
  }))
  default     = {}
  description = "Key Vault-backed Container App secrets: secret name => { kv_secret_id, identity_id }. identity_id must be one of user_assigned_identity_ids. A versionless kv_secret_id lets ACA pick up a rotation on its own (it re-reads within 30 minutes and restarts active revisions); a versioned one pins the value until the next apply. Names must not collide with var.secrets."
}

# SELF-HOSTED EXTENSION: env vars sourced from app secrets.
variable "env_secret_refs" {
  type        = map(string)
  default     = {}
  description = "Environment variables sourced from app secrets: env var name => secret name (a key of var.secrets or var.secret_refs)."
}

# SELF-HOSTED EXTENSION: secret-backed file mounts (MAS-446). `azurerm_container_app` has no
# Secret-backed volume type (checked against the provider schema; see the comment on the
# `volume`/`init_container` blocks in main.tf for why), so a named entry here becomes an
# EmptyDir volume, an init container that writes the named secret's value into it before the
# app container starts, and a mount of that volume on the app container. Nothing about this
# implies the content is confidential — it is simply the mechanism available for landing a
# value on disk without provisioning a storage account, and a CA bundle is public material
# carried this way for exactly that reason.
variable "secret_file_mounts" {
  type = map(object({
    mount_path  = string
    file_name   = string
    secret_name = string
    # Default false: the file is the secret's content and nothing else. true makes the write
    # ADDITIVE — the init container writes the image's own CA trust store
    # (/etc/ssl/certs/ca-certificates.crt) first and appends the secret's content after it,
    # instead of the secret's content replacing the file outright. This exists for exactly one
    # caller today (ca_bundle_pem, below) and is named for that: it is not a generic "prepend
    # some other file" knob, it is specifically the image's CA bundle, because that is the only
    # file this module ever needs to add to rather than replace.
    prepend_image_ca_bundle = optional(bool, false)
  }))
  default     = {}
  description = "Named file mounts: each key identifies one EmptyDir volume + init container pair. mount_path is the absolute directory mounted on the app container (and on the init container, which writes into it); file_name is the file written inside that directory; secret_name names the app secret (a key of var.secrets or var.secret_refs) whose value becomes the file's content. prepend_image_ca_bundle (default false) writes the image's own /etc/ssl/certs/ca-certificates.crt ahead of the secret's content instead of replacing it — an additive trust store rather than a replacement one. A caller wanting one file declares one entry."
}

# SELF-HOSTED EXTENSION: HTTP probes.
variable "liveness_probe_path" {
  type        = string
  default     = null
  description = "HTTP GET path for the liveness probe (null disables; ACA then uses its defaults)."
}

variable "readiness_probe_path" {
  type        = string
  default     = null
  description = "HTTP GET path for the readiness probe (null disables)."
}

# Readiness tolerances. Null leaves Azure's default, which is what every probe in this module
# ran before these knobs existed — an unset caller plans unchanged.
#
# They exist because callers that DECLARE a probe need them wide — both of them do. Declaring an HTTP readiness probe is not the
# safe half of a trade. Azure documents the readiness defaults that apply when no probe is
# declared as TCP with a 5s timeout and a failure threshold of 48, while the provider's defaults
# for a DECLARED probe are a 1s timeout and 3 failures. So a probe added without widening these
# is stricter than what it replaces — and ACA restarts a replica that keeps failing readiness,
# so the difference between a slow dependency and a restart loop is the budget set by the caller.
#
# (Azure's own pages disagree on whether those no-probe defaults come from the platform or are
# added by the portal on create. The numbers are consistent across them and the direction of the
# trade is the same either way, so this deliberately does not depend on which is true.)
variable "readiness_probe_initial_delay" {
  type        = number
  default     = null
  description = "Seconds after container start before the first readiness probe (0-60)."
}

variable "readiness_probe_interval_seconds" {
  type        = number
  default     = null
  description = "Seconds between readiness probes (1-240)."
}

variable "readiness_probe_timeout" {
  type        = number
  default     = null
  description = "Seconds before a readiness probe attempt counts as failed (1-240). Keep it at or below readiness_probe_interval_seconds."
}

variable "readiness_probe_failure_count_threshold" {
  type        = number
  default     = null
  description = "Consecutive failed readiness probes before the replica is pulled out of rotation and restarted (1-48). initial_delay + threshold x interval is the budget a cold dependency has to answer in."
}

variable "readiness_probe_success_count_threshold" {
  type        = number
  default     = null
  description = "Consecutive successful readiness probes before the replica takes traffic (1-10). 1 keeps a healthy cold wake from paying extra probe intervals."
}

# Liveness tolerances. Null leaves Azure's default, so every caller that sets none plans
# unchanged. A DECLARED liveness probe defaults to a 1s timeout, a 10s interval and 3
# failures, and a failing liveness probe always restarts the container — so at the defaults a
# process that is merely slow, or still starting, for about 30 seconds is killed and started
# again. A caller that declares a liveness probe should size these deliberately.
#
# There is no success threshold here: the provider does not expose one on the liveness block,
# and one success is all a liveness probe ever needs.
variable "liveness_probe_initial_delay" {
  type        = number
  default     = null
  description = "Seconds after container start before the first liveness probe (0-60)."
}

variable "liveness_probe_interval_seconds" {
  type        = number
  default     = null
  description = "Seconds between liveness probes (1-240)."
}

variable "liveness_probe_timeout" {
  type        = number
  default     = null
  description = "Seconds before a liveness probe attempt counts as failed (1-240). Keep it at or below liveness_probe_interval_seconds."
}

variable "liveness_probe_failure_count_threshold" {
  type        = number
  default     = null
  description = "Consecutive failed liveness probes before the container is restarted (1-30). initial_delay + threshold x interval is how long a process may go unanswered, including while it is still starting, before it is restarted."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the Container App."
}
