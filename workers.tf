# The dedicated workers app (ADR 0066 increment 3): the async-pipeline consume loop as its
# own Container App — same image and env contract as the api, command overridden to
# `python -m masterly_app.workers`, no ingress, no probes. Enabling it flips the api off
# the in-process loop (MASTERLY_INPROCESS_WORKER=false), so exactly one side owns it.

variable "enable_workers" {
  type        = bool
  default     = false
  description = "Run the dedicated workers Container App and take the api off the in-process worker loop (ADR 0066). Off = the api runs the loop in-process (the single-process dev/demo shape, ADR 0012). Required by mode=production — the api scales for request load, the pipeline for job load, independently."

  # Production runs the pipeline in its own app (ADR 0066): with a multi-replica api the
  # in-process loop would run on every replica; the dedicated workers app owns the loop and
  # scales independently of request traffic.
  validation {
    condition     = var.mode != "production" || var.enable_workers
    error_message = "mode=production requires enable_workers=true — the async pipeline must run in the dedicated ca-workers app, not in-process on the (multi-replica) api."
  }
}

variable "workers_min_replicas" {
  type        = number
  default     = 1
  description = "Minimum workers replicas (keep >= 1: the loop polls; scale-to-zero would stall the pipeline on the polling binding). mode=production requires >= 1."

  # No stalled pipeline in production: ca-workers has no ingress, so nothing wakes a
  # scaled-to-zero workers app — every queued job would wait indefinitely. It is also the one
  # floor at which the workers no-replica alert stands down (diagnostics.tf), so a production
  # install at zero would stall with nothing reporting it.
  validation {
    condition     = var.mode != "production" || var.workers_min_replicas >= 1
    error_message = "mode=production requires workers_min_replicas >= 1 — ca-workers has no ingress, so nothing wakes it from zero and every queued job would wait indefinitely."
  }
}

variable "workers_max_replicas" {
  type        = number
  default     = 1
  description = "Maximum workers replicas. ca-workers scales above workers_min_replicas only on the Service Bus binding (enable_service_bus = true), where a scale rule on the jobs queue targets 5 waiting messages per replica, up to this number. On the polling binding (the default) there is no queue length to scale on, so ca-workers stays at workers_min_replicas whatever this is set to. Jobs are claimed per Environment and job kind across all replicas: jobs of different kinds, or in different Environments, run in parallel, and two jobs of the same kind in one Environment never overlap, so an extra replica adds throughput and never duplicates work."

  validation {
    condition     = !var.enable_workers || var.workers_max_replicas >= var.workers_min_replicas
    error_message = "workers_max_replicas must be at least workers_min_replicas."
  }
}

variable "workers_termination_grace_period_seconds" {
  type        = number
  default     = 600
  description = "Seconds a stopping ca-workers replica (scale-in, a new revision, a restart) has between the termination signal and a forced kill, 0-600. On the signal a worker claims no new job and finishes the jobs it is running, so the grace period is how long those jobs may still take. A job cut off by a forced kill is retried only once its lease expires. The default, 600, is the most Container Apps allows; 30 seconds is Azure's own default."

  validation {
    condition     = var.workers_termination_grace_period_seconds >= 0 && var.workers_termination_grace_period_seconds <= 600 && floor(var.workers_termination_grace_period_seconds) == var.workers_termination_grace_period_seconds
    error_message = "workers_termination_grace_period_seconds must be a whole number of seconds from 0 to 600."
  }
}

locals {
  # Merged into the api's env in main.tf when the workers app owns the loop.
  workers_inprocess_env = var.enable_workers ? {
    MASTERLY_INPROCESS_WORKER = "false"
  } : {}

  # The workers scale on the jobs queue's length, and only on the Service Bus binding: the
  # polling binding keeps its queue in each Environment's Postgres database, where there is no
  # single length to measure, so on it ca-workers stays at workers_min_replicas.
  workers_scale_on_queue = var.enable_workers && var.enable_service_bus

  # Each message on the queue tells a worker that one Environment has jobs waiting, so the
  # length of the queue is the number of drains not yet started. KEDA's own default target of
  # 5 messages per replica is kept: a drain runs every job of its Environment that it can
  # claim, so one replica per message would add replicas faster than the work needs them.
  workers_scale_message_count = 5

  # Whether ca-workers runs as its own identity (id-<prefix>-workers, main.tf): wherever it exists
  # and the install has a Key Vault, so on "password", on BYO-DB and on migrations = "job", which
  # requires the vault. migrations = "start" with database_auth = "entra" on the starter server
  # stays on the apps identity: the shared DSN's user there is that identity's name, and its token
  # is minted for AZURE_CLIENT_ID. Every `*_workers` grant and Redis policy counts on this, so an
  # install without ca-workers gets none of them. nonsensitive() on database_entra alone, the
  # same narrow unmarking as main.tf's presence tests: whether a DSN was supplied is not the secret,
  # and a marked value here would hide which identity ca-workers runs as from every plan.
  workers_own_identity = var.enable_workers && var.enable_key_vault && (local.migrate_app_roles || !nonsensitive(local.database_entra))

  # Whether ca-workers signs in as its own database role, masterly_workers, with its own DSN
  # secrets: only where the migrate job creates that role (migrate_app_roles) and ca-workers exists.
  # Separate from the identity above, because that role and its URLs need the starter server,
  # which BYO-DB does not have: elsewhere ca-workers reads the shared database-url, through its own
  # identity where it has one (backend_vault_secret_refs, keyvault.tf).
  workers_own_dsn = local.migrate_app_roles && var.enable_workers

  # The identity ca-workers runs as, pulls with, resolves its vault references with and scales
  # with: its own when workers_own_identity, the apps identity otherwise, as before.
  workers_identity_id = local.workers_own_identity ? module.workers_identity[0].id : module.apps_identity.id
}

# The scale rule reads the queue's message count, which the scaler's documentation says needs
# the Manage right. The data-plane Sender and Receiver roles in main.tf do not carry it; of the
# built-in roles only Azure Service Bus Data Owner does. It is granted on the jobs queue only, not
# on the namespace, so it reaches no other entity. That queue scope is enough is checked on a
# live install before the release that carries this rule; namespace scope is the fallback.
#
# The apps identity holds it only while ca-workers runs as that identity: with
# local.workers_own_identity the scale rule uses sb_scaler_workers below, and ca-api never needs
# Data Owner (ADR 0120). module.workers depends on this grant, so on an install where ca-workers
# moves to its own identity Terraform removes it only after updating ca-workers.
resource "azurerm_role_assignment" "sb_scaler" {
  count = local.workers_scale_on_queue && !local.workers_own_identity ? 1 : 0

  scope                = azurerm_servicebus_queue.jobs[0].id
  role_definition_name = "Azure Service Bus Data Owner"
  principal_id         = module.apps_identity.principal_id
}

# The same role on the same queue for ca-workers' own identity, which the scale rule then uses.
resource "azurerm_role_assignment" "sb_scaler_workers" {
  count = local.workers_own_identity && local.workers_scale_on_queue ? 1 : 0

  scope                = azurerm_servicebus_queue.jobs[0].id
  role_definition_name = "Azure Service Bus Data Owner"
  principal_id         = module.workers_identity[0].principal_id
}

check "workers_scale_on_the_polling_binding" {
  assert {
    condition     = !var.enable_workers || var.enable_service_bus || var.workers_max_replicas <= var.workers_min_replicas
    error_message = "workers_max_replicas is above workers_min_replicas, but ca-workers scales only on the Service Bus binding (enable_service_bus = true). On the polling binding it stays at workers_min_replicas."
  }
}

module "workers" {
  count  = var.enable_workers ? 1 : 0
  source = "./modules/aca-container-app"

  name                = "ca-workers"
  resource_group_name = azurerm_resource_group.aca.name
  environment_id      = module.aca_env.id
  image               = local.api_image # the same image as the api; only the command differs

  acr_login_server           = local.registry_server
  user_assigned_identity_ids = [local.workers_identity_id]

  registry_username             = local.registry_username
  registry_password_secret_name = local.registry_password_secret_name

  ingress_enabled = false
  command         = ["python", "-m", "masterly_app.workers"]

  min_replicas = var.workers_min_replicas
  max_replicas = var.workers_max_replicas

  cpu    = local.app_resources.workers.cpu
  memory = local.app_resources.workers.memory

  termination_grace_period_seconds = var.workers_termination_grace_period_seconds

  # KEDA's Service Bus scaler, authenticated as ca-workers' managed identity (the namespace
  # refuses SAS). The queue, and its namespace by short name, are the ones the workers
  # receive from (MASTERLY_SERVICEBUS_QUEUE / MASTERLY_SERVICEBUS_NAMESPACE in main.tf).
  custom_scale_rules = local.workers_scale_on_queue ? [{
    name             = "jobs-queue"
    custom_rule_type = "azure-servicebus"
    metadata = {
      namespace    = azurerm_servicebus_namespace.this[0].name
      queueName    = azurerm_servicebus_queue.jobs[0].name
      messageCount = tostring(local.workers_scale_message_count)
    }
    identity_id = local.workers_identity_id
  }] : []

  # The full api env contract: build_services in the workers process reads the same
  # settings (identity, license, bus, secret store, redis) as the api. That includes the
  # CA bundle mount (MAS-446): SMTP/webhook/stream-push delivery runs here, so ca-workers
  # needs the same trusted CA the api does, at the same path. The exceptions: the BFF shared
  # secret authenticates the frontend's calls to the api, and ca-workers serves no request, so
  # it gets the backend_* set, which is the api's without it (main.tf); with its own identity
  # its AZURE_CLIENT_ID is its own (workers_env), and with its own role so are its DSNs
  # (workers-database-url).
  env                = local.workers_env
  secrets            = local.backend_value_secrets
  secret_refs        = local.backend_vault_secret_refs
  env_secret_refs    = local.backend_env_secret_refs
  secret_file_mounts = local.ca_bundle_secret_file_mounts

  tags = local.tags

  depends_on = [
    # The :6432 URL must not reach a revision before PgBouncer listens and the NSG admits it.
    azurerm_postgresql_flexible_server_configuration.pgbouncer,
    azurerm_network_security_group.private_endpoints,
    azurerm_private_endpoint.postgres,
    azurerm_private_dns_zone_virtual_network_link.postgres,
    azurerm_private_endpoint.redis,
    azurerm_private_dns_zone_virtual_network_link.redis,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
    azurerm_role_assignment.kv_app_secrets,
    azurerm_role_assignment.sb_sender,
    # On an install where ca-workers moves to its own identity, the first two edges also make
    # Terraform remove the apps identity's Receiver and scaler grant only after this app's update,
    # and on one moving to migrations = "job" the third does the same for its Entra
    # administrator: keep them.
    azurerm_role_assignment.sb_receiver,
    azurerm_role_assignment.sb_scaler,
    azurerm_postgresql_flexible_server_active_directory_administrator.apps,
    azurerm_managed_redis_access_policy_assignment.apps,
    azurerm_redis_cache_access_policy_assignment.apps,
    # Its own identity's grants, when it runs as it.
    azurerm_role_assignment.acr_pull_workers,
    azurerm_role_assignment.kv_app_secrets_workers,
    azurerm_role_assignment.kv_crypto_officer_workers,
    azurerm_role_assignment.sb_sender_workers,
    azurerm_role_assignment.sb_receiver_workers,
    azurerm_role_assignment.sb_scaler_workers,
    azurerm_role_assignment.acs_email_sender_workers,
    azurerm_managed_redis_access_policy_assignment.workers,
    azurerm_redis_cache_access_policy_assignment.workers,
    azurerm_private_endpoint.servicebus,
    azurerm_private_dns_zone_virtual_network_link.servicebus,
    # MASTERLY_MIGRATIONS = job, as on the api (migrate.tf).
    azapi_resource_action.migrate_start,
  ]
}

output "workers_app_name" {
  value       = var.enable_workers ? module.workers[0].name : null
  description = "Container App name of the workers (null when the api runs the loop in-process)."
}
