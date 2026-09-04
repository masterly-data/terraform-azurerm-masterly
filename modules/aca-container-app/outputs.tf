output "id" {
  value       = azurerm_container_app.this.id
  description = "Resource ID of the Container App."
}

output "name" {
  value       = azurerm_container_app.this.name
  description = "Name of the Container App."
}

# Informational only. Do NOT wire app-to-app traffic to this: Azure has been observed to
# report an internal app's fqdn in the external form, and terraform reads it back as drift
# ("changed outside of Terraform"). Address another app in the same environment by `name`.
output "fqdn" {
  value       = try(azurerm_container_app.this.ingress[0].fqdn, null)
  description = "Ingress FQDN as Azure currently reports it. Null when ingress is disabled. Not stable enough to address the app with — use `name` for in-environment calls."
}

# Environment variable NAMES only, never their values: this exists so the module's posture is
# assertable in `terraform test` (does the dev binding carry its opt-in? does oidc not?), and a
# value here would put whatever a caller passed as plain env into state and test output.
output "env_names" {
  value       = sort(keys(var.env))
  description = "Names of the plain (non-secret) environment variables set on the container."
}

# Readiness posture as configured — the same reason env_names exists: `terraform test` must be
# able to assert the gate AND its tolerances, because a gate that outlasts nothing is worse
# than no gate. Config values, not resource attributes, so it stays known at plan time.
output "readiness_probe" {
  value = var.readiness_probe_path == null ? null : {
    path                    = var.readiness_probe_path
    initial_delay           = var.readiness_probe_initial_delay
    interval_seconds        = var.readiness_probe_interval_seconds
    timeout                 = var.readiness_probe_timeout
    failure_count_threshold = var.readiness_probe_failure_count_threshold
    success_count_threshold = var.readiness_probe_success_count_threshold
  }
  description = "The readiness gate as configured, or null when the app has none. A null tolerance means Azure's default applies."
}

output "ingress_external" {
  # Whether this app answers beyond the Container App Environment. A root that reasons about
  # who can reach an app — or a test that pins it — cannot read it off the resource, because
  # `ingress` is a dynamic block that is absent entirely on an app with no ingress.
  value       = var.ingress_enabled ? var.ingress_external : false
  description = "Whether the app has ingress beyond the environment. False when it has no ingress at all."
}

output "ingress_allowed_ip_ranges" {
  # The CIDRs actually applied to this app's ingress. Exposed so a caller can PIN the
  # allowlist rather than the intent: asserting that a flag is set proves nothing about
  # whether the restrictions reached the app, and an empty list on an external app means
  # unrestricted in Azure.
  value       = [for r in var.ingress_allowed_ip_security_restrictions : r.ip_address_range]
  description = "CIDRs allowed to reach this app's ingress. Empty means unrestricted when the app is external."
}
