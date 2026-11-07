# Opt-in migrate job (ADR 0120 §6; ADR 0065, 0086 and 0108 as amended 2026-10-23).
# "start" preserves app-start migrations; "job" needs a backend release after v0.135.0.
# At install, migrate_start acknowledges execution start before the apps roll; readiness
# waits for schema stamps. CD owns image drift: update the job, start it, await success,
# then roll the apps to the same digest. The schedule picks up pending provisioning runs.
# Overlapping executions require the backend migration lock. See README, "The migrate job".
# The identity is attached only to the job: AcrPull and secret-scoped Secrets User, never
# vault-wide or other data-plane grants. The privileged BYO DSN stays in the ACA job secret.

variable "migrations" {
  type        = string
  default     = "start"
  description = "Where schema migrations run. \"start\" (default): ca-api and ca-workers migrate at start, as before, and the module creates no migrate job. \"job\": the migrate Container Apps job (caj-migrate) runs them as its own identity, id-<prefix>-migrate, and ca-api and ca-workers get MASTERLY_MIGRATIONS=job. \"job\" requires mode = \"production\" and an api image from a backend release later than v0.135.0, which has the migrate entry point and honours MASTERLY_MIGRATIONS; an earlier image cannot run the job. On the starter server, \"job\" also moves ca-api and ca-workers to the DML-only roles masterly_api and masterly_workers, so the image must also create those roles, which no release up to v0.135.0 does. It also removes id-<prefix>-apps' Postgres Entra administrator (id-<prefix>-migrate is the only one). As wherever ca-workers runs as id-<prefix>-workers, on BYO-DB and on \"start\" with database_auth = \"password\" too, id-<prefix>-apps gives up its Service Bus Data Receiver and jobs-queue Data Owner grants to that identity, and ca-api keeps Service Bus Data Sender. Removing these is a minor release under ADR 0062. An existing \"entra\" install moves to this in two steps: on module 0.23.x with \"job\", confirm a Succeeded migrate run and both apps on their roles, then upgrade; a start-to-job jump does it all in one apply. See the README's upgrade note under \"The migrate job\"."

  validation {
    condition     = contains(["start", "job"], var.migrations)
    error_message = "migrations must be \"start\" (the apps migrate at start; the default) or \"job\" (the migrate job does; needs a backend release later than v0.135.0)."
  }

  validation {
    condition     = var.migrations != "job" || var.mode != "demo"
    error_message = "migrations = \"job\" cannot be used with mode = \"demo\": demo's control plane is in memory, so there is nothing for the job to migrate. Keep migrations = \"start\" for demo, or use mode = \"production\"."
  }
}

variable "migrate_job_schedule" {
  type        = string
  default     = "*/5 * * * *"
  description = "With migrations = \"job\": when the migrate job (caj-migrate) runs on its own, as a five-field cron expression in UTC. Each run picks up pending Environment provisioning once database access is ready, including any migrate_byo_database_secret_names grants. Default every five minutes. The job also runs once at install, and when CD starts it before a release rolls, whatever this says."

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

  # The DML-only login roles the job creates for ca-api and ca-workers (ADR 0120 §6), on the
  # starter server only: on BYO-DB the database is the customer's. Lowercase Postgres
  # identifiers, distinct from masterly_admin and from local.migrate_database_role. The job never
  # alters a role that already exists, so these names, the identities and the passwords below
  # must stay stable once applied.
  migrate_app_roles     = local.migrate_job && nonsensitive(var.external_database_url == null)
  migrate_api_role      = "masterly_api"
  migrate_workers_role  = "masterly_workers"
  migrate_app_passwords = local.migrate_app_roles && !local.database_entra && var.enable_key_vault

  # The vault secrets holding the app-role passwords (keyvault.tf). The job reads them by name
  # with its own identity; they are never an ACA secret, so never in migrate_secret_names.
  migrate_api_role_password_secret_name     = "install-migrate-api-role-password"
  migrate_workers_role_password_secret_name = "install-migrate-workers-role-password"

  migrate_env = merge(
    {
      MASTERLY_ORG_ID = var.org_id
      MASTERLY_MODE   = var.mode
    },
    var.org_name != null ? { MASTERLY_ORG_NAME = var.org_name } : {},
    var.mode == "production" ? { MASTERLY_CONTROLPLANE_STORE = "postgres" } : {},
    var.postgres_pgbouncer ? { MASTERLY_DATABASE_POOLER = "transaction" } : {},
    local.ca_bundle_env,
    local.private_egress_env,
    local.migrate_job && var.enable_key_vault ? {
      MASTERLY_SECRET_STORE = "keyvault"
      MASTERLY_KEYVAULT_URL = azurerm_key_vault.this[0].vault_uri
      AZURE_CLIENT_ID       = module.migrate_identity[0].client_id
    } : {},
    # The token is minted for the migrate identity, never the apps'.
    local.migrate_job && local.database_entra ? {
      MASTERLY_DATABASE_AUTH = "entra"
      AZURE_CLIENT_ID        = module.migrate_identity[0].client_id
    } : {},
    # The app roles, and how each signs in: its identity's object id on "entra", the name of its
    # password's vault secret on "password" (a reference, never the value).
    local.migrate_app_roles ? {
      MASTERLY_MIGRATE_API_ROLE     = local.migrate_api_role
      MASTERLY_MIGRATE_WORKERS_ROLE = local.migrate_workers_role
    } : {},
    local.migrate_app_roles && local.database_entra ? {
      MASTERLY_MIGRATE_API_ROLE_OBJECT_ID     = module.apps_identity.principal_id
      MASTERLY_MIGRATE_WORKERS_ROLE_OBJECT_ID = module.workers_identity[0].principal_id
    } : {},
    local.migrate_app_passwords ? {
      MASTERLY_MIGRATE_API_ROLE_PASSWORD_REF     = azurerm_key_vault_secret.migrate_api_role_password[0].name
      MASTERLY_MIGRATE_WORKERS_ROLE_PASSWORD_REF = azurerm_key_vault_secret.migrate_workers_role_password[0].name
    } : {},
  )

  migrate_env_secret_refs = merge(
    { MASTERLY_DATABASE_URL = "migrate-database-url" },
    var.postgres_pgbouncer ? { MASTERLY_DATABASE_DIRECT_URL = "migrate-database-direct-url" } : {},
  )
}

# The app roles' passwords on database_auth = "password", held in the vault (keyvault.tf) for the
# job to read when it creates the roles. No keepers: the job never alters an existing role, so a
# regenerated password would silently differ from the one in the database.
resource "random_password" "migrate_api_role" {
  count = local.migrate_app_passwords ? 1 : 0

  length  = 32
  special = false # as postgres_admin: URL-safe in a DSN
}

resource "random_password" "migrate_workers_role" {
  count = local.migrate_app_passwords ? 1 : 0

  length  = 32
  special = false
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
    azurerm_role_assignment.kv_byo_database_reader_migrate,
    azurerm_role_assignment.kv_secrets_user_migrate_api_role_password,
    azurerm_role_assignment.kv_secrets_user_migrate_workers_role_password,
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
