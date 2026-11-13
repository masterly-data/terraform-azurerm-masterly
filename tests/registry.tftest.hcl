# The registry, credential mode, release channel and image references (registry.tf).
#
# Branch coverage for the module's variable guards and conditional resources (mock providers, no
# cloud access; runs in CI via `terraform test`). One of the per-concern plan files
# (MAS-4478): add a run to the file of the concern it asserts on.
#
# Every plan file starts with the same two parts: the shared azurerm mock data in tests/mocks/install,
# and the same variables block below. Copy both into a new file, and change a value in every plan
# file at once (tests/README.md). A run's own `variables` block overrides the file's.

mock_provider "azurerm" {
  source = "./tests/mocks/install"
}
mock_provider "random" {}
mock_provider "azapi" {}

variables {
  location         = "swedencentral"
  org_id           = "org_test"
  install_id       = "test"
  api_image        = "masterly.azurecr.io/release/api:v0.0.0"
  frontend_image   = "masterly.azurecr.io/release/frontend:v0.0.0"
  acr_login_server = ""

  # Every production run needs one of the two deployer paths to the vault stated, the same
  # as a real production install (see key_vault_deployer_ip_rules). Set file-wide so the
  # runs that assert something else are not all about this; the guard has its own run in keyvault.tftest.hcl.
  key_vault_deployer_ip_rules = ["203.0.113.7"]

  # A production plan with no notification target is refused (alert_email's validation), so
  # every production run states one. Runs about the target override it; the refusal
  # has its own runs in diagnostics.tftest.hcl.
  alert_email = "ops@example.com"
}

# --- Registry location, credential mode and release channel -----------------------
# These runs leave api_image, frontend_image and acr_login_server null (the file-wide values
# pin them), so the images resolve from the release channel and the registry from
# registry_location. Digests are read from MANIFEST.json through the module's own local,
# never typed here: a release changes them.

# The token mode: direct pull from Masterly's registry with the bundle's credential. Every app
# carries the username and the registry-password secret, and AcrPull is not granted even with
# acr_id set, because nothing pulls as an identity.
run "registry_token_mode_pulls_release_digests_with_the_pull_secret" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    api_image                = null
    frontend_image           = null
    acr_login_server         = null
    enable_workers           = true
    registry_credential_mode = "token"
    registry_token = {
      username = "00000000-0000-0000-0000-000000000000"
      password = "sp-client-secret"
    }
    acr_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
  }

  assert {
    condition = (
      module.api.image == "masterly.azurecr.io/release/api@${local.release_manifest.releases[local.release_manifest.latest].digests.api}" &&
      module.frontend.image == "masterly.azurecr.io/release/frontend@${local.release_manifest.releases[local.release_manifest.latest].digests.frontend}" &&
      module.workers[0].image == module.api.image &&
      can(regex("^masterly\\.azurecr\\.io/release/api@sha256:[0-9a-f]{64}$", module.api.image)) &&
      can(regex("^masterly\\.azurecr\\.io/release/frontend@sha256:[0-9a-f]{64}$", module.frontend.image))
    )
    error_message = "The token mode must pull masterly.azurecr.io/release/<role>@<digest of the latest release>."
  }

  assert {
    condition = alltrue([
      for r in [module.api.registry, module.frontend.registry, module.workers[0].registry] :
      r.server == "masterly.azurecr.io" &&
      r.username == "00000000-0000-0000-0000-000000000000" &&
      r.password_secret_name == "registry-password" &&
      r.identity == null
    ])
    error_message = "Every app's registry block must name masterly.azurecr.io, the token's username and the registry-password secret, and no identity."
  }

  assert {
    condition = (
      contains(module.api.value_secret_names, "registry-password") &&
      contains(module.frontend.value_secret_names, "registry-password") &&
      contains(module.workers[0].value_secret_names, "registry-password")
    )
    error_message = "The token mode must carry the pull credential as the registry-password secret on every app."
  }

  assert {
    condition     = length(azurerm_role_assignment.acr_pull) == 0 && length(azurerm_role_assignment.acr_pull_frontend) == 0
    error_message = "The token mode must create no AcrPull assignment."
  }

  assert {
    condition     = output.image_references.registry_credential_mode == "token" && output.image_references.release_version == local.release_manifest.latest
    error_message = "image_references must report the token mode and the latest release."
  }
}

# The managed-identity mode: each app pulls as its own identity, carries no registry secret,
# and acr_id grants AcrPull to both. Identity ids are pinned with override_module, as in
# no_data_plane_grant_reaches_the_frontend, so the wiring is comparable at plan.
run "registry_managed_identity_mode_pulls_with_the_app_identities" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    api_image                = null
    frontend_image           = null
    acr_login_server         = null
    enable_key_vault         = true
    registry_credential_mode = "managed_identity"
    acr_id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
  }

  override_module {
    target = module.apps_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-apps"
      principal_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      client_id    = "aaaaaaaa-aaaa-aaaa-aaaa-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-apps"
    }
  }

  override_module {
    target = module.frontend_identity
    outputs = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-masterly-aca/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-masterly-frontend"
      principal_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
      client_id    = "ffffffff-ffff-ffff-ffff-cccccccccccc"
      tenant_id    = "00000000-0000-0000-0000-000000000000"
      name         = "id-masterly-frontend"
    }
  }

  assert {
    condition = (
      module.api.registry.server == "masterly.azurecr.io" &&
      module.api.registry.identity == module.apps_identity.id &&
      module.frontend.registry.server == "masterly.azurecr.io" &&
      module.frontend.registry.identity == module.frontend_identity.id &&
      module.api.registry.username == null && module.api.registry.password_secret_name == null &&
      module.frontend.registry.username == null && module.frontend.registry.password_secret_name == null
    )
    error_message = "The managed-identity mode must pull each app as its own identity, with no username or password secret."
  }

  assert {
    condition = alltrue([
      for names in [
        module.api.value_secret_names, module.api.vault_backed_secret_names,
        module.frontend.value_secret_names, module.frontend.vault_backed_secret_names,
      ] : !contains(names, "registry-password")
      ]) && (
      !contains(keys(azurerm_key_vault_secret.install), "registry-password") &&
      !contains(keys(azurerm_role_assignment.kv_secrets_user_frontend), "registry-password")
    )
    error_message = "The managed-identity mode must carry no registry-password secret, by value or from the vault, and write none to the vault."
  }

  assert {
    condition = (
      azurerm_role_assignment.acr_pull[0].scope == var.acr_id &&
      azurerm_role_assignment.acr_pull[0].principal_id == module.apps_identity.principal_id &&
      azurerm_role_assignment.acr_pull_frontend[0].scope == var.acr_id &&
      azurerm_role_assignment.acr_pull_frontend[0].principal_id == module.frontend_identity.principal_id
    )
    error_message = "With acr_id set, the managed-identity mode must grant AcrPull on it to both app identities."
  }

  assert {
    condition = (
      module.api.image == "masterly.azurecr.io/release/api@${local.release_manifest.releases[local.release_manifest.latest].digests.api}" &&
      module.frontend.image == "masterly.azurecr.io/release/frontend@${local.release_manifest.releases[local.release_manifest.latest].digests.frontend}"
    )
    error_message = "The managed-identity mode must pull the same release/<role> digests from Masterly's registry."
  }
}

# With the vault on, the token's password is written to the vault and every app reads it as a
# reference: no app holds it as a value, and the frontend may read that one secret.
run "registry_token_mode_with_the_vault_reads_the_password_from_the_vault" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    acr_login_server         = null
    enable_key_vault         = true
    enable_workers           = true
    registry_credential_mode = "token"
    registry_token = {
      username = "00000000-0000-0000-0000-000000000000"
      password = "sp-client-secret"
    }
  }

  assert {
    condition = (
      contains(keys(azurerm_key_vault_secret.install), "registry-password") &&
      contains(keys(azurerm_role_assignment.kv_secrets_user_frontend), "registry-password") &&
      alltrue([
        for app in [module.api, module.frontend, module.workers[0]] :
        contains(app.vault_backed_secret_names, "registry-password") &&
        !contains(app.value_secret_names, "registry-password") &&
        app.registry.password_secret_name == "registry-password"
      ])
    )
    error_message = "With the vault on, the token mode must write registry-password to the vault and every app must read it as a reference."
  }
}

# Without acr_id the grants are the customer's to make out of band (see the principal id outputs).
run "registry_managed_identity_mode_without_acr_id_grants_nothing" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    acr_login_server         = null
    registry_credential_mode = "managed_identity"
  }

  assert {
    condition     = length(azurerm_role_assignment.acr_pull) == 0 && length(azurerm_role_assignment.acr_pull_frontend) == 0
    error_message = "With acr_id null, no AcrPull assignment may be created."
  }
}

# The customer-owned registry: the images and the registry block name the customer's login
# server, the repositories stay release/<role>, and the apps pull as their identities with
# AcrPull on the customer's registry.
run "registry_customer_mode_pulls_release_repositories_from_the_customer_registry" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    api_image                = null
    frontend_image           = null
    acr_login_server         = null
    registry_location        = "acme.azurecr.io"
    registry_credential_mode = "customer_registry"
    acr_id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme/providers/Microsoft.ContainerRegistry/registries/acme"
  }

  assert {
    condition = (
      module.api.image == "acme.azurecr.io/release/api@${local.release_manifest.releases[local.release_manifest.latest].digests.api}" &&
      module.frontend.image == "acme.azurecr.io/release/frontend@${local.release_manifest.releases[local.release_manifest.latest].digests.frontend}"
    )
    error_message = "The customer_registry mode must pull release/<role> from the customer's login server."
  }

  assert {
    condition = alltrue([
      for r in [module.api.registry, module.frontend.registry] :
      r.server == "acme.azurecr.io" && r.username == null && r.password_secret_name == null
    ])
    error_message = "The customer_registry mode must point each registry block at the customer's login server and pull with no username or password secret, as the app identity."
  }

  assert {
    condition = (
      !contains(module.api.value_secret_names, "registry-password") &&
      !contains(module.frontend.value_secret_names, "registry-password") &&
      azurerm_role_assignment.acr_pull[0].scope == var.acr_id &&
      azurerm_role_assignment.acr_pull_frontend[0].scope == var.acr_id
    )
    error_message = "The customer_registry mode must carry no registry secret and grant AcrPull on the customer's acr_id to both identities."
  }
}

# --- The registry's private endpoint (registry.tf) ---------------------------------------
# On with the managed-identity mode: one endpoint to acr_id's "registry" subresource in the data
# resource group, one privatelink.azurecr.io zone with its VNet link, and the endpoint's zone
# group in that zone. The created VNet's and zone's IDs are unknown at plan; the injected-network
# run below compares the VNet and subnet the endpoint lands on.
run "registry_private_endpoint_managed_identity_plans_the_endpoint_zone_and_link" {
  command = plan

  variables {
    ingress_allowed_cidrs     = ["203.0.113.7/32"]
    acr_login_server          = null
    registry_credential_mode  = "managed_identity"
    acr_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    registry_private_endpoint = true
  }

  assert {
    condition = (
      length(azurerm_private_endpoint.registry) == 1 &&
      azurerm_private_endpoint.registry[0].name == "pe-masterly-registry" &&
      azurerm_private_endpoint.registry[0].resource_group_name == azurerm_resource_group.data.name &&
      azurerm_private_endpoint.registry[0].private_service_connection[0].private_connection_resource_id == var.acr_id &&
      azurerm_private_endpoint.registry[0].private_service_connection[0].subresource_names == tolist(["registry"]) &&
      azurerm_private_endpoint.registry[0].private_service_connection[0].is_manual_connection == false
    )
    error_message = "registry_private_endpoint must create one private endpoint to acr_id's \"registry\" subresource, in the data resource group."
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone.registry) == 1 &&
      azurerm_private_dns_zone.registry[0].name == "privatelink.azurecr.io" &&
      azurerm_private_dns_zone.registry[0].resource_group_name == azurerm_resource_group.aca.name
    )
    error_message = "registry_private_endpoint must create the privatelink.azurecr.io private DNS zone."
  }

  assert {
    condition = (
      length(azurerm_private_dns_zone_virtual_network_link.registry) == 1 &&
      azurerm_private_dns_zone_virtual_network_link.registry[0].name == "pdzl-masterly-registry"
    )
    error_message = "registry_private_endpoint must link the privatelink.azurecr.io zone to the install's VNet."
  }

  assert {
    condition = (
      length(azurerm_private_endpoint.registry[0].private_dns_zone_group) == 1 &&
      azurerm_private_endpoint.registry[0].private_dns_zone_group[0].name == "registry" &&
      length(azurerm_private_endpoint.registry[0].private_dns_zone_group[0].private_dns_zone_ids) == 1
    )
    error_message = "The registry's private endpoint must carry one DNS zone group, in the privatelink.azurecr.io zone."
  }

  # The endpoint changes the network path only: the apps still pull from the same login server
  # as their identities, with AcrPull on acr_id.
  assert {
    condition = (
      module.api.registry.server == "masterly.azurecr.io" &&
      module.frontend.registry.server == "masterly.azurecr.io" &&
      module.api.registry.password_secret_name == null &&
      azurerm_role_assignment.acr_pull[0].scope == var.acr_id &&
      azurerm_role_assignment.acr_pull_frontend[0].scope == var.acr_id
    )
    error_message = "registry_private_endpoint must leave the registry block and the AcrPull grants as the managed-identity mode sets them."
  }
}

# Topology 3 with a customer-owned registry: the endpoint lands on the injected
# private-endpoint subnet and the zone is linked to the VNet that subnet belongs to.
run "registry_private_endpoint_customer_registry_lands_on_the_injected_network" {
  command = plan

  variables {
    ingress_allowed_cidrs       = ["203.0.113.7/32"]
    aca_subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca"
    private_endpoints_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-pe"
    acr_login_server            = null
    registry_location           = "acme.azurecr.io"
    registry_credential_mode    = "customer_registry"
    acr_id                      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-acme/providers/Microsoft.ContainerRegistry/registries/acme"
    registry_private_endpoint   = true
  }

  assert {
    condition = (
      azurerm_private_endpoint.registry[0].subnet_id == var.private_endpoints_subnet_id &&
      azurerm_private_endpoint.registry[0].private_service_connection[0].private_connection_resource_id == var.acr_id &&
      azurerm_private_endpoint.registry[0].private_service_connection[0].subresource_names == tolist(["registry"])
    )
    error_message = "The registry's private endpoint must connect to the customer's acr_id from the injected private-endpoint subnet."
  }

  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.registry[0].virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hub-spoke/providers/Microsoft.Network/virtualNetworks/vnet-spoke"
    error_message = "The privatelink.azurecr.io zone must be linked to the VNet of the injected subnets."
  }
}

# Off by default, even in an identity mode with acr_id set: no endpoint, no zone, no link.
run "registry_private_endpoint_off_by_default_creates_nothing" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    acr_login_server         = null
    registry_credential_mode = "managed_identity"
    acr_id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
  }

  assert {
    condition = (
      length(azurerm_private_endpoint.registry) == 0 &&
      length(azurerm_private_dns_zone.registry) == 0 &&
      length(azurerm_private_dns_zone_virtual_network_link.registry) == 0 &&
      output.registry_private_endpoint_id == null
    )
    error_message = "With registry_private_endpoint off (the default), no registry private endpoint, DNS zone or VNet link may be created."
  }
}

# The release channel picks the manifest release; the repository never moves. One run per
# allowed value; the second compares itself with the first.
run "release_channel_stable_resolves_the_latest_release" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = null
    frontend_image        = null
    acr_login_server      = null
    release_channel       = "stable"
  }

  assert {
    condition = (
      output.image_references.release_version == local.release_manifest.latest &&
      output.image_references.api == "masterly.azurecr.io/release/api@${local.release_manifest.releases[local.release_manifest.latest].digests.api}" &&
      output.image_references.frontend == "masterly.azurecr.io/release/frontend@${local.release_manifest.releases[local.release_manifest.latest].digests.frontend}"
    )
    error_message = "release_channel = \"stable\" must resolve to the latest release's release/<role> digests."
  }
}

run "release_channel_previous_resolves_an_older_release_in_the_same_repositories" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = null
    frontend_image        = null
    acr_login_server      = null
    release_channel       = "previous"
  }

  assert {
    condition = (
      output.image_references.release_version != local.release_manifest.latest &&
      try(local.release_manifest.releases[output.image_references.release_version].known_issue, null) == null &&
      output.image_references.api == "masterly.azurecr.io/release/api@${local.release_manifest.releases[output.image_references.release_version].digests.api}" &&
      output.image_references.frontend == "masterly.azurecr.io/release/frontend@${local.release_manifest.releases[output.image_references.release_version].digests.frontend}"
    )
    error_message = "release_channel = \"previous\" must resolve to an older release with no known issue, by its release/<role> digests."
  }

  # Only the version differs from the stable channel: the registry and the repositories match.
  assert {
    condition = (
      output.image_references.release_version != run.release_channel_stable_resolves_the_latest_release.image_references.release_version &&
      split("@", output.image_references.api)[0] == split("@", run.release_channel_stable_resolves_the_latest_release.image_references.api)[0] &&
      split("@", output.image_references.frontend)[0] == split("@", run.release_channel_stable_resolves_the_latest_release.image_references.frontend)[0] &&
      split("@", output.image_references.api)[0] == "masterly.azurecr.io/release/api" &&
      split("@", output.image_references.frontend)[0] == "masterly.azurecr.io/release/frontend"
    )
    error_message = "Changing release_channel must change only the version; the repositories stay release/api and release/frontend."
  }
}

# An image set explicitly is used as given, whatever the channel.
run "release_channel_leaves_an_explicit_image_alone" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    release_channel       = "previous"
  }

  assert {
    condition     = module.api.image == "masterly.azurecr.io/release/api:v0.0.0" && module.frontend.image == "masterly.azurecr.io/release/frontend:v0.0.0"
    error_message = "An explicit api_image or frontend_image must not be replaced by the channel's reference."
  }
}

# The deprecated inputs map onto the modes: the credential pair is the token mode, and a
# registry other than Masterly's with no credential is the customer_registry mode.
run "legacy_registry_credential_maps_onto_the_token_mode" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = null
    registry_username     = "00000000-0000-0000-0000-000000000000"
    registry_password     = "sp-client-secret"
  }

  assert {
    condition = (
      output.image_references.registry_credential_mode == "token" &&
      module.api.registry.server == "masterly.azurecr.io" &&
      module.api.registry.username == "00000000-0000-0000-0000-000000000000" &&
      module.frontend.registry.password_secret_name == "registry-password" &&
      contains(module.frontend.value_secret_names, "registry-password")
    )
    error_message = "registry_username and registry_password must map onto the token mode."
  }
}

run "legacy_acr_login_server_maps_onto_the_customer_registry_mode" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = "acme.azurecr.io"
    api_image             = null
    frontend_image        = null
  }

  assert {
    condition = (
      output.image_references.registry_credential_mode == "customer_registry" &&
      module.api.registry.server == "acme.azurecr.io" &&
      startswith(module.api.image, "acme.azurecr.io/release/api@sha256:") &&
      startswith(module.frontend.image, "acme.azurecr.io/release/frontend@sha256:")
    )
    error_message = "acr_login_server naming the customer's registry must map onto the customer_registry mode."
  }
}

# Omitting registry_location, with no mode, credential or acr_id, is public images: no
# registry block and no pull secret. acr_login_server = "" migrates to exactly that.
run "registry_location_omitted_renders_no_registry_block" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = null
    api_image             = null
    frontend_image        = null
  }

  assert {
    condition = (
      module.api.registry == null &&
      module.frontend.registry == null &&
      output.image_references.registry_server == "" &&
      !contains(module.api.value_secret_names, "registry-password") &&
      !contains(module.frontend.value_secret_names, "registry-password")
    )
    error_message = "registry_location omitted with no mode, credential or acr_id must render no registry block and no registry-password secret."
  }

  assert {
    condition = (
      module.api.image == "masterly.azurecr.io/release/api@${local.release_manifest.releases[local.release_manifest.latest].digests.api}" &&
      module.frontend.image == "masterly.azurecr.io/release/frontend@${local.release_manifest.releases[local.release_manifest.latest].digests.frontend}"
    )
    error_message = "With no registry block, the default images must still be the latest release's release/<role> digests."
  }
}

run "legacy_acr_login_server_empty_matches_registry_location_omitted" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = ""
    api_image             = null
    frontend_image        = null
  }

  assert {
    condition = (
      module.api.registry == null &&
      module.frontend.registry == null &&
      output.image_references == run.registry_location_omitted_renders_no_registry_block.image_references
    )
    error_message = "acr_login_server = \"\" must plan the same images and the same absent registry block as omitting registry_location."
  }
}

# acr_id alone still pulls from Masterly's registry as the app identities, as the old
# acr_login_server default did: a grant with no registry block would pull nothing.
run "registry_location_omitted_with_acr_id_pulls_from_masterly_as_the_identities" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = null
    acr_id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
  }

  assert {
    condition = (
      output.image_references.registry_credential_mode == "managed_identity" &&
      module.api.registry.server == "masterly.azurecr.io" &&
      module.frontend.registry.server == "masterly.azurecr.io" &&
      module.api.registry.password_secret_name == null &&
      length(azurerm_role_assignment.acr_pull) == 1 && length(azurerm_role_assignment.acr_pull_frontend) == 1
    )
    error_message = "acr_id with registry_location omitted must pull from masterly.azurecr.io as the app identities, with AcrPull for both."
  }
}

# Guards.
run "release_channel_unknown_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    release_channel       = "beta"
  }

  expect_failures = [var.release_channel]
}

run "registry_token_mode_without_a_credential_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    registry_credential_mode = "token"
  }

  expect_failures = [var.registry_credential_mode]
}

run "registry_credential_mode_unknown_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    registry_credential_mode = "anonymous"
  }

  expect_failures = [var.registry_credential_mode]
}

run "registry_identity_mode_with_a_token_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    registry_credential_mode = "managed_identity"
    registry_token = {
      username = "00000000-0000-0000-0000-000000000000"
      password = "sp-client-secret"
    }
  }

  expect_failures = [var.registry_credential_mode]
}

run "registry_customer_mode_without_a_customer_registry_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    acr_login_server         = null
    registry_credential_mode = "customer_registry"
  }

  expect_failures = [var.registry_credential_mode]
}

run "registry_private_endpoint_with_the_token_mode_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs    = ["203.0.113.7/32"]
    acr_login_server         = null
    registry_credential_mode = "token"
    registry_token = {
      username = "00000000-0000-0000-0000-000000000000"
      password = "sp-client-secret"
    }
    acr_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    registry_private_endpoint = true
  }

  expect_failures = [var.registry_private_endpoint]
}

# The token mode derived from a credential, with registry_credential_mode left null.
run "registry_private_endpoint_with_a_derived_token_mode_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = null
    registry_token = {
      username = "00000000-0000-0000-0000-000000000000"
      password = "sp-client-secret"
    }
    acr_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/masterly"
    registry_private_endpoint = true
  }

  expect_failures = [var.registry_private_endpoint]
}

run "registry_private_endpoint_without_acr_id_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs     = ["203.0.113.7/32"]
    acr_login_server          = null
    registry_credential_mode  = "managed_identity"
    registry_private_endpoint = true
  }

  expect_failures = [var.registry_private_endpoint]
}

run "registry_private_endpoint_with_an_acr_id_that_is_not_a_registry_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs     = ["203.0.113.7/32"]
    acr_login_server          = null
    registry_credential_mode  = "managed_identity"
    acr_id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared"
    registry_private_endpoint = true
  }

  expect_failures = [var.registry_private_endpoint]
}

run "registry_location_with_acr_login_server_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = "acme.azurecr.io"
    registry_location     = "acme.azurecr.io"
  }

  expect_failures = [var.registry_location]
}

run "registry_location_with_a_scheme_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = null
    registry_location     = "https://acme.azurecr.io/"
  }

  expect_failures = [var.registry_location]
}

# "" is not a registry: public images are registry_location omitted.
run "registry_location_empty_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    acr_login_server      = null
    registry_location     = ""
  }

  expect_failures = [var.registry_location]
}

run "registry_token_with_the_deprecated_pair_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    registry_username     = "00000000-0000-0000-0000-000000000000"
    registry_password     = "sp-client-secret"
    registry_token = {
      username = "00000000-0000-0000-0000-000000000000"
      password = "sp-client-secret"
    }
  }

  expect_failures = [var.registry_token]
}

# The token must arrive whole: a blank username or an empty password is refused.
run "registry_token_without_a_username_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    registry_token = {
      username = ""
      password = "sp-client-secret"
    }
  }

  expect_failures = [var.registry_token]
}

run "registry_token_without_a_password_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    registry_token = {
      username = "00000000-0000-0000-0000-000000000000"
      password = ""
    }
  }

  expect_failures = [var.registry_token]
}

# Guard: ACS email data location must match the install's geo.
run "acs_email_geo_mismatch_is_rejected" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    location              = "eastus2"
    masterly_region       = "us"
    email_acs_enabled     = true
    # email_acs_data_location stays the "Europe" default -> mismatch
  }

  expect_failures = [var.email_acs_data_location]
}

# The frontend refuses to boot on a production build with the dev binding unless the opt-in is
# present. It took the demo's login down for weeks: every server-side route threw "Refusing to
# run: MASTERLY_IDP_BINDING=dev on a production build", so /api/config and /api/auth/login
# returned empty 500s while the login PAGE still served — which is why it read as "stale" rather
# than "broken". Terraform is the only place that can pair the two, so it is pinned here.
run "dev_binding_sets_the_frontend_opt_in" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = contains(module.frontend.env_names, "MASTERLY_ALLOW_DEV_BINDING")
    error_message = "identity_binding=dev must set MASTERLY_ALLOW_DEV_BINDING, or the frontend refuses to boot"
  }
}

# And the opt-in is not carried into a real identity binding, where it would be a standing
# invitation to fall back to an identity adapter that accepts anyone.
run "oidc_does_not_set_the_dev_opt_in" {
  command = plan

  variables {
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
  }

  assert {
    condition     = !contains(module.frontend.env_names, "MASTERLY_ALLOW_DEV_BINDING")
    error_message = "MASTERLY_ALLOW_DEV_BINDING must not be set when identity_binding is oidc"
  }
}

# Redis runs noeviction. Session revocation markers (`sess:rev:{jti}`) and the org revocation
# epoch are correctness state, and every key the registry writes carries a TTL — so Azure's
# default volatile-lru evicts exactly the keys that keep a revoked session revoked, and the
# token itself stays valid until its own expiry. Nothing downstream can detect that
# resurrection, so the policy is pinned at plan time here.
run "redis_runs_noeviction" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    enable_redis          = true
    redis_offering        = "cache"
  }

  assert {
    condition     = azurerm_redis_cache.this[0].redis_configuration[0].maxmemory_policy == "noeviction"
    error_message = "Redis must run maxmemory_policy = noeviction — an evicted revocation marker resurrects a revoked session"
  }
}

# Guard: mode=production refuses an install with no Owner bootstrap. A fresh production
# install starts with an empty member list, and the only rule that ever mints the first Owner
# keys on MASTERLY_INITIAL_OWNER_EMAIL — so an apply without it hands the customer an install
# nobody can sign into, which is exactly what a plan-time refusal is for.
run "production_without_initial_owner_is_rejected" {
  command = plan

  variables {
    mode                 = "production"
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
    license_token        = "eyJ.fake.jwt"
    license_public_jwk   = "{\"kty\":\"EC\"}"
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 2
    # initial_owner_email is unset -> refused

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.mode]
}

# And an armed break-glass pair does not satisfy it. This pins the bug caught in review: the
# obvious condition "initial_owner_email OR the break-glass pair" reads as an either/or, but
# break-glass resolves an existing Owner membership before minting a session, so on a fresh
# install it is 403 — recovery for an Owner who exists, never the creation of the first one.
run "production_breakglass_does_not_replace_the_owner_bootstrap" {
  command = plan

  variables {
    mode                 = "production"
    identity_binding     = "oidc"
    oidc_allowed_issuers = "https://login.microsoftonline.com/aaa/v2.0"
    oidc_audience        = "api-client-id"
    oidc_jwks_uri        = "https://login.microsoftonline.com/organizations/discovery/v2.0/keys"
    oidc_client_id       = "bff-client-id"
    oidc_client_secret   = "s3cret"
    oidc_authority       = "https://login.microsoftonline.com/organizations/v2.0"
    oidc_redirect_uri    = "https://app.example.com/api/auth/callback"
    license_token        = "eyJ.fake.jwt"
    license_public_jwk   = "{\"kty\":\"EC\"}"
    enable_key_vault     = true
    enable_redis         = true
    redis_offering       = "cache"
    enable_workers       = true
    api_max_replicas     = 2

    breakglass_owner_email = "breakglass@example.com"
    breakglass_secret_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    external_database_url = "postgresql+asyncpg://masterly:pw@pg.example.com:5432/postgres?ssl=require"
  }

  expect_failures = [var.mode]
}

# The frontend's readiness gate. Liveness cannot see a frontend that boots and then throws on
# every server-side route (the dev-binding opt-in), nor one wired to an api that answers 404
# (the drifting FQDN) — /api/healthz returns 200 in both states, and both ran for hours.
# /api/readyz resolves the runtime config and calls the api, so it sees both.
run "frontend_readiness_gates_on_the_api" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_min_replicas      = 0 # the demo's posture: the probe can be waiting on a cold api
    frontend_min_replicas = 0
  }

  assert {
    condition     = module.frontend.readiness_probe.path == "/api/readyz"
    error_message = "The frontend must gate readiness on /api/readyz — /api/healthz answers 200 from a frontend broken in exactly the ways this install has hit."
  }

  # The gate is only safe while it outlasts a cold backend: at the provider's defaults (1s
  # timeout, 3 failures) a scaled-to-zero api makes a healthy frontend revision look broken,
  # and ACA restarts the replica rather than activating it.
  assert {
    condition = (
      module.frontend.readiness_probe.initial_delay +
      module.frontend.readiness_probe.failure_count_threshold *
      module.frontend.readiness_probe.interval_seconds
    ) >= 240
    error_message = "The frontend's readiness budget must stay >= 240s of continuous failure, or a cold api can fail an otherwise healthy revision."
  }

  assert {
    condition     = module.frontend.readiness_probe.success_count_threshold == 1
    error_message = "One success must be enough to take traffic, or the gate adds probe intervals to every cold wake."
  }

  # The api needs the same widening, and this assertion used to say the opposite.
  #
  # It asserted the api must KEEP Azure's defaults, because tolerances re-render its container
  # template and roll the api on every live install's next apply. On 2026-08-31 that trade came
  # due: the v0.133.0 roll left ca-api--0000135 ActivationFailed holding 100% of traffic with
  # zero replicas, while the previous revision logged "Probe of Readiness failed with timeout in
  # 1 seconds" 71 times running. A one-time roll is the cheaper side of this trade by a wide
  # margin, and mode=production requires api_max_replicas >= 2, so a real install runs this race
  # on every replica start.
  assert {
    condition     = module.api.readiness_probe.path == "/readyz"
    error_message = "The api must gate readiness on /readyz."
  }

  # The same budget as the frontend, and for a stronger reason: /readyz opens Postgres, Redis
  # and Key Vault behind private endpoints, and a customer's FIRST apply is the worst case.
  # A cold api must not outlive the frontend gate that is waiting on it.
  assert {
    condition = (
      module.api.readiness_probe.initial_delay +
      module.api.readiness_probe.failure_count_threshold *
      module.api.readiness_probe.interval_seconds
    ) >= 240
    error_message = "The api's readiness budget must stay >= 240s of continuous failure. At the provider's declared-probe defaults (1s timeout, 3 failures) a cold database makes a healthy revision ActivationFailed, and it takes 100% of traffic with zero replicas."
  }

  # A timeout above the interval would let attempts overlap and never resolve.
  assert {
    condition     = module.api.readiness_probe.timeout <= module.api.readiness_probe.interval_seconds
    error_message = "The api's readiness timeout must stay at or below its interval."
  }

  assert {
    condition     = module.api.readiness_probe.success_count_threshold == 1
    error_message = "One success must be enough for the api to take traffic."
  }
}

# The api's liveness probe declares its tolerances. A declared liveness probe with none set runs
# on Azure's defaults (1s timeout, 3 failures), and a failing liveness probe always restarts the
# container — so one slow /healthz answer, or a start that takes longer than about 30 seconds,
# becomes a restart, and a systemic one becomes a restart loop. The api does not listen until
# its startup completes, so the liveness budget is also its startup budget.
run "api_liveness_declares_its_tolerances" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
  }

  assert {
    condition     = module.api.liveness_probe.path == "/healthz"
    error_message = "The api must probe liveness on /healthz."
  }

  # The declared values, pinned, so an edit cannot silently drop the api back to the defaults.
  assert {
    condition = (
      module.api.liveness_probe.initial_delay == 5 &&
      module.api.liveness_probe.interval_seconds == 20 &&
      module.api.liveness_probe.timeout == 10 &&
      module.api.liveness_probe.failure_count_threshold == 24
    )
    error_message = "The api's liveness tolerances must be declared (initial_delay 5, interval 20s, timeout 10s, 24 failures). If you change them deliberately, change this assertion with them."
  }

  # The budget a process that is alive but slow, or still starting, has before it is restarted.
  # It must not be tighter than readiness: readiness already takes an unhealthy replica out of
  # rotation and restarts it, so a tighter liveness budget adds nothing but a second, earlier
  # way to restart a replica that is only starting.
  assert {
    condition = (
      module.api.liveness_probe.initial_delay +
      module.api.liveness_probe.failure_count_threshold *
      module.api.liveness_probe.interval_seconds
      ) >= (
      module.api.readiness_probe.initial_delay +
      module.api.readiness_probe.failure_count_threshold *
      module.api.readiness_probe.interval_seconds
    )
    error_message = "The api's liveness budget must be at least its readiness budget, or liveness restarts a replica that readiness is still waiting on."
  }

  # A timeout above the interval would let attempts overlap and never resolve.
  assert {
    condition     = module.api.liveness_probe.timeout <= module.api.liveness_probe.interval_seconds
    error_message = "The api's liveness timeout must stay at or below its interval."
  }

  # Every other caller keeps Azure's defaults: the new inputs are null unless set, and only the
  # api sets them.
  assert {
    condition = (
      module.frontend.liveness_probe.path == "/api/healthz" &&
      module.frontend.liveness_probe.initial_delay == null &&
      module.frontend.liveness_probe.interval_seconds == null &&
      module.frontend.liveness_probe.timeout == null &&
      module.frontend.liveness_probe.failure_count_threshold == null
    )
    error_message = "The frontend's liveness probe must be unchanged by the api's tolerances."
  }
}

# --- Image references: a tag, a tag and a digest, or a digest alone -------------------------
# api_image and frontend_image take registry/repository:tag, registry/repository:tag@sha256:<digest>
# or registry/repository@sha256:<digest>, and the repository's last segment names the role. The
# digests here are synthetic: no release records them.
run "image_references_pinned_by_digest_alone_plan" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    frontend_image        = "masterly.azurecr.io/release/frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  assert {
    condition     = !module.license_claims_floor.refused && module.license_claims_floor.image_claims_version == null
    error_message = "A digest-only api image whose digest the manifest does not record must plan, unchecked."
  }
}

# A tag and a digest together are resolved by the tag: v0.133.2 is a release the manifest
# recorded before api_claims_version existed, so it reads as 0.
run "image_references_pinned_by_tag_and_digest_plan" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/api:v0.133.2@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    frontend_image        = "masterly.azurecr.io/release/frontend:v0.0.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  assert {
    condition     = !module.license_claims_floor.refused && module.license_claims_floor.image_claims_version == 0
    error_message = "An api image pinned by tag and digest must plan and be resolved by its tag."
  }
}

run "image_references_pinned_by_tag_alone_plan" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/api:v0.133.2"
    frontend_image        = "masterly.azurecr.io/release/frontend:v0.0.0"
  }

  assert {
    condition     = !module.license_claims_floor.refused && module.license_claims_floor.image_claims_version == 0
    error_message = "An image pinned by tag alone must plan and be resolved by its tag."
  }
}

# A digest must be "sha256:" and exactly 64 lowercase hex characters.
run "an_image_digest_of_the_wrong_length_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    frontend_image        = "masterly.azurecr.io/release/frontend:v0.0.0@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  expect_failures = [var.api_image, var.frontend_image]
}

run "an_image_digest_in_uppercase_hex_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/api@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    frontend_image        = "masterly.azurecr.io/release/frontend:v0.0.0@sha256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  }

  expect_failures = [var.api_image, var.frontend_image]
}

run "an_image_digest_without_sha256_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/api@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    frontend_image        = "masterly.azurecr.io/release/frontend:v0.0.0@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  expect_failures = [var.api_image, var.frontend_image]
}

# The repository's last segment names the role: an api image is .../api, a frontend image
# .../frontend, and swapping them, or a longer name, is refused.
run "an_image_whose_repository_is_not_the_role_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/apiserver:v0.0.0"
    frontend_image        = "masterly.azurecr.io/release/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.api_image, var.frontend_image]
}

run "an_image_with_the_role_above_another_segment_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "masterly.azurecr.io/release/api/release:v0.0.0"
    frontend_image        = "masterly.azurecr.io/release/frontend/release:v0.0.0"
  }

  expect_failures = [var.api_image, var.frontend_image]
}

# The first segment is the registry: a host with a "." or a ":" (a port), or localhost. A
# reference whose first segment is neither would be read by an image runtime as Docker Hub's
# default registry, which the customer never named, so it is refused.
run "an_image_with_no_registry_host_is_refused" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "release/api:v1.0.0"
    frontend_image        = "release/frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  expect_failures = [var.api_image, var.frontend_image]
}

run "an_image_on_localhost_or_a_registry_port_plans" {
  command = plan

  variables {
    ingress_allowed_cidrs = ["203.0.113.7/32"]
    api_image             = "localhost/api:v0.0.0"
    frontend_image        = "registry:5000/release/frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  assert {
    condition     = !module.license_claims_floor.refused && module.license_claims_floor.image_claims_version == null
    error_message = "An image on localhost, or on a registry named by host and port, must plan."
  }
}
