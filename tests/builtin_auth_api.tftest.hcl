# Container Apps built-in authentication on ca-api (builtin-auth.tf, builtin_auth_api): the L1
# gate of ADR 0120 §2, off by default.
#
# Every expected value here is a literal, so this file states what the switch plans off and on,
# and a change that moves either has to change this file. Between them the runs compare ca-api's
# and ca-frontend's auth configurations, ca-api's allowed applications exactly, and the
# container app bodies of ca-api, ca-frontend and ca-edge, which turning the switch on must not
# move: ca-api already carries the built-in auth client secret whenever builtin_auth is set.
#
# The container app bodies: for ca-api and ca-frontend, everything modules/aca-container-app
# exposes (name, environment, image, registry, size, scale, identity, ingress, env names and
# value digests, probes, secrets and mounts), the same literal off and on; the rest of their
# arguments are in main.tf and that module, neither of which reads builtin_auth_api. For ca-edge,
# every configured attribute of azurerm_container_app.edge, its Envoy configuration by digest.
#
# Applies, in their own file, for the reasons tests/workers_identity_unchanged.tftest.hcl gives:
# the identities' client ids and the apps' ids are computed, so at plan they are unknown on
# Terraform 1.10. Every identity is overridden with a distinct client id: the shared mock gives
# them all the same one, and an "exactly these applications" assertion would then prove nothing.
# The guard refusing the switch without builtin_auth is a plan run in builtin_auth.tftest.hcl.

mock_provider "azurerm" {
  source = "./tests/mocks/migrate"

  override_resource {
    target = module.api.azurerm_container_app.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
    }
  }

  override_resource {
    target = module.frontend.azurerm_container_app.this
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend"
    }
  }

  override_resource {
    target = azurerm_container_app.edge
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-edge"
    }
  }
}
mock_provider "random" {}
mock_provider "azapi" {}
mock_provider "time" {
  mock_resource "time_sleep" {
    defaults = {
      id = "2026-01-01T00:00:00Z"
    }
  }
}

# A distinct client id per identity, so an allowed application on the wrong identity fails.
override_module {
  target  = module.apps_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps", principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", client_id = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-apps" }
}

override_module {
  target  = module.frontend_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend", principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff", client_id = "ffffffff-ffff-ffff-ffff-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-frontend" }
}

override_module {
  target  = module.migrate_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-migrate", principal_id = "dddddddd-dddd-dddd-dddd-dddddddddddd", client_id = "dddddddd-dddd-dddd-dddd-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-migrate" }
}

override_module {
  target  = module.workers_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-workers", principal_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", client_id = "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-workers" }
}

override_module {
  target  = module.edge_identity
  outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge", principal_id = "99999999-9999-9999-9999-999999999999", client_id = "99999999-9999-9999-9999-cccccccccccc", tenant_id = "00000000-0000-0000-0000-000000000000", name = "id-masterly-edge" }
}

variables {
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image   = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server = ""

  key_vault_deployer_ip_rules = ["203.0.113.7"]

  alert_email = "ops@example.com"

  ingress_allowed_cidrs = ["203.0.113.7/32"]
  builtin_auth = {
    tenant_id = "11111111-1111-1111-1111-111111111111"
    client_id = "22222222-2222-2222-2222-222222222222"
  }
  builtin_auth_client_secret = "test-only-not-a-secret"
}

# --- Off (the default) -----------------------------------------------------------------------

# builtin_auth_api unset: the frontend's gate only, and every app as on earlier versions.
run "builtin_auth_api_off_gates_the_frontend_only" {
  command = apply

  assert {
    condition = (
      jsonencode(keys(local.builtin_auth_apps)) == jsonencode(["frontend"]) &&
      jsonencode(keys(azapi_resource.builtin_auth)) == jsonencode(["frontend"]) &&
      !contains(keys(azapi_resource.builtin_auth), "api")
    )
    error_message = "With builtin_auth_api unset, built-in auth must configure ca-frontend only, and nothing under the key \"api\"."
  }

  assert {
    condition = jsonencode(azapi_resource.builtin_auth["frontend"].body) == jsonencode({
      properties = {
        platform = {
          enabled = true
        }
        globalValidation = {
          unauthenticatedClientAction = "RedirectToLoginPage"
          excludedPaths               = []
          redirectToProvider          = "azureactivedirectory"
        }
        identityProviders = {
          azureActiveDirectory = {
            registration = {
              clientId                = "22222222-2222-2222-2222-222222222222"
              clientSecretSettingName = "microsoft-provider-authentication-secret"
              openIdIssuer            = "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0"
            }
            validation = {
              allowedAudiences = []
              defaultAuthorizationPolicy = {
                allowedApplications = ["22222222-2222-2222-2222-222222222222"]
              }
            }
          }
        }
      }
    })
    error_message = "With builtin_auth_api unset, ca-frontend's auth configuration must be as before this input existed."
  }

  assert {
    condition = (
      azapi_resource.builtin_auth["frontend"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-frontend" &&
      !local.builtin_auth_leaves_published_api_ungated
    )
    error_message = "With builtin_auth_api unset and the api internal, the frontend's configuration must name ca-frontend, and the published-api warning must not fire."
  }

  # The rest of ca-api's and ca-frontend's arguments are in main.tf and the app module: neither
  # reads the switch, so it cannot reach them.
  assert {
    condition = (
      length(regexall("builtin_auth_api", file("${path.module}/main.tf"))) == 0 &&
      length(regexall("builtin_auth_api", file("${path.module}/modules/aca-container-app/main.tf"))) == 0
    )
    error_message = "main.tf and modules/aca-container-app/main.tf must not read builtin_auth_api."
  }

  assert {
    condition = nonsensitive(jsonencode({
      name                       = module.api.name
      environment_id             = module.api.environment_id
      image                      = module.api.image
      registry                   = module.api.registry
      cpu                        = module.api.cpu
      memory                     = module.api.memory
      scale                      = module.api.scale
      user_assigned_identity_ids = module.api.user_assigned_identity_ids
      ingress_enabled            = module.api.ingress_enabled
      ingress_external           = module.api.ingress_external
      ingress_allow_insecure     = module.api.ingress_allow_insecure
      ingress_allowed_ip_ranges  = module.api.ingress_allowed_ip_ranges
      env_names                  = module.api.env_names
      env_value_sha256           = module.api.env_value_sha256
      env_secret_refs            = module.api.env_secret_refs
      readiness_probe            = module.api.readiness_probe
      liveness_probe             = module.api.liveness_probe
      value_secret_names         = sort(module.api.value_secret_names)
      vault_backed_secret_names  = module.api.vault_backed_secret_names
      secret_ref_identity_ids    = module.api.secret_ref_identity_ids
      secret_refs                = module.api.secret_refs
      secret_file_mounts         = module.api.secret_file_mounts
      })) == jsonencode({
      name                       = "ca-api"
      environment_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      image                      = "masterly.azurecr.io/release/api:v0.0.0"
      registry                   = null
      cpu                        = 0.5
      memory                     = "1Gi"
      scale                      = { min_replicas = 1, max_replicas = 1, termination_grace_period_seconds = null, custom_scale_rules = [] }
      user_assigned_identity_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"]
      ingress_enabled            = true
      ingress_external           = false
      ingress_allow_insecure     = true
      ingress_allowed_ip_ranges  = []
      env_names                  = ["MASTERLY_ALLOWED_REGIONS", "MASTERLY_DPOP_INTERNAL_ORIGIN", "MASTERLY_ERASURE_BACKUP_RETENTION_DAYS", "MASTERLY_IDENTITY_BINDING", "MASTERLY_INSTALL_ID", "MASTERLY_MODE", "MASTERLY_ORG_ID", "MASTERLY_REGION"]
      env_value_sha256 = {
        MASTERLY_ALLOWED_REGIONS               = sha256("eu")
        MASTERLY_DPOP_INTERNAL_ORIGIN          = sha256("http://ca-api")
        MASTERLY_ERASURE_BACKUP_RETENTION_DAYS = sha256("7")
        MASTERLY_IDENTITY_BINDING              = sha256("dev")
        MASTERLY_INSTALL_ID                    = sha256("test")
        MASTERLY_MODE                          = sha256("demo")
        MASTERLY_ORG_ID                        = sha256("org_test")
        MASTERLY_REGION                        = sha256("eu")
      }
      env_secret_refs           = { MASTERLY_BFF_SHARED_SECRET = "bff-shared-secret", MASTERLY_DATABASE_URL = "database-url", MASTERLY_SESSION_SECRET = "session-secret" }
      readiness_probe           = { path = "/readyz", initial_delay = 5, interval_seconds = 10, timeout = 8, failure_count_threshold = 48, success_count_threshold = 1 }
      liveness_probe            = { path = "/healthz", initial_delay = 5, interval_seconds = 20, timeout = 10, failure_count_threshold = 24 }
      value_secret_names        = ["bff-shared-secret", "database-url", "microsoft-provider-authentication-secret", "session-secret"]
      vault_backed_secret_names = []
      secret_ref_identity_ids   = []
      secret_refs               = {}
      secret_file_mounts        = {}
    })
    error_message = "With builtin_auth_api unset, ca-api's container app must be as before this input existed, the built-in auth client secret included."
  }

  assert {
    condition = nonsensitive(jsonencode({
      name                       = module.frontend.name
      environment_id             = module.frontend.environment_id
      image                      = module.frontend.image
      registry                   = module.frontend.registry
      cpu                        = module.frontend.cpu
      memory                     = module.frontend.memory
      scale                      = module.frontend.scale
      user_assigned_identity_ids = module.frontend.user_assigned_identity_ids
      ingress_enabled            = module.frontend.ingress_enabled
      ingress_external           = module.frontend.ingress_external
      ingress_allow_insecure     = module.frontend.ingress_allow_insecure
      ingress_allowed_ip_ranges  = module.frontend.ingress_allowed_ip_ranges
      env_names                  = module.frontend.env_names
      env_value_sha256           = module.frontend.env_value_sha256
      env_secret_refs            = module.frontend.env_secret_refs
      readiness_probe            = module.frontend.readiness_probe
      liveness_probe             = module.frontend.liveness_probe
      value_secret_names         = sort(module.frontend.value_secret_names)
      vault_backed_secret_names  = module.frontend.vault_backed_secret_names
      secret_ref_identity_ids    = module.frontend.secret_ref_identity_ids
      secret_refs                = module.frontend.secret_refs
      secret_file_mounts         = module.frontend.secret_file_mounts
      })) == jsonencode({
      name                       = "ca-frontend"
      environment_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      image                      = "masterly.azurecr.io/release/frontend:v0.0.0"
      registry                   = null
      cpu                        = 0.5
      memory                     = "1Gi"
      scale                      = { min_replicas = 1, max_replicas = 3, termination_grace_period_seconds = null, custom_scale_rules = [] }
      user_assigned_identity_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend"]
      ingress_enabled            = true
      ingress_external           = true
      ingress_allow_insecure     = false
      ingress_allowed_ip_ranges  = ["203.0.113.7/32"]
      env_names                  = ["MASTERLY_ALLOW_DEV_BINDING", "MASTERLY_API_BASE_URL", "MASTERLY_IDP_BINDING", "MASTERLY_REGION"]
      env_value_sha256 = {
        MASTERLY_ALLOW_DEV_BINDING = sha256("true")
        MASTERLY_API_BASE_URL      = sha256("http://ca-api")
        MASTERLY_IDP_BINDING       = sha256("dev")
        MASTERLY_REGION            = sha256("eu")
      }
      env_secret_refs           = { MASTERLY_BFF_SHARED_SECRET = "bff-shared-secret" }
      readiness_probe           = { path = "/api/readyz", initial_delay = 5, interval_seconds = 10, timeout = 8, failure_count_threshold = 48, success_count_threshold = 1 }
      liveness_probe            = { path = "/api/healthz", initial_delay = null, interval_seconds = null, timeout = null, failure_count_threshold = null }
      value_secret_names        = ["bff-shared-secret", "microsoft-provider-authentication-secret"]
      vault_backed_secret_names = []
      secret_ref_identity_ids   = []
      secret_refs               = {}
      secret_file_mounts        = {}
    })
    error_message = "With builtin_auth_api unset, ca-frontend's container app must be as before this input existed."
  }
}

# The same with edge set: ca-edge is as on earlier versions too.
run "builtin_auth_api_off_leaves_the_edge_unchanged" {
  command = apply

  variables {
    edge = {}
  }

  assert {
    condition = (
      jsonencode(keys(local.builtin_auth_apps)) == jsonencode(["frontend"]) &&
      !contains(keys(azapi_resource.builtin_auth), "api")
    )
    error_message = "With builtin_auth_api unset and edge set, built-in auth must still configure ca-frontend only."
  }

  # Every configured attribute of ca-edge; Azure's computed ones (fqdn, the identity's principal,
  # a TCP probe's path) are left out. The Envoy configuration, the third argument, is compared by
  # its SHA-256: the literal is the digest of the configuration this version renders, and the file
  # it is built in reads no builtin_auth_api, so the switch cannot reach it.
  assert {
    condition = nonsensitive(jsonencode({
      name                         = azurerm_container_app.edge[0].name
      resource_group_name          = azurerm_container_app.edge[0].resource_group_name
      container_app_environment_id = azurerm_container_app.edge[0].container_app_environment_id
      revision_mode                = azurerm_container_app.edge[0].revision_mode
      tags                         = azurerm_container_app.edge[0].tags
      secret                       = length(azurerm_container_app.edge[0].secret)
      registry                     = azurerm_container_app.edge[0].registry
      identity                     = [for i in azurerm_container_app.edge[0].identity : { type = i.type, identity_ids = i.identity_ids }]
      ingress = [for i in azurerm_container_app.edge[0].ingress : {
        external_enabled           = i.external_enabled
        target_port                = i.target_port
        exposed_port               = i.exposed_port
        transport                  = i.transport
        allow_insecure_connections = i.allow_insecure_connections
        client_certificate_mode    = i.client_certificate_mode
        session_affinity_enabled   = i.session_affinity_enabled
        cors                       = i.cors
        custom_domain              = i.custom_domain
        traffic_weight             = i.traffic_weight
        ip_security_restriction    = i.ip_security_restriction
      }]
      template = [for t in azurerm_container_app.edge[0].template : {
        min_replicas   = t.min_replicas
        max_replicas   = t.max_replicas
        init_container = t.init_container
        volume         = t.volume
        container = [for c in t.container : {
          name            = c.name
          image           = c.image
          cpu             = c.cpu
          memory          = c.memory
          command         = c.command
          args            = [for index, a in c.args : index == 2 ? sha256(a) : a]
          env             = c.env
          volume_mounts   = c.volume_mounts
          startup_probe   = c.startup_probe
          liveness_probe  = [for p in c.liveness_probe : { transport = p.transport, port = p.port, host = p.host, header = p.header, initial_delay = p.initial_delay, interval_seconds = p.interval_seconds, timeout = p.timeout, failure_count_threshold = p.failure_count_threshold }]
          readiness_probe = [for p in c.readiness_probe : { transport = p.transport, port = p.port, host = p.host, header = p.header, initial_delay = p.initial_delay, interval_seconds = p.interval_seconds, timeout = p.timeout, failure_count_threshold = p.failure_count_threshold, success_count_threshold = p.success_count_threshold }]
        }]
      }]
      })) == jsonencode({
      name                         = "ca-edge"
      resource_group_name          = "rg-masterly-aca"
      container_app_environment_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      revision_mode                = "Single"
      tags                         = { install-id = "test", org-id = "org_test" }
      secret                       = 0
      registry                     = []
      identity                     = [{ type = "UserAssigned", identity_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge"] }]
      ingress = [{
        external_enabled           = true
        target_port                = 8080
        exposed_port               = null
        transport                  = null
        allow_insecure_connections = false
        client_certificate_mode    = null
        session_affinity_enabled   = null
        cors                       = []
        custom_domain              = []
        traffic_weight             = [{ label = null, latest_revision = true, percentage = 100, revision_suffix = null }]
        ip_security_restriction    = [{ action = "Allow", description = null, ip_address_range = "203.0.113.7/32", name = "allow-0" }]
      }]
      template = [{
        min_replicas   = 1
        max_replicas   = 3
        init_container = []
        volume         = []
        container = [{
          name            = "ca-edge"
          image           = "docker.io/envoyproxy/envoy:v1.40.2@sha256:8de97e654644827d62afdbf7e1d3dc9fee01a8690d410dd1c63a30dc6b6cecbb"
          cpu             = 0.25
          memory          = "0.5Gi"
          command         = null
          args            = ["envoy", "--config-yaml", "3fa7977ce66aca883eb804fdedca8966a2af34be7b369f6566d398cd512d3c15"]
          env             = []
          volume_mounts   = []
          startup_probe   = []
          liveness_probe  = [{ transport = "TCP", port = 8080, host = null, header = [], initial_delay = null, interval_seconds = 10, timeout = null, failure_count_threshold = 3 }]
          readiness_probe = [{ transport = "TCP", port = 8080, host = null, header = [], initial_delay = 5, interval_seconds = 10, timeout = null, failure_count_threshold = 10, success_count_threshold = null }]
        }]
      }]
    })
    error_message = "With builtin_auth_api unset, ca-edge's container app, its Envoy configuration included, must be as before this input existed."
  }

  assert {
    condition = (
      azurerm_container_app.edge[0].template[0].container[0].args[2] == jsonencode(local.edge_envoy_config) &&
      length(regexall("builtin_auth_api", file("${path.module}/edge.tf"))) == 0
    )
    error_message = "ca-edge's Envoy configuration must be local.edge_envoy_config, and edge.tf must not read builtin_auth_api."
  }

  assert {
    condition = (
      jsonencode(sort(module.api.value_secret_names)) == jsonencode([
        "bff-shared-secret",
        "database-url",
        "microsoft-provider-authentication-secret",
        "session-secret",
      ]) &&
      jsonencode(sort(module.frontend.value_secret_names)) == jsonencode([
        "bff-shared-secret",
        "microsoft-provider-authentication-secret",
      ]) &&
      module.api.ingress_external == false &&
      jsonencode(local.frontend_env) == jsonencode({
        MASTERLY_ALLOW_DEV_BINDING = "true"
        MASTERLY_API_BASE_URL      = "http://ca-api"
        MASTERLY_IDP_BINDING       = "dev"
        MASTERLY_REGION            = "eu"
      })
    )
    error_message = "With builtin_auth_api unset and edge set, ca-api's and ca-frontend's secrets, ingress and env must be as without edge."
  }
}

# --- On ----------------------------------------------------------------------------------------

# builtin_auth_api = true, edge unset: ca-api answers 401 to everything but ca-frontend's
# workload identity, on every path, and nothing else moves.
run "builtin_auth_api_on_admits_only_the_frontend_identity" {
  command = apply

  variables {
    builtin_auth_api = true
  }

  assert {
    condition = (
      jsonencode(keys(local.builtin_auth_apps)) == jsonencode(["api", "frontend"]) &&
      jsonencode(keys(azapi_resource.builtin_auth)) == jsonencode(["api", "frontend"])
    )
    error_message = "With builtin_auth_api = true, built-in auth must configure ca-api, under the key \"api\" that 0.19.0 and 0.19.1 used, and ca-frontend."
  }

  assert {
    condition = (
      azapi_resource.builtin_auth["api"].parent_id == module.api.id &&
      azapi_resource.builtin_auth["api"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api" &&
      azapi_resource.builtin_auth["api"].name == "current" &&
      azapi_resource.builtin_auth["api"].type == "Microsoft.App/containerApps/authConfigs@2025-01-01"
    )
    error_message = "ca-api's auth configuration must be authConfigs/current at 2025-01-01, on ca-api."
  }

  # The whole body: on, 401 with no redirect, no excluded path, builtin_auth's registration, no
  # additional audience, and ca-frontend's workload identity as the one allowed application.
  # jsonencode writes every key present, so a redirectToProvider would make it differ.
  assert {
    condition = jsonencode(azapi_resource.builtin_auth["api"].body) == jsonencode({
      properties = {
        platform = {
          enabled = true
        }
        globalValidation = {
          unauthenticatedClientAction = "Return401"
          excludedPaths               = []
        }
        identityProviders = {
          azureActiveDirectory = {
            registration = {
              clientId                = "22222222-2222-2222-2222-222222222222"
              clientSecretSettingName = "microsoft-provider-authentication-secret"
              openIdIssuer            = "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0"
            }
            validation = {
              allowedAudiences = []
              defaultAuthorizationPolicy = {
                allowedApplications = ["ffffffff-ffff-ffff-ffff-cccccccccccc"]
              }
            }
          }
        }
      }
    })
    error_message = "ca-api's auth configuration must be on, answer 401 with no redirect and no excluded path, validate builtin_auth's registration with no additional audience, and admit ca-frontend's workload identity alone."
  }

  # Threat: an excluded path that leaves part of ca-api open without a token.
  assert {
    condition = (
      jsonencode(local.builtin_auth_api_excluded_paths) == jsonencode([]) &&
      jsonencode(azapi_resource.builtin_auth["api"].body.properties.globalValidation.excludedPaths) == jsonencode([]) &&
      !contains(keys(azapi_resource.builtin_auth["api"].body.properties.globalValidation), "redirectToProvider")
    )
    error_message = "ca-api's excluded paths must come from local.builtin_auth_api_excluded_paths, which is empty, and ca-api must never redirect."
  }

  # Threat: an allowed-application list broader than ca-frontend's identity. Exactly one entry,
  # and not the registration, whose tokens a browser sign-in yields.
  assert {
    condition = (
      jsonencode(azapi_resource.builtin_auth["api"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications) == jsonencode(["ffffffff-ffff-ffff-ffff-cccccccccccc"]) &&
      !contains(azapi_resource.builtin_auth["api"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications, "22222222-2222-2222-2222-222222222222") &&
      !contains(azapi_resource.builtin_auth["api"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications, "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc")
    )
    error_message = "With edge unset, ca-api must admit exactly ca-frontend's workload identity: not builtin_auth's registration and not the apps identity."
  }

  assert {
    condition     = !local.builtin_auth_leaves_published_api_ungated
    error_message = "With builtin_auth_api = true, the published-api warning must not fire."
  }

  # Turning the switch on changes nothing else: the frontend's configuration and both container
  # apps are the literals of the off run.
  assert {
    condition = jsonencode(azapi_resource.builtin_auth["frontend"].body) == jsonencode({
      properties = {
        platform = {
          enabled = true
        }
        globalValidation = {
          unauthenticatedClientAction = "RedirectToLoginPage"
          excludedPaths               = []
          redirectToProvider          = "azureactivedirectory"
        }
        identityProviders = {
          azureActiveDirectory = {
            registration = {
              clientId                = "22222222-2222-2222-2222-222222222222"
              clientSecretSettingName = "microsoft-provider-authentication-secret"
              openIdIssuer            = "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0"
            }
            validation = {
              allowedAudiences = []
              defaultAuthorizationPolicy = {
                allowedApplications = ["22222222-2222-2222-2222-222222222222"]
              }
            }
          }
        }
      }
    })
    error_message = "Turning builtin_auth_api on must leave ca-frontend's auth configuration as it is with the switch off."
  }

  assert {
    condition = nonsensitive(jsonencode({
      name                       = module.api.name
      environment_id             = module.api.environment_id
      image                      = module.api.image
      registry                   = module.api.registry
      cpu                        = module.api.cpu
      memory                     = module.api.memory
      scale                      = module.api.scale
      user_assigned_identity_ids = module.api.user_assigned_identity_ids
      ingress_enabled            = module.api.ingress_enabled
      ingress_external           = module.api.ingress_external
      ingress_allow_insecure     = module.api.ingress_allow_insecure
      ingress_allowed_ip_ranges  = module.api.ingress_allowed_ip_ranges
      env_names                  = module.api.env_names
      env_value_sha256           = module.api.env_value_sha256
      env_secret_refs            = module.api.env_secret_refs
      readiness_probe            = module.api.readiness_probe
      liveness_probe             = module.api.liveness_probe
      value_secret_names         = sort(module.api.value_secret_names)
      vault_backed_secret_names  = module.api.vault_backed_secret_names
      secret_ref_identity_ids    = module.api.secret_ref_identity_ids
      secret_refs                = module.api.secret_refs
      secret_file_mounts         = module.api.secret_file_mounts
      })) == jsonencode({
      name                       = "ca-api"
      environment_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      image                      = "masterly.azurecr.io/release/api:v0.0.0"
      registry                   = null
      cpu                        = 0.5
      memory                     = "1Gi"
      scale                      = { min_replicas = 1, max_replicas = 1, termination_grace_period_seconds = null, custom_scale_rules = [] }
      user_assigned_identity_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"]
      ingress_enabled            = true
      ingress_external           = false
      ingress_allow_insecure     = true
      ingress_allowed_ip_ranges  = []
      env_names                  = ["MASTERLY_ALLOWED_REGIONS", "MASTERLY_DPOP_INTERNAL_ORIGIN", "MASTERLY_ERASURE_BACKUP_RETENTION_DAYS", "MASTERLY_IDENTITY_BINDING", "MASTERLY_INSTALL_ID", "MASTERLY_MODE", "MASTERLY_ORG_ID", "MASTERLY_REGION"]
      env_value_sha256 = {
        MASTERLY_ALLOWED_REGIONS               = sha256("eu")
        MASTERLY_DPOP_INTERNAL_ORIGIN          = sha256("http://ca-api")
        MASTERLY_ERASURE_BACKUP_RETENTION_DAYS = sha256("7")
        MASTERLY_IDENTITY_BINDING              = sha256("dev")
        MASTERLY_INSTALL_ID                    = sha256("test")
        MASTERLY_MODE                          = sha256("demo")
        MASTERLY_ORG_ID                        = sha256("org_test")
        MASTERLY_REGION                        = sha256("eu")
      }
      env_secret_refs           = { MASTERLY_BFF_SHARED_SECRET = "bff-shared-secret", MASTERLY_DATABASE_URL = "database-url", MASTERLY_SESSION_SECRET = "session-secret" }
      readiness_probe           = { path = "/readyz", initial_delay = 5, interval_seconds = 10, timeout = 8, failure_count_threshold = 48, success_count_threshold = 1 }
      liveness_probe            = { path = "/healthz", initial_delay = 5, interval_seconds = 20, timeout = 10, failure_count_threshold = 24 }
      value_secret_names        = ["bff-shared-secret", "database-url", "microsoft-provider-authentication-secret", "session-secret"]
      vault_backed_secret_names = []
      secret_ref_identity_ids   = []
      secret_refs               = {}
      secret_file_mounts        = {}
    })
    error_message = "Turning builtin_auth_api on must leave ca-api's container app as it is with the switch off."
  }

  assert {
    condition = nonsensitive(jsonencode({
      name                       = module.frontend.name
      environment_id             = module.frontend.environment_id
      image                      = module.frontend.image
      registry                   = module.frontend.registry
      cpu                        = module.frontend.cpu
      memory                     = module.frontend.memory
      scale                      = module.frontend.scale
      user_assigned_identity_ids = module.frontend.user_assigned_identity_ids
      ingress_enabled            = module.frontend.ingress_enabled
      ingress_external           = module.frontend.ingress_external
      ingress_allow_insecure     = module.frontend.ingress_allow_insecure
      ingress_allowed_ip_ranges  = module.frontend.ingress_allowed_ip_ranges
      env_names                  = module.frontend.env_names
      env_value_sha256           = module.frontend.env_value_sha256
      env_secret_refs            = module.frontend.env_secret_refs
      readiness_probe            = module.frontend.readiness_probe
      liveness_probe             = module.frontend.liveness_probe
      value_secret_names         = sort(module.frontend.value_secret_names)
      vault_backed_secret_names  = module.frontend.vault_backed_secret_names
      secret_ref_identity_ids    = module.frontend.secret_ref_identity_ids
      secret_refs                = module.frontend.secret_refs
      secret_file_mounts         = module.frontend.secret_file_mounts
      })) == jsonencode({
      name                       = "ca-frontend"
      environment_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      image                      = "masterly.azurecr.io/release/frontend:v0.0.0"
      registry                   = null
      cpu                        = 0.5
      memory                     = "1Gi"
      scale                      = { min_replicas = 1, max_replicas = 3, termination_grace_period_seconds = null, custom_scale_rules = [] }
      user_assigned_identity_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend"]
      ingress_enabled            = true
      ingress_external           = true
      ingress_allow_insecure     = false
      ingress_allowed_ip_ranges  = ["203.0.113.7/32"]
      env_names                  = ["MASTERLY_ALLOW_DEV_BINDING", "MASTERLY_API_BASE_URL", "MASTERLY_IDP_BINDING", "MASTERLY_REGION"]
      env_value_sha256 = {
        MASTERLY_ALLOW_DEV_BINDING = sha256("true")
        MASTERLY_API_BASE_URL      = sha256("http://ca-api")
        MASTERLY_IDP_BINDING       = sha256("dev")
        MASTERLY_REGION            = sha256("eu")
      }
      env_secret_refs           = { MASTERLY_BFF_SHARED_SECRET = "bff-shared-secret" }
      readiness_probe           = { path = "/api/readyz", initial_delay = 5, interval_seconds = 10, timeout = 8, failure_count_threshold = 48, success_count_threshold = 1 }
      liveness_probe            = { path = "/api/healthz", initial_delay = null, interval_seconds = null, timeout = null, failure_count_threshold = null }
      value_secret_names        = ["bff-shared-secret", "microsoft-provider-authentication-secret"]
      vault_backed_secret_names = []
      secret_ref_identity_ids   = []
      secret_refs               = {}
      secret_file_mounts        = {}
    })
    error_message = "Turning builtin_auth_api on must leave ca-frontend's container app as it is with the switch off."
  }
}

# With edge set, ca-edge's workload identity is admitted too, after ca-frontend's, and nothing
# else; ca-edge itself is the off run's literal.
run "builtin_auth_api_on_admits_the_frontend_and_edge_identities" {
  command = apply

  variables {
    builtin_auth_api = true
    edge             = {}
  }

  assert {
    condition     = jsonencode(azapi_resource.builtin_auth["api"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications) == jsonencode(["ffffffff-ffff-ffff-ffff-cccccccccccc", "99999999-9999-9999-9999-cccccccccccc"])
    error_message = "With edge set, ca-api must admit exactly ca-frontend's and ca-edge's workload identities, in that order."
  }

  assert {
    condition = (
      azapi_resource.builtin_auth["api"].body.properties.platform.enabled == true &&
      azapi_resource.builtin_auth["api"].body.properties.globalValidation.unauthenticatedClientAction == "Return401" &&
      jsonencode(azapi_resource.builtin_auth["api"].body.properties.globalValidation.excludedPaths) == jsonencode([]) &&
      jsonencode(azapi_resource.builtin_auth["api"].body.properties.identityProviders.azureActiveDirectory.validation.allowedAudiences) == jsonencode([]) &&
      azapi_resource.builtin_auth["api"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
    )
    error_message = "With edge set, ca-api's gate must still be on, answer 401, exclude no path and take no additional audience."
  }

  assert {
    condition = nonsensitive(jsonencode({
      name                         = azurerm_container_app.edge[0].name
      resource_group_name          = azurerm_container_app.edge[0].resource_group_name
      container_app_environment_id = azurerm_container_app.edge[0].container_app_environment_id
      revision_mode                = azurerm_container_app.edge[0].revision_mode
      tags                         = azurerm_container_app.edge[0].tags
      secret                       = length(azurerm_container_app.edge[0].secret)
      registry                     = azurerm_container_app.edge[0].registry
      identity                     = [for i in azurerm_container_app.edge[0].identity : { type = i.type, identity_ids = i.identity_ids }]
      ingress = [for i in azurerm_container_app.edge[0].ingress : {
        external_enabled           = i.external_enabled
        target_port                = i.target_port
        exposed_port               = i.exposed_port
        transport                  = i.transport
        allow_insecure_connections = i.allow_insecure_connections
        client_certificate_mode    = i.client_certificate_mode
        session_affinity_enabled   = i.session_affinity_enabled
        cors                       = i.cors
        custom_domain              = i.custom_domain
        traffic_weight             = i.traffic_weight
        ip_security_restriction    = i.ip_security_restriction
      }]
      template = [for t in azurerm_container_app.edge[0].template : {
        min_replicas   = t.min_replicas
        max_replicas   = t.max_replicas
        init_container = t.init_container
        volume         = t.volume
        container = [for c in t.container : {
          name            = c.name
          image           = c.image
          cpu             = c.cpu
          memory          = c.memory
          command         = c.command
          args            = [for index, a in c.args : index == 2 ? sha256(a) : a]
          env             = c.env
          volume_mounts   = c.volume_mounts
          startup_probe   = c.startup_probe
          liveness_probe  = [for p in c.liveness_probe : { transport = p.transport, port = p.port, host = p.host, header = p.header, initial_delay = p.initial_delay, interval_seconds = p.interval_seconds, timeout = p.timeout, failure_count_threshold = p.failure_count_threshold }]
          readiness_probe = [for p in c.readiness_probe : { transport = p.transport, port = p.port, host = p.host, header = p.header, initial_delay = p.initial_delay, interval_seconds = p.interval_seconds, timeout = p.timeout, failure_count_threshold = p.failure_count_threshold, success_count_threshold = p.success_count_threshold }]
        }]
      }]
      })) == jsonencode({
      name                         = "ca-edge"
      resource_group_name          = "rg-masterly-aca"
      container_app_environment_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/managedEnvironments/aca-masterly"
      revision_mode                = "Single"
      tags                         = { install-id = "test", org-id = "org_test" }
      secret                       = 0
      registry                     = []
      identity                     = [{ type = "UserAssigned", identity_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-edge"] }]
      ingress = [{
        external_enabled           = true
        target_port                = 8080
        exposed_port               = null
        transport                  = null
        allow_insecure_connections = false
        client_certificate_mode    = null
        session_affinity_enabled   = null
        cors                       = []
        custom_domain              = []
        traffic_weight             = [{ label = null, latest_revision = true, percentage = 100, revision_suffix = null }]
        ip_security_restriction    = [{ action = "Allow", description = null, ip_address_range = "203.0.113.7/32", name = "allow-0" }]
      }]
      template = [{
        min_replicas   = 1
        max_replicas   = 3
        init_container = []
        volume         = []
        container = [{
          name            = "ca-edge"
          image           = "docker.io/envoyproxy/envoy:v1.40.2@sha256:8de97e654644827d62afdbf7e1d3dc9fee01a8690d410dd1c63a30dc6b6cecbb"
          cpu             = 0.25
          memory          = "0.5Gi"
          command         = null
          args            = ["envoy", "--config-yaml", "3fa7977ce66aca883eb804fdedca8966a2af34be7b369f6566d398cd512d3c15"]
          env             = []
          volume_mounts   = []
          startup_probe   = []
          liveness_probe  = [{ transport = "TCP", port = 8080, host = null, header = [], initial_delay = null, interval_seconds = 10, timeout = null, failure_count_threshold = 3 }]
          readiness_probe = [{ transport = "TCP", port = 8080, host = null, header = [], initial_delay = 5, interval_seconds = 10, timeout = null, failure_count_threshold = 10, success_count_threshold = null }]
        }]
      }]
    })
    error_message = "Turning builtin_auth_api on must leave ca-edge's container app, its Envoy configuration included, as it is with the switch off."
  }

  assert {
    condition     = azurerm_container_app.edge[0].template[0].container[0].args[2] == jsonencode(local.edge_envoy_config)
    error_message = "Turning builtin_auth_api on must leave ca-edge's Envoy configuration as local.edge_envoy_config."
  }

  assert {
    condition = (
      jsonencode(sort(module.api.value_secret_names)) == jsonencode([
        "bff-shared-secret",
        "database-url",
        "microsoft-provider-authentication-secret",
        "session-secret",
      ]) &&
      jsonencode(sort(module.frontend.value_secret_names)) == jsonencode([
        "bff-shared-secret",
        "microsoft-provider-authentication-secret",
      ]) &&
      module.api.ingress_external == false &&
      jsonencode(local.frontend_env) == jsonencode({
        MASTERLY_ALLOW_DEV_BINDING = "true"
        MASTERLY_API_BASE_URL      = "http://ca-api"
        MASTERLY_IDP_BINDING       = "dev"
        MASTERLY_REGION            = "eu"
      })
    )
    error_message = "Turning builtin_auth_api on with edge set must leave ca-api's and ca-frontend's secrets, ingress and env as they are with the switch off."
  }
}

# Threat: the frontend's recovery fallback turns ca-api's gate off. With the window open, the
# frontend's gate is off and ca-api's stays on.
run "plan_time" {
  command = plan

  module {
    source = "./tests/helpers/plan-time"
  }
}

run "builtin_auth_api_stays_on_through_the_frontend_recovery_window" {
  command = apply

  variables {
    builtin_auth_api            = true
    builtin_auth_recovery_until = run.plan_time.in_30_minutes
  }

  assert {
    condition     = local.builtin_auth_recovery_open
    error_message = "A builtin_auth_recovery_until 30 minutes after the plan must open the recovery window."
  }

  assert {
    condition = (
      azapi_resource.builtin_auth["frontend"].body.properties.platform.enabled == false &&
      azapi_resource.builtin_auth["api"].body.properties.platform.enabled == true
    )
    error_message = "With the recovery window open, ca-frontend's gate must be off and ca-api's must stay on."
  }

  assert {
    condition = (
      azapi_resource.builtin_auth["api"].body.properties.globalValidation.unauthenticatedClientAction == "Return401" &&
      jsonencode(azapi_resource.builtin_auth["api"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications) == jsonencode(["ffffffff-ffff-ffff-ffff-cccccccccccc"])
    )
    error_message = "The recovery window must leave the rest of ca-api's configuration as it is without it."
  }
}

# Threat: the published api ungated while the switch is on. With api_ingress_external, ca-api's
# gate is planned and the published-api warning does not fire (no expect_failures). The run with
# the switch off, which expects the warning, is builtin_auth_warns_when_the_api_is_published in
# builtin_auth.tftest.hcl.
run "builtin_auth_api_gates_the_published_api" {
  command = apply

  variables {
    builtin_auth_api     = true
    api_ingress_external = true
  }

  assert {
    condition = (
      module.api.ingress_external == true &&
      contains(keys(azapi_resource.builtin_auth), "api") &&
      azapi_resource.builtin_auth["api"].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api" &&
      azapi_resource.builtin_auth["api"].body.properties.platform.enabled == true &&
      azapi_resource.builtin_auth["api"].body.properties.globalValidation.unauthenticatedClientAction == "Return401"
    )
    error_message = "With builtin_auth_api = true and api_ingress_external = true, the published ca-api must be gated."
  }

  assert {
    condition     = !local.builtin_auth_leaves_published_api_ungated
    error_message = "With builtin_auth_api = true, the published api is gated and the published-api warning must not fire."
  }
}

# Threat: another tenant application admitted. On an install with every identity the module
# creates (apps, frontend, migrate, workers) and the deprecated api_allowed_applications set,
# ca-api admits ca-frontend's identity alone: not the registration, no other identity of the
# install, and no deprecated entry. The deprecation warning still fires.
run "builtin_auth_api_admits_no_other_application" {
  command = apply

  variables {
    acr_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    mode                           = "production"
    identity_binding               = "oidc"
    oidc_tenant_id                 = "11111111-2222-3333-4444-555555555555"
    oidc_client_id                 = "bff-client-id"
    oidc_client_secret             = "test-only"
    oidc_redirect_uri              = "https://app.example.com/api/auth/callback"
    license_token                  = "eyJ.fake.jwt"
    license_public_jwk             = jsonencode({ kty = "EC" })
    initial_owner_email            = "owner@example.com"
    enable_key_vault               = true
    enable_redis                   = true
    redis_offering                 = "cache"
    enable_workers                 = true
    enable_service_bus             = true
    servicebus_sku                 = "Standard"
    api_max_replicas               = 2
    postgres_sku_name              = "GP_Standard_D2ds_v5"
    postgres_zone_redundant_ha     = true
    postgres_backup_retention_days = 14
    migrations                     = "job"

    builtin_auth = {
      tenant_id                = "11111111-1111-1111-1111-111111111111"
      client_id                = "22222222-2222-2222-2222-222222222222"
      api_allowed_applications = ["33333333-3333-3333-3333-333333333333", "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"]
      api_allowed_audiences    = ["api://masterly-api"]
    }
    builtin_auth_api = true
  }

  assert {
    condition = (
      length(module.migrate_identity) == 1 &&
      length(module.workers_identity) == 1 &&
      module.migrate_identity[0].client_id == "dddddddd-dddd-dddd-dddd-cccccccccccc" &&
      module.workers_identity[0].client_id == "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc"
    )
    error_message = "This run needs the migrate and workers identities, so that admitting either would show."
  }

  assert {
    condition     = jsonencode(azapi_resource.builtin_auth["api"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications) == jsonencode(["ffffffff-ffff-ffff-ffff-cccccccccccc"])
    error_message = "ca-api must admit exactly ca-frontend's workload identity, whatever builtin_auth.api_allowed_applications says."
  }

  assert {
    condition = length(setintersection(
      toset(azapi_resource.builtin_auth["api"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications),
      toset([
        "22222222-2222-2222-2222-222222222222",
        "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc",
        "bbbbbbbb-bbbb-bbbb-bbbb-cccccccccccc",
        "dddddddd-dddd-dddd-dddd-cccccccccccc",
        "33333333-3333-3333-3333-333333333333",
      ]),
    )) == 0
    error_message = "ca-api must not admit builtin_auth's registration, the apps, workers or migrate identity, or any builtin_auth.api_allowed_applications entry."
  }

  assert {
    condition = (
      jsonencode(azapi_resource.builtin_auth["api"].body.properties.identityProviders.azureActiveDirectory.validation.allowedAudiences) == jsonencode([]) &&
      jsonencode(azapi_resource.builtin_auth["frontend"].body.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications) == jsonencode(["22222222-2222-2222-2222-222222222222"])
    )
    error_message = "builtin_auth.api_allowed_audiences must not reach ca-api's audiences, and the deprecated entries must not reach the frontend's configuration."
  }

  expect_failures = [check.builtin_auth_api_entries_are_ignored]
}

# --- The 401 alert (builtin-auth.tf) ---------------------------------------------------------

# Threat: a broken gate refuses every BFF call and nothing alerts. The alert exists exactly when
# builtin_auth_api does, in the defaults (mode "demo", so diagnostics are off), and its name
# follows the module's alert convention.
run "api_401_alert_absent_with_builtin_auth_api_off" {
  command = plan

  assert {
    condition     = length(azurerm_monitor_metric_alert.builtin_auth_api_401) == 0
    error_message = "With builtin_auth set and builtin_auth_api off, there must be no 401 alert."
  }
}

run "api_401_alert_planned_with_builtin_auth_api_on" {
  command = plan

  variables {
    builtin_auth_api = true
  }

  assert {
    condition = (
      !local.diagnostics_enabled &&
      length(azurerm_monitor_metric_alert.builtin_auth_api_401) == 1 &&
      azurerm_monitor_metric_alert.builtin_auth_api_401[0].name == "alert-masterly-api-401"
    )
    error_message = "With builtin_auth_api on in demo mode (diagnostics off), the 401 alert must be planned as alert-masterly-api-401."
  }
}

run "api_401_alert_planned_with_diagnostics_explicitly_off" {
  command = plan

  variables {
    builtin_auth_api   = true
    enable_diagnostics = false
  }

  assert {
    condition     = length(azurerm_monitor_metric_alert.builtin_auth_api_401) == 1
    error_message = "The 401 alert must not depend on enable_diagnostics."
  }
}

# The scope is ca-api's id (overridden above to a literal) and the signal is the Requests metric
# filtered to status 401.
run "api_401_alert_watches_ca_api_401s" {
  command = apply

  variables {
    builtin_auth_api = true
  }

  assert {
    condition     = jsonencode(azurerm_monitor_metric_alert.builtin_auth_api_401[0].scopes) == jsonencode([module.api.id]) && module.api.id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.App/containerApps/ca-api"
    error_message = "The 401 alert must be scoped to ca-api only."
  }

  assert {
    condition = (
      azurerm_monitor_metric_alert.builtin_auth_api_401[0].criteria[0].metric_namespace == "Microsoft.App/containerapps" &&
      azurerm_monitor_metric_alert.builtin_auth_api_401[0].criteria[0].metric_name == "Requests" &&
      azurerm_monitor_metric_alert.builtin_auth_api_401[0].criteria[0].dimension[0].name == "statusCode" &&
      azurerm_monitor_metric_alert.builtin_auth_api_401[0].criteria[0].dimension[0].operator == "Include" &&
      jsonencode(azurerm_monitor_metric_alert.builtin_auth_api_401[0].criteria[0].dimension[0].values) == jsonencode(["401"])
    )
    error_message = "The 401 alert must read the Requests metric filtered to statusCode 401."
  }

  assert {
    condition     = length(trimspace(azurerm_monitor_metric_alert.builtin_auth_api_401[0].description)) > 0
    error_message = "The 401 alert must carry a description."
  }
}
