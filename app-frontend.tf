# The frontend: its environment and Container App.

# --- The frontend (public ingress, optionally IP-restricted) -----------------------

locals {
  # On oidc the frontend is the confidential BFF client (authorization-code + PKCE): it
  # gets the client config here; the client secret travels as a Container App secret
  # (see frontend_secret_names above), never as plain env. A local rather than inline on the
  # module, so a test can read the values the frontend is given.
  frontend_env = merge(
    {
      # By SHORT APP NAME, not by FQDN. ACA resolves `http://<app-name>` for any app in the
      # same environment through the same Envoy proxy the FQDN goes through, and it cannot
      # drift. The FQDN can: Azure reported ca-api's ingress fqdn as the INTERNAL form
      # (`ca-api.internal.<env>`) and later as the EXTERNAL form (`ca-api.<env>`) with no
      # config change on our side — terraform saw it as "changed outside of Terraform".
      # That is not cosmetic. The proxy identifies the target app from the request hostname,
      # so an internal-ingress app addressed by the external-form hostname is not found and
      # the proxy answers 404 "This Container App is stopped or does not exist" — which the
      # frontend's BFF then relayed for every /api/auth/login on the live demo.
      #
      # http, not https, and it stays http now that the environment encrypts peer traffic.
      # The certificate the platform manages is issued for the environment's domain, so
      # https://ca-api would fail hostname verification on the very name chosen because it
      # cannot drift. The scheme here says what the BFF speaks, not what crosses the wire:
      # with mutual_tls_enabled on module.aca_env, Azure encrypts the hop underneath it.
      MASTERLY_API_BASE_URL = "http://${module.api.name}"
      MASTERLY_REGION       = var.masterly_region
      MASTERLY_IDP_BINDING  = var.identity_binding
    },
    # The frontend refuses to boot on a production build with the dev binding unless this is
    # set — a deliberate guard, and it took the demo's login down: every server-side route
    # threw "Refusing to run: MASTERLY_IDP_BINDING=dev on a production build", so /api/config
    # and /api/auth/login 500'd with empty bodies while the login PAGE still served.
    #
    # Derived rather than a second variable, because the explicit opt-in already exists one
    # level up: identity_binding=dev is a deliberate choice AND is unrepresentable without a
    # non-empty ingress_allowed_cidrs (see variables.tf). A separate flag would add no safety
    # this module does not already enforce, and its absence is a silent outage.
    var.identity_binding == "dev" ? { MASTERLY_ALLOW_DEV_BINDING = "true" } : {},
    # The same value the api and the workers get, for the catalog's Consume card (empty unless set).
    local.public_api_url_env,
    var.identity_binding == "oidc" ? merge(
      {
        MASTERLY_OIDC_CLIENT_ID    = var.oidc_client_id
        MASTERLY_OIDC_AUTHORITY    = local.oidc_authority
        MASTERLY_OIDC_REDIRECT_URI = local.oidc_redirect_uri
      },
      var.oidc_scopes != null ? { MASTERLY_OIDC_SCOPES = var.oidc_scopes } : {},
    ) : {},
  )
}

module "frontend" {
  source = "./modules/aca-container-app"

  name                = "ca-frontend"
  resource_group_name = azurerm_resource_group.aca.name
  environment_id      = module.aca_env.id
  image               = local.frontend_image

  acr_login_server           = local.registry_server
  user_assigned_identity_ids = [module.frontend_identity.id]

  registry_username             = local.registry_username
  registry_password_secret_name = local.registry_password_secret_name

  ingress_external    = var.frontend_ingress_external
  ingress_target_port = 3000

  min_replicas = var.frontend_min_replicas
  max_replicas = var.frontend_max_replicas

  cpu    = local.app_resources.frontend.cpu
  memory = local.app_resources.frontend.memory

  ingress_allowed_ip_security_restrictions = [
    for index, cidr in var.ingress_allowed_cidrs : {
      name             = "allow-${index}"
      ip_address_range = cidr
      action           = "Allow"
    }
  ]

  env = local.frontend_env

  secrets         = local.frontend_value_secrets
  secret_refs     = local.frontend_vault_secret_refs
  env_secret_refs = local.frontend_env_secret_refs

  liveness_probe_path  = "/api/healthz"
  readiness_probe_path = "/api/readyz"

  # Wide on purpose. /api/readyz resolves the runtime config and then calls the api's /readyz,
  # which makes it the only check that sees either fault this frontend has actually shipped:
  # a container that boots and then throws on every server-side route (the dev-binding opt-in),
  # and one addressing an api that answers 404 (the drifting FQDN). Liveness sees neither —
  # /api/healthz returns 200 from a frontend in both states, which is why both ran for hours.
  #
  # But a gate is only safe while it outlasts a cold backend. On api_min_replicas = 0 (the
  # demo) a probe can be waiting on ACA to activate an api replica, and the provider's defaults
  # for a DECLARED probe (1s timeout, 3 failures) are far tighter than the documented readiness
  # defaults that apply when none is declared (5s timeout, 48 failures) — tight enough to call a
  # healthy revision broken and never activate it. So these five values are not tuning; without
  # them, adding the probe would be a regression.
  #
  # Budget: 5 + 48 x 10 = 485s of CONTINUOUS failure before the replica is pulled and restarted.
  # Sized for the case that actually has to work — a customer's FIRST apply, where the frontend
  # starts while the api is still pulling a multi-hundred-MB image onto a cold node. A brand-new
  # install serving a bare 503 at frontend_url is precisely the outcome this release exists to
  # prevent, so the budget is deliberately past any plausible first pull.
  #
  # The interval is what a healthy cold wake pays, not the threshold: the frontend cannot take
  # traffic until a probe lands AFTER the api answers, so a wide interval quantises every wake.
  # 10s halves that against 20s while the higher threshold still doubles the budget — the two
  # knobs trade independently, so there is no reason to be coarse. One success takes traffic.
  #
  # Detection speed costs nothing here: revision_mode is Single, and ACA shifts traffic only
  # once readiness succeeds, so a broken revision never serves regardless of the threshold. The
  # threshold governs only when ACA restarts the replica.
  readiness_probe_initial_delay           = 5
  readiness_probe_interval_seconds        = 10
  readiness_probe_timeout                 = 8
  readiness_probe_failure_count_threshold = 48
  readiness_probe_success_count_threshold = 1

  tags = local.tags

  # The grants must land before the first pull. Nothing else orders them: the app depends on
  # the identity, not on the role assignments on it, so on a first apply terraform is free to
  # create the revision while AcrPull is still in flight — and a revision that cannot pull
  # fails to provision. With the vault on, the same is true of the secret reads — one grant per
  # frontend secret, and naming the resource waits for every instance: the registry password is
  # itself a vault reference, so an unresolvable secret is an unpullable image.
  depends_on = [
    azurerm_role_assignment.acr_pull_frontend,
    azurerm_role_assignment.kv_secrets_user_frontend,
    azurerm_private_endpoint.registry,
    azurerm_private_dns_zone_virtual_network_link.registry,
  ]
}
