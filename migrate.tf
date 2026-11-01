# The migrate job (ADR 0120 §6; ADR 0065, 0086 and 0108 as amended 2026-10-23): schema migrations
# and the databases of new Masterly Environments are created here, in a Container Apps job that
# runs as its own identity, and no longer by ca-api and ca-workers at start. Those two only check
# the schema stamps (MASTERLY_MIGRATIONS = job, main.tf), and are not ready until the job has
# brought them to head.
#
# How the job starts:
#
#   at apply      azapi_resource_action.migrate_start starts one execution. It is replaced, and so
#                 starts another, whenever the resolved api image changes. ca-api and ca-workers
#                 depend on it, so the execution has started before either app is created or
#                 updated. The action returns once the execution has started, not when it ends:
#                 ca-api's readiness probe (/readyz) and revision_mode Single keep traffic on the
#                 previous revision until the stamps reach head.
#   on a schedule migrate_job_schedule. Each run also picks up the provisioning runs a new
#                 Environment leaves pending, which is how a new Environment's database is made.
#
# The two can overlap. The application's migration lock serialises them.
#
# The job's identity (main.tf, module.migrate_identity) is the install's most privileged database
# principal, and the job wakes on a schedule. So it carries only what migrating needs: the
# database URLs, how to authenticate, and the CA bundle when one is set. It is attached to no
# Container App, and its grants are AcrPull (acr_pull_migrate) and Key Vault Secrets User on each
# of its own secrets (kv_secrets_user_migrate), nothing else.

variable "migrate_job_schedule" {
  type        = string
  default     = "*/5 * * * *"
  description = "When the migrate job (caj-migrate) runs on its own, as a five-field cron expression in UTC. Each run applies any pending schema migration and creates the database of each Masterly Environment waiting to be provisioned, so this is the longest a new Environment waits for its database. A run with nothing to do checks and exits. Default every five minutes. The job also runs once at every apply that changes the api image, whatever this says."

  validation {
    condition     = can(regex("^\\S+( \\S+){4}$", var.migrate_job_schedule))
    error_message = "migrate_job_schedule must be a five-field cron expression separated by single spaces, for example \"*/5 * * * *\" (every five minutes)."
  }
}

locals {
  # The migrate job's Postgres role: the migrate identity's Entra role on "entra" (its
  # administrator is in entra-auth.tf), masterly_admin on "password". Never local.database_role,
  # which is the apps'.
  migrate_database_role = local.database_entra ? module.migrate_identity.name : "masterly_admin"

  # On BYO-DB the admin DSN when one is given, else the same DSN the apps get. Only the job
  # carries either (migrate_secret_names).
  migrate_database_url = var.external_database_url != null ? coalesce(var.external_database_admin_url, var.external_database_url) : module.postgres_connection_urls_migrate[0].pooler_url

  # Null on BYO-DB, where postgres_pgbouncer is refused and the secret is never named.
  migrate_database_direct_url = var.external_database_url != null ? null : module.postgres_connection_urls_migrate[0].direct_url

  migrate_secret_names = concat(
    ["migrate-database-url"],
    var.postgres_pgbouncer ? ["migrate-database-direct-url"] : [],
    local.registry_secret_names,
    var.ca_bundle_pem != null ? ["ca-bundle-pem"] : [],
  )

  migrate_secrets = { for name in local.migrate_secret_names : name => local.secret_values[name] }

  migrate_env = merge(
    var.mode == "production" ? { MASTERLY_CONTROLPLANE_STORE = "postgres" } : {},
    var.postgres_pgbouncer ? { MASTERLY_DATABASE_POOLER = "transaction" } : {},
    local.ca_bundle_env,
    # The token is minted for the migrate identity, never the apps'.
    local.database_entra ? {
      MASTERLY_DATABASE_AUTH = "entra"
      AZURE_CLIENT_ID        = module.migrate_identity.client_id
    } : {},
  )

  migrate_env_secret_refs = merge(
    { MASTERLY_DATABASE_URL = "migrate-database-url" },
    var.postgres_pgbouncer ? { MASTERLY_DATABASE_DIRECT_URL = "migrate-database-direct-url" } : {},
  )
}

resource "azurerm_container_app_job" "migrate" {
  name                         = "caj-migrate"
  location                     = var.location
  resource_group_name          = azurerm_resource_group.aca.name
  container_app_environment_id = module.aca_env.id

  # An execution that has not finished in 30 minutes is stopped; the next one starts over.
  replica_timeout_in_seconds = 1800
  replica_retry_limit        = 0

  identity {
    type         = "UserAssigned"
    identity_ids = [module.migrate_identity.id]
  }

  schedule_trigger_config {
    cron_expression          = var.migrate_job_schedule
    parallelism              = 1
    replica_completion_count = 1
  }

  # The apps' registry block (modules/aca-container-app), with the migrate identity.
  dynamic "registry" {
    for_each = local.registry_server == "" ? [] : [1]
    content {
      server               = local.registry_server
      identity             = local.registry_username == null ? module.migrate_identity.id : null
      username             = local.registry_username
      password_secret_name = local.registry_password_secret_name
    }
  }

  dynamic "secret" {
    for_each = local.migrate_value_secrets
    content {
      name  = secret.key
      value = secret.value
    }
  }

  dynamic "secret" {
    for_each = local.migrate_vault_secret_refs
    content {
      name                = secret.key
      identity            = secret.value.identity_id
      key_vault_secret_id = secret.value.kv_secret_id
    }
  }

  template {
    # The CA bundle mount the apps get (main.tf, ca_bundle_secret_file_mounts): the job connects
    # to the same database and must trust the same CA.
    dynamic "volume" {
      for_each = local.ca_bundle_secret_file_mounts
      content {
        name         = "${volume.key}-vol"
        storage_type = "EmptyDir"
      }
    }

    dynamic "init_container" {
      for_each = local.ca_bundle_secret_file_mounts
      content {
        name    = "${init_container.key}-init"
        image   = local.api_image
        command = ["/bin/sh", "-c", "umask 077 && cat /etc/ssl/certs/ca-certificates.crt > \"${init_container.value.mount_path}/${init_container.value.file_name}\" && printf '%s\n' \"$MASTERLY_FILE_CONTENT\" >> \"${init_container.value.mount_path}/${init_container.value.file_name}\""]

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
      name    = "migrate"
      image   = local.api_image
      command = ["python", "-m", "masterly_app.apps.migrate"]
      cpu     = 0.5
      memory  = "1Gi"

      dynamic "env" {
        for_each = local.migrate_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.migrate_env_secret_refs
        content {
          name        = env.key
          secret_name = env.value
        }
      }

      dynamic "volume_mounts" {
        for_each = local.ca_bundle_secret_file_mounts
        content {
          name = "${volume_mounts.key}-vol"
          path = volume_mounts.value.mount_path
        }
      }
    }
  }

  tags = local.tags

  lifecycle {
    # Azure back-fills "Consumption" in a VNet-integrated environment, as on the apps.
    ignore_changes = [workload_profile_name]
  }

  # The grants must land before the first pull and the first secret read, as on the frontend
  # (main.tf): the job depends on its identity, not on the role assignments on it.
  depends_on = [
    azurerm_role_assignment.acr_pull_migrate,
    azurerm_role_assignment.kv_secrets_user_migrate,
    azurerm_private_endpoint.registry,
    azurerm_private_dns_zone_virtual_network_link.registry,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
  ]
}

# What replaces the start action: the image the job runs, after the channel and api_image are
# resolved. A new image is a new release, whose migrations must run before the apps roll.
resource "terraform_data" "migrate_image" {
  input = local.api_image
}

# Starts one execution of the job at apply (Microsoft.App/jobs start).
resource "azapi_resource_action" "migrate_start" {
  type        = "Microsoft.App/jobs@2025-01-01"
  resource_id = azurerm_container_app_job.migrate.id
  action      = "start"
  method      = "POST"

  # The execution connects at once: the database, its network path and, on "entra", the
  # migrate identity's administrator must exist first.
  depends_on = [
    azurerm_postgresql_flexible_server_configuration.pgbouncer,
    azurerm_network_security_group.private_endpoints,
    azurerm_private_endpoint.postgres,
    azurerm_private_dns_zone_virtual_network_link.postgres,
    azurerm_postgresql_flexible_server_active_directory_administrator.migrate,
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.migrate_image]
  }
}

output "migrate_job_name" {
  value       = azurerm_container_app_job.migrate.name
  description = "Name of the migrate Container Apps job (caj-migrate), in the apps resource group. `az containerapp job execution list` shows its runs."
}
