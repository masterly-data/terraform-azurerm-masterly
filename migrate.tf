# The migrate job (ADR 0120 §6; ADR 0065, 0086 and 0108 as amended 2026-10-23), opt-in with
# migrations = "job": schema migrations and the databases of new Masterly Environments are created
# here, in a Container Apps job that runs as its own identity, and no longer by ca-api and
# ca-workers at start. Those two then carry MASTERLY_MIGRATIONS = job (main.tf), which tells the
# api image to check the schema stamps instead of migrating. The migrate entry point and that
# setting are in no backend release up to v0.135.0, so the default, "start", creates none of this
# and leaves the apps migrating at start as before (README, "The migrate job").
#
# How the job starts:
#
#   at install    azapi_resource_action.migrate_start starts one execution on the seeded image.
#                 ca-api and ca-workers depend on it, so it has started before either app is
#                 created. It returns once the execution has started, not when it ends. The
#                 action is replaced when the resolved api image changes, but Terraform ignores
#                 image drift on the job as on the apps, so that run uses the job's current image.
#   at a release  CD owns the running image (ADR 0086 as amended 2026-10-23): it moves caj-migrate
#                 to the release's digest, starts an execution, waits for it to succeed, and only
#                 then rolls ca-api and ca-workers to the same digest. Terraform takes no part.
#   on a schedule migrate_job_schedule. The release's migrate role is required to pick up the
#                 provisioning runs a new Environment leaves pending.
#
# Runs can overlap; the release's migrate role is required to serialise them (a migration lock).
#
# The job's identity (main.tf, module.migrate_identity) is the install's most privileged database
# principal, and the job wakes on a schedule. So it carries only what migrating needs: the
# database URLs, how to authenticate, and the CA bundle when one is set. It is attached to no
# Container App, and its grants are AcrPull (acr_pull_migrate) and Key Vault Secrets User on each
# of its own secrets (kv_secrets_user_migrate), nothing else.

variable "migrations" {
  type        = string
  default     = "start"
  description = "Where schema migrations run. \"start\" (default): ca-api and ca-workers migrate at start, as before, and the module creates no migrate job. \"job\": the migrate Container Apps job (caj-migrate) runs them as its own identity, id-<prefix>-migrate, and ca-api and ca-workers get MASTERLY_MIGRATIONS=job. \"job\" needs an api image from a backend release later than v0.135.0, which has the migrate entry point and honours MASTERLY_MIGRATIONS; an earlier image cannot run the job."

  validation {
    condition     = contains(["start", "job"], var.migrations)
    error_message = "migrations must be \"start\" (the apps migrate at start; the default) or \"job\" (the migrate job does; needs a backend release later than v0.135.0)."
  }
}

variable "migrate_job_schedule" {
  type        = string
  default     = "*/5 * * * *"
  description = "With migrations = \"job\": when the migrate job (caj-migrate) runs on its own, as a five-field cron expression in UTC. The api image the job requires picks up, on each migrate run, the Masterly Environments waiting to be provisioned, so this is the longest a new Environment waits for its database. Default every five minutes. The job also runs once at install, and when CD starts it before a release rolls, whatever this says."

  validation {
    condition     = can(regex("^\\S+( \\S+){4}$", var.migrate_job_schedule))
    error_message = "migrate_job_schedule must be a five-field cron expression separated by single spaces, for example \"*/5 * * * *\" (every five minutes)."
  }
}

locals {
  # Everything in this file, the migrate identity, its grants and its Entra administrator exist
  # only with migrations = "job".
  migrate_job = var.migrations == "job"

  # The migrate job's Postgres role: the migrate identity's Entra role on "entra" (its
  # administrator is in entra-auth.tf), masterly_admin on "password". Never local.database_role,
  # which is the apps'.
  migrate_database_role = local.migrate_job && local.database_entra ? module.migrate_identity[0].name : "masterly_admin"

  # On BYO-DB the admin DSN when one is given, else the same DSN the apps get. Only the job
  # carries either (migrate_secret_names).
  migrate_database_url = !local.migrate_job ? null : (
    var.external_database_url != null ? coalesce(var.external_database_admin_url, var.external_database_url) : module.postgres_connection_urls_migrate[0].pooler_url
  )

  # Null on BYO-DB, where postgres_pgbouncer is refused and the secret is never named.
  migrate_database_direct_url = !local.migrate_job || var.external_database_url != null ? null : module.postgres_connection_urls_migrate[0].direct_url

  migrate_secret_names = !local.migrate_job ? [] : concat(
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
    local.migrate_job && local.database_entra ? {
      MASTERLY_DATABASE_AUTH = "entra"
      AZURE_CLIENT_ID        = module.migrate_identity[0].client_id
    } : {},
  )

  migrate_env_secret_refs = merge(
    { MASTERLY_DATABASE_URL = "migrate-database-url" },
    var.postgres_pgbouncer ? { MASTERLY_DATABASE_DIRECT_URL = "migrate-database-direct-url" } : {},
  )
}

resource "azurerm_container_app_job" "migrate" {
  count = local.migrate_job ? 1 : 0

  name                         = "caj-migrate"
  location                     = var.location
  resource_group_name          = azurerm_resource_group.aca.name
  container_app_environment_id = module.aca_env.id

  # An execution that has not finished in 30 minutes is stopped; the next one starts over.
  replica_timeout_in_seconds = 1800
  replica_retry_limit        = 0

  identity {
    type         = "UserAssigned"
    identity_ids = [module.migrate_identity[0].id]
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
      identity             = local.registry_username == null ? module.migrate_identity[0].id : null
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
    # As on the apps (modules/aca-container-app): CD owns the running image, Terraform seeds it
    # on create and then ignores drift, so CD can move the job to a release's digest and run it
    # before it rolls ca-api and ca-workers. Azure back-fills "Consumption" in a VNet-integrated
    # environment.
    ignore_changes = [template[0].container[0].image, workload_profile_name]
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

# What replaces the start action: the resolved api image, after the channel and api_image. A new
# value starts one more execution, on the image the job runs (CD's, once it has rolled one).
resource "terraform_data" "migrate_image" {
  count = local.migrate_job ? 1 : 0

  input = local.api_image
}

# Starts one execution of the job at apply (Microsoft.App/jobs start): at install, before the
# apps are created.
resource "azapi_resource_action" "migrate_start" {
  count = local.migrate_job ? 1 : 0

  type        = "Microsoft.App/jobs@2025-01-01"
  resource_id = azurerm_container_app_job.migrate[0].id
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
  value       = one(azurerm_container_app_job.migrate[*].name)
  description = "Name of the migrate Container Apps job (caj-migrate), in the apps resource group, with migrations = \"job\"; null otherwise. `az containerapp job execution list` shows its runs."
}
