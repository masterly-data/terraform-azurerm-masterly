# Vendored from masterly-platform-iac/modules/aca-container-app; SELF-HOSTED EXTENSIONS:
# value-based secrets, env-from-secret references, HTTP probes.

resource "azurerm_container_app" "this" {
  name                         = var.name
  resource_group_name          = var.resource_group_name
  container_app_environment_id = var.environment_id
  revision_mode                = var.revision_mode

  dynamic "identity" {
    for_each = length(var.user_assigned_identity_ids) > 0 ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = var.user_assigned_identity_ids
    }
  }

  # SELF-HOSTED EXTENSION: credential-based registry auth (ADR 0067) — a per-customer
  # service principal pulling cross-tenant from Masterly's registry. Managed identity
  # remains the same-tenant default (own-ACR mirror / Masterly-operated installs).
  dynamic "registry" {
    for_each = var.acr_login_server != "" ? [1] : []
    content {
      server               = var.acr_login_server
      identity             = var.registry_username == null ? var.user_assigned_identity_ids[0] : null
      username             = var.registry_username
      password_secret_name = var.registry_username != null ? var.registry_password_secret_name : null
    }
  }

  # SELF-HOSTED EXTENSION: value-based secrets.
  dynamic "secret" {
    for_each = var.secrets
    content {
      name  = secret.key
      value = secret.value
    }
  }

  # SELF-HOSTED EXTENSION: ingress is optional — a worker app has none.
  dynamic "ingress" {
    for_each = var.ingress_enabled ? [1] : []
    content {
      external_enabled           = var.ingress_external
      target_port                = var.ingress_target_port
      allow_insecure_connections = var.ingress_allow_insecure

      traffic_weight {
        latest_revision = true
        percentage      = 100
      }

      dynamic "ip_security_restriction" {
        for_each = var.ingress_allowed_ip_security_restrictions
        content {
          name             = ip_security_restriction.value.name
          ip_address_range = ip_security_restriction.value.ip_address_range
          action           = ip_security_restriction.value.action
        }
      }
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name    = var.name
      image   = var.image
      cpu     = var.cpu
      memory  = var.memory
      command = var.command # SELF-HOSTED EXTENSION: null keeps the image entrypoint

      dynamic "env" {
        for_each = var.env
        content {
          name  = env.key
          value = env.value
        }
      }

      # SELF-HOSTED EXTENSION: env sourced from app secrets.
      dynamic "env" {
        for_each = var.env_secret_refs
        content {
          name        = env.key
          secret_name = env.value
        }
      }

      # SELF-HOSTED EXTENSION: HTTP probes.
      dynamic "liveness_probe" {
        for_each = var.liveness_probe_path != null ? [1] : []
        content {
          path      = var.liveness_probe_path
          port      = var.ingress_target_port
          transport = "HTTP"
        }
      }

      # Tolerances are inputs because one caller needs them wide: the frontend's readiness gate
      # calls the api, and on a scale-to-zero install that call can be waiting on ACA to
      # activate a backend replica. Null keeps Azure's defaults (1s timeout, 3 failures).
      dynamic "readiness_probe" {
        for_each = var.readiness_probe_path != null ? [1] : []
        content {
          path      = var.readiness_probe_path
          port      = var.ingress_target_port
          transport = "HTTP"

          initial_delay           = var.readiness_probe_initial_delay
          interval_seconds        = var.readiness_probe_interval_seconds
          timeout                 = var.readiness_probe_timeout
          failure_count_threshold = var.readiness_probe_failure_count_threshold
          success_count_threshold = var.readiness_probe_success_count_threshold
        }
      }
    }
  }

  tags = var.tags

  lifecycle {
    # CD (the app repos' release.yml -> `az containerapp update --image`) is the sole
    # owner of the running image tag: Terraform seeds it on create, then ignores drift,
    # so an apply never rolls a CD-pushed revision back to the seed tag.
    # workload_profile_name: Azure back-fills "Consumption" on apps in VNet-integrated
    # environments (API-side drift) — never try to strip it.
    ignore_changes = [template[0].container[0].image, workload_profile_name]

    precondition {
      condition     = alltrue([for s in keys(var.env_secret_refs) : contains(keys(var.secrets), var.env_secret_refs[s])])
      error_message = "Every env_secret_refs value must name a key of var.secrets."
    }

    precondition {
      condition = (
        var.acr_login_server == "" ||
        var.registry_username != null ||
        length(var.user_assigned_identity_ids) > 0
      )
      error_message = "acr_login_server requires managed-identity pull (user_assigned_identity_ids) or credential pull (registry_username)."
    }

    precondition {
      condition     = var.registry_username == null || contains(keys(var.secrets), coalesce(var.registry_password_secret_name, "-"))
      error_message = "registry_username requires registry_password_secret_name naming a key of var.secrets."
    }
  }
}
