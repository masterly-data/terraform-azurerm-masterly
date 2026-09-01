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

# SELF-HOSTED EXTENSION: env vars sourced from app secrets.
variable "env_secret_refs" {
  type        = map(string)
  default     = {}
  description = "Environment variables sourced from app secrets: env var name => secret name (a key of var.secrets)."
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

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to the Container App."
}
