# Vendored from masterly-platform-iac/modules/aca-container-app; SELF-HOSTED EXTENSIONS:
# value-based secrets, env-from-secret references, HTTP probes.

locals {
  # Secret NAMES only. keys() of a sensitive map carries the mark, and a mark on a
  # precondition condition or an output is an error — the names are not the material, so
  # they are unmarked here once and reused.
  value_secret_names = nonsensitive(keys(var.secrets))
  secret_names       = concat(local.value_secret_names, keys(var.secret_refs))
}

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

  # Key Vault-backed secrets: the app stores the reference and ACA resolves the value with
  # `identity`. A caller passes a name through EITHER this map or var.secrets, never both —
  # ACA has one secret namespace and a duplicate name is rejected at apply, so the
  # precondition below refuses it at plan.
  dynamic "secret" {
    for_each = var.secret_refs
    content {
      name                = secret.key
      identity            = secret.value.identity_id
      key_vault_secret_id = secret.value.kv_secret_id
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

    # SELF-HOSTED EXTENSION: secret-backed file mounts (MAS-446).
    #
    # `azurerm_container_app`'s `volume` block supports only `storage_type = "AzureFile"` and
    # `"EmptyDir"` (checked against the provider schema, 4.61.0 through 4.81.0 — there is no
    # `Secret` storage type here, unlike the raw Azure Container Apps API). So an app secret
    # cannot be mounted as a file directly, the way it can be sourced into an env var below.
    # `AzureFile` would need a whole storage account + share + environment-storage binding for
    # one small PEM file; this module gets the same result with what it already has: an
    # EMPTY EmptyDir volume, shared between the container below and a short-lived INIT
    # CONTAINER that writes the file from the named secret before the real container starts.
    # ACA runs every init container to completion, in order, before starting the app
    # container in the same revision — so the file exists at the mount path from the app
    # container's first instruction, on every replica start (a cold start writes it fresh;
    # nothing here is a one-time seed). It reuses this app's own image (already pulled, under
    # the same registry credentials as the app container) rather than adding a dependency on a
    # generic utility image — every image this module deploys ships a POSIX shell.
    dynamic "volume" {
      for_each = var.secret_file_mounts
      content {
        name         = "${volume.key}-vol"
        storage_type = "EmptyDir"
      }
    }

    dynamic "init_container" {
      for_each = var.secret_file_mounts
      content {
        name  = "${init_container.key}-init"
        image = var.image

        # umask 077: the file is created owner-read/write only. This is safe -- readable by the
        # app container that mounts the same volume -- only because that container runs the
        # SAME image (var.image, above): same USER, same UID, so "owner-only" still means the
        # process that needs to read it. A future caller of this block that swapped the init
        # container for a generic utility image (busybox, say, typically running as root) would
        # produce a file the app container's non-root process cannot read, silently, the first
        # time this file mount is actually needed -- worth remembering if that image ever stops
        # being var.image.
        #
        # printf, not echo -- echo's handling of a leading "-" or backslash sequences in the
        # content is shell-dependent, printf's is not, and %s never reinterprets the value.
        #
        # prepend_image_ca_bundle (MAS-446): true makes the write ADDITIVE -- the image's own
        # CA trust store goes into the file first, then the secret's content is appended, so the
        # result trusts both the publicly-trusted roots the image already ships and whatever the
        # secret adds, rather than the secret's content replacing the image's trust store
        # outright. This is what keeps ca_bundle_pem (see variables.tf, root) from being a
        # foot-gun: without it, setting ca_bundle_pem to an internal CA would make every OTHER
        # outbound TLS call the install makes -- telemetry, licence refresh, ACS email --
        # start failing certificate verification the moment the apply landed, because
        # SSL_CERT_FILE would name a file that no longer had those roots in it at all.
        command = [
          "/bin/sh", "-c",
          init_container.value.prepend_image_ca_bundle ? (
            "umask 077 && cat /etc/ssl/certs/ca-certificates.crt > \"${init_container.value.mount_path}/${init_container.value.file_name}\" && printf '%s\n' \"$MASTERLY_FILE_CONTENT\" >> \"${init_container.value.mount_path}/${init_container.value.file_name}\""
            ) : (
            "umask 077 && printf '%s\n' \"$MASTERLY_FILE_CONTENT\" > \"${init_container.value.mount_path}/${init_container.value.file_name}\""
          )
        ]

        env {
          name        = "MASTERLY_FILE_CONTENT"
          secret_name = init_container.value.secret_name
        }

        volume_mounts {
          name = "${init_container.key}-vol"
          path = init_container.value.mount_path
        }
      }
    }

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

      # SELF-HOSTED EXTENSION: secret-backed file mounts (MAS-446) — the same EmptyDir volume
      # the init container above just wrote the file into.
      dynamic "volume_mounts" {
        for_each = var.secret_file_mounts
        content {
          name = "${volume_mounts.key}-vol"
          path = volume_mounts.value.mount_path
        }
      }

      # SELF-HOSTED EXTENSION: HTTP probes. Tolerances are inputs on both; null keeps Azure's
      # defaults (1s timeout, 3 failures). The liveness block has no success threshold.
      dynamic "liveness_probe" {
        for_each = var.liveness_probe_path != null ? [1] : []
        content {
          path      = var.liveness_probe_path
          port      = var.ingress_target_port
          transport = "HTTP"

          initial_delay           = var.liveness_probe_initial_delay
          interval_seconds        = var.liveness_probe_interval_seconds
          timeout                 = var.liveness_probe_timeout
          failure_count_threshold = var.liveness_probe_failure_count_threshold
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
      condition     = alltrue([for s in keys(var.env_secret_refs) : contains(local.secret_names, var.env_secret_refs[s])])
      error_message = "Every env_secret_refs value must name a key of var.secrets or var.secret_refs."
    }

    precondition {
      condition     = alltrue([for m in values(var.secret_file_mounts) : contains(local.secret_names, m.secret_name)])
      error_message = "Every secret_file_mounts[*].secret_name must name a key of var.secrets or var.secret_refs."
    }

    # One namespace: ACA rejects two secrets with the same name, and a caller that moved a
    # secret to the vault without removing the value-based copy would otherwise fail at apply
    # with an Azure error that names neither map.
    precondition {
      condition     = length(setintersection(keys(var.secret_refs), local.value_secret_names)) == 0
      error_message = "A secret name may appear in var.secrets or var.secret_refs, not both."
    }

    # Upstream parity: ACA resolves a vault reference with the named identity, which must be
    # attached to the app.
    precondition {
      condition     = alltrue([for s in values(var.secret_refs) : contains(var.user_assigned_identity_ids, s.identity_id)])
      error_message = "Every secret_refs[*].identity_id must be one of user_assigned_identity_ids."
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
      condition     = var.registry_username == null || contains(local.secret_names, coalesce(var.registry_password_secret_name, "-"))
      error_message = "registry_username requires registry_password_secret_name naming a key of var.secrets or var.secret_refs."
    }
  }
}
