# Identity

How the install authenticates its users and which identity each part of it runs as (ADR 0024):
the identity adapter, `ca-frontend` on your own domain, the built-in authentication in front of
the frontend, and the workload identity each role runs as (ADR 0120 §6).

## Identity (ADR 0024)

`identity_binding` selects the adapter:

- **`oidc`** — production: your own IdP. The backend verifies tokens against
  `oidc_allowed_issuers`/`oidc_audience`/`oidc_jwks_uri`; the frontend BFF is the
  confidential client (`oidc_client_id`/`oidc_client_secret`/`oidc_authority`/
  `oidc_redirect_uri`). With Entra, `oidc_tenant_id` fills in the issuer, the signing-key
  endpoint and the authority for a single-tenant registration; any of the three you set
  yourself wins. `oidc_audience` defaults to `oidc_client_id`. Optional break-glass local
  Owner via `breakglass_secret_hash` — a salted Argon2id value minted
  inside the api image with `python -m masterly_app.core.breakglass_credential`, never the
  secret and never a sha256 digest, which the api refuses at startup. A break-glass attempt
  made in the GUI is throttled by the browser's address rather than the frontend's, through
  the [BFF shared secret](../README.md#the-bff-shared-secret) the module generates. Break-glass signs in
  as `breakglass_owner_email`, which defaults to `initial_owner_email` once a hash is set:
  that address becomes the first Owner, and break-glass admits only an existing Owner. See
  [Access and identity](https://masterlydata.com/docs/self-hosted/install/#access-and-identity).

  `oidc_allowed_issuers` normally holds **one** entry — this install's own issuer. Every
  issuer listed here is trusted **install-wide**, so it is not the way to onboard an
  additional organization onto one install: register an org-scoped SSO connection in the
  product instead, which is bound to the Organizations that registered it.
- **`dev`** — evaluation only. The module **refuses** `dev` with an open ingress:
  set `ingress_allowed_cidrs` (an IP allowlist) or switch to `oidc`.

**With a custom domain** (`frontend_custom_domain`) a production install is **one apply**. The
redirect URI is known before anything exists: the module derives
`https://<hostname>/api/auth/callback` from the hostname and gives it to the frontend, so leave
`oidc_redirect_uri` unset and register that URI at your IdP before you apply. If you do set
`oidc_redirect_uri` alongside the custom domain it must name the same host, or the plan is refused.
Before the apply, create the DNS records and grant the deploying identity the right to assign a
role on the certificate's vault: see
[ca-frontend on your own domain](#ca-frontend-on-your-own-domain-frontend_custom_domain).

**Without a custom domain** the frontend FQDN is an output of the first apply, so a production
install is two applies, **both with `identity_binding = "oidc"`** and the production posture:
apply 1 carries a placeholder `oidc_redirect_uri` (the value is read only during sign-in, never
at boot or by the readiness probe, so the install comes up healthy with it), then read
`frontend_url`, register `https://<frontend host>/api/auth/callback` at your IdP, set
`oidc_redirect_uri` to it and apply again. [`examples/production/`](../examples/production/) does
exactly this. Do not bring a production install up with `identity_binding = "dev"` and switch to
`oidc` afterwards: that second apply would change identity and everything else production
requires — Key Vault with purge protection, which cannot be turned off, the control-plane store,
Redis — at once, on a running install.

### ca-frontend on your own domain (`frontend_custom_domain`)

Null by default, which binds no hostname and creates nothing: `ca-frontend` answers on its
Container Apps FQDN, as before the input existed. Set it and `ca-frontend` also answers on your
hostname, with your own certificate, both on a public environment and on an internal one
(`aca_internal_load_balancer = true`) behind your Application Gateway:

```hcl
frontend_custom_domain = {
  hostname                        = "masterly.example.com"
  certificate_key_vault_secret_id = "https://kv-contoso-certs.vault.azure.net/secrets/masterly-example-com"
  key_vault_id                    = "/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/kv-contoso-certs"
}
```

- **The certificate stays in your vault.** The module takes a reference, the certificate's
  secret id **without a version**, and no certificate, key or password: none enters Terraform
  or its state. The Container App Environment reads the certificate from the vault itself, and
  because the reference names no version it picks up a certificate you renew in the vault
  without an apply. A versioned id, or a `/certificates/` URL, is refused at plan.
- **A dedicated identity reads it.** The module creates `id-<prefix>-frontend-cert`, attaches it
  to the Container App Environment and to no app, and grants it **Key Vault Secrets User** on
  the certificate's secret alone, never on the vault. It is not the frontend's identity: the
  frontend is the app an attacker reaches first, and a read on the certificate would hand them
  your hostname's private key.
- **The vault** must use Azure RBAC authorization, and must be reachable from the Container App
  Environment: a vault that admits only private endpoints the environment cannot reach, or a
  firewall that does not admit it, fails the certificate at apply. The module does not change
  your vault's network.
- **The deploying identity** needs the right to create that role assignment on the vault
  (`Microsoft.Authorization/roleAssignments/write`): **Owner**, **User Access Administrator** or
  **Role Based Access Control Administrator** on the vault or the secret. A subscription-scope
  grant of one of those covers it when the vault is in the install's subscription. Entra role
  assignments propagate eventually, so a first apply can fail on the certificate inside that
  window; re-run the apply.
- **The binding** is an SNI binding of exactly your hostname to `ca-frontend`. It changes
  nothing else about the app: `ingress_allowed_cidrs` applies to the hostname as to the FQDN,
  and ingress stays HTTPS-only.
- **`frontend_url`** becomes `https://<hostname>`, and on `identity_binding = "oidc"` the
  frontend's redirect URI is `https://<hostname>/api/auth/callback`.
- **The TXT record comes first.** Azure checks the `asuid.<hostname>` TXT record when it binds
  the hostname, during the first apply. Its value is the `custom_domain_verification_id` output,
  and can be read from your subscription before that apply. The A or CNAME record that routes
  the hostname points at your gateway, or at the environment once it exists.
  [docs/networking.md](networking.md#ca-frontend-on-your-own-domain) lists both records,
  when each can be created, and the Application Gateway settings.

Certificates managed by Container Apps are not offered: Azure cannot issue one on an internal
environment.

### Built-in authentication in front of the frontend (`builtin_auth`)

`identity_binding` decides how the **application** signs a caller in. `builtin_auth` adds a
second, independent gate at the **platform**: Container Apps built-in authentication (often
called EasyAuth) with Microsoft Entra ID, on `ca-frontend`, and on `ca-api` once you turn on
`builtin_auth_api`. A browser without an Entra sign-in for your tenant is redirected to Entra
sign-in before it reaches the frontend, and a user who passes it still has to sign in to the
application, which decides the member and their roles. Neither layer relies on the other. Unset
(the default), the module configures none.

| App | Unauthenticated request | Who is admitted |
|---|---|---|
| `ca-frontend` | Redirected to Entra sign-in | Users of `tenant_id` signing in through `client_id`. `frontend_excluded_paths` (empty by default) are served without sign-in. |
| `ca-api`, `builtin_auth_api = false` (the default) | Not gated | The module configures no built-in auth on the api. |
| `ca-api`, `builtin_auth_api = true` | `401`, on every path, with no redirect | Tokens for the audience `client_id` issued to `ca-frontend`'s workload identity (`id-<prefix>-frontend`) and, with `edge` set, `ca-edge`'s (`id-<prefix>-edge`). Nothing else: not a browser sign-in through `client_id`, and no other identity of the install. No path is excluded. |
| `ca-edge`, `builtin_auth_edge = false` (the default) | Not gated at the platform | Envoy alone answers: `jwt_authn` (`edge.jwt_authn`) on the machine paths, and `404` elsewhere. |
| `ca-edge`, `builtin_auth_edge = true` | `401`, with no redirect, on every path but the machine paths | Tokens issued to `client_id` by the issuer in `oidc_allowed_issuers`. `/v1`, `/v1/*`, `/mcp`, `/.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp` reach Envoy without one. |

Without `builtin_auth_api` the module gates the frontend only. The api is reached internally: the
frontend's server-side calls go to `ca-api` inside the Container Apps environment, and the module
puts no platform gate on it; the application authenticates its callers as `identity_binding`
sets. With `api_ingress_external = true` the api is also published to `ingress_allowed_cidrs`,
and this gate does not cover it there either; a plan that sets both warns through the check
`builtin_auth_does_not_gate_the_published_api`, on every plan while both are set and
`builtin_auth_api` is not.

`api_allowed_applications` and `api_allowed_audiences` configured a gate on `ca-api` in 0.19.0
and 0.19.1. They are deprecated and ignored, and `builtin_auth_api` does not read them: a plan
that sets either succeeds and warns (`builtin_auth_api_entries_are_ignored`). Remove them from
`builtin_auth`.

#### The api's gate (`builtin_auth_api`)

`builtin_auth_api = true` (ADR 0120 §2) puts the platform gate on `ca-api` too. It validates
tokens against `builtin_auth`'s registration, so it requires `builtin_auth`, and a caller requests
its token for the audience `builtin_auth.client_id`, the bare client id: Easy Auth always admits a
registration's own client id as an audience, and the module adds no other. Only `ca-frontend`'s
and `ca-edge`'s workload identities are allowed applications: a browser's ID token for the same
registration carries that audience but is refused, because the registration itself is not one of
them. Every other request gets `401`; no path is excluded: a path that must be reached without
this token, such as a webhook, is for `ca-edge`'s proxy in front of the api to exempt, never for
the api's gate. The application still authenticates every caller as `identity_binding` sets.

- **Off by default. Turn it on only after the callers send their token.** With it on, `ca-api`
  refuses every request that does not carry `ca-frontend`'s or `ca-edge`'s workload-identity
  token. On a `ca-frontend` or `ca-edge` release that does not yet send that token, every call the
  frontend's server makes on a user's behalf is refused, and the application is unusable until the
  switch is turned off again, as happened with 0.19.x on 2026-10-22. Upgrade both apps to releases
  that send it first, then turn this on. The `ca-api` release must also verify the token and
  accept empty edge and recovery client ids (below), or it refuses to start.
- **The module wires both ends of the token.** With the switch on, `ca-frontend` gets
  `MASTERLY_API_AUDIENCE` (`builtin_auth.client_id`) and `AZURE_CLIENT_ID` (its own identity's
  client id, so a token request is not ambiguous when `registry_identity_id` gives it a second
  identity), and requests the token for that audience. `ca-api`, and `ca-workers`, which shares its
  environment, get the trust the application verifies the token against (ADR 0119):
  `MASTERLY_WORKLOAD_ISSUER` (the gate's `https://login.microsoftonline.com/<tenant>/v2.0`),
  `MASTERLY_WORKLOAD_JWKS_URI` (`…/<tenant>/discovery/v2.0/keys`),
  `MASTERLY_WORKLOAD_API_AUDIENCE` (the same audience), `MASTERLY_WORKLOAD_FRONTEND_CLIENT_ID`,
  `MASTERLY_WORKLOAD_EDGE_CLIENT_ID` (`ca-edge`'s identity with `edge`, empty without it),
  `MASTERLY_WORKLOAD_RECOVERY_CLIENT_ID` (empty until `ca-recovery` exists), and
  `MASTERLY_L1_TOKEN_REQUIRED = "true"`. Off, none of them is set. `MASTERLY_SERVE_AUDIENCE` is
  left unset until `ca-serve` has a gate of its own.
- **The registration must issue v2.0 access tokens.** Set `requestedAccessTokenVersion` to `2`
  in the app registration's manifest (`api.requestedAccessTokenVersion` in the Microsoft Graph
  form). Without it Entra issues v1 tokens, whose issuer is `https://sts.windows.net/<tenant>/`,
  and the application refuses every workload token.
- **The registration must be in the deployment's tenant.** The workload identities' tokens come
  from the tenant the module deploys to, so `builtin_auth.tenant_id` must be that tenant; a plan
  where it is not warns through the check `builtin_auth_tenant_is_the_deployment_tenant`.
- **A broken gate is alerted on.** With the switch on, `alert-<name_prefix>-api-401` (severity 1)
  fires when `ca-api` returns more than 20 responses with status 401 in 15 minutes, which is what
  a wrong allowed-client list looks like. It routes through `alert_email` or
  `alert_action_group_id`, does not need `enable_diagnostics`, and also counts the application's
  own 401s, which are occasional and sit below the threshold.
- **Nothing else moves.** `ca-api` carries `builtin_auth_client_secret` whenever `builtin_auth` is
  set, so turning the switch on or off changes the env above, a new revision of each of the three
  apps, and the api's `authConfigs/current` (`module.masterly.azapi_resource.builtin_auth["api"]`,
  the address 0.19.0 and 0.19.1 used), and nothing else on them.
- **The recovery fallback turns it off too.** While `builtin_auth_recovery_until` is open, at most
  60 minutes and only behind a network restriction, it turns this gate off along with
  `ca-frontend`'s, so that under an Entra outage a caller reaches `ca-api` with the application's
  own authentication alone in front of it (ADR 0117, amended 2026-11-02). Only the gate changes:
  the rest of the api's configuration, its ingress and its environment stay as they are, and
  `MASTERLY_L1_TOKEN_REQUIRED` stays `"true"`, so a request in the window that carries no workload
  token is refused by the application until it learns the window (MAS-5233, MAS-5228). Every
  write to the api's auth configuration raises the activity-log alert
  `alert-<prefix>-api-auth-config-write`, which exists whenever the switch is on. See
  [Recovery fallback](#recovery-fallback-turning-the-gates-off-builtin_auth_recovery_until).
- **A hand-made configuration is imported once.** An install that configured built-in auth on
  `ca-api` by hand imports it in the first apply that sets `builtin_auth_api`, as for the frontend
  below, with `["api"]` and the api's `authConfigs/current`.

#### ca-edge's backstop (`builtin_auth_edge`)

`builtin_auth_edge = true` (ADR 0120, as amended by ADR 0117 and clarified on 2026-11-22) puts a
default-deny gate on `ca-edge`, behind Envoy's own token check. The platform lets the machine
paths through without a token, because Envoy's `jwt_authn` validates them, and answers `401`,
with no redirect, to every other request that does not carry a token issued to
`builtin_auth.client_id` by the issuer in `oidc_allowed_issuers`. Off (the default), the module
configures nothing on `ca-edge`.

- **Exactly five paths are excluded.** An excluded path matches exactly, and `<path>/*` matches
  the whole tree below it but never a sibling. So `/v1` and `/v1/*` let through `/v1` and
  everything under it, but not `/v1x`. `/mcp` lets through that path only, so a path below
  `/mcp` is refused at the platform. `/.well-known/oauth-protected-resource` and
  `/.well-known/oauth-protected-resource/mcp` are let through. `/` and every other path answer
  `401`. Set `edge.jwt_authn` with it: the platform does not check a token on these paths, so
  without `jwt_authn` nothing in front of `ca-api` does.
- **It requires `builtin_auth`, `edge` and a single-tenant issuer.** The gate trusts the issuer
  Envoy's `jwt_authn` trusts, so `oidc_allowed_issuers` (or `oidc_tenant_id`) must be exactly
  one `https://login.microsoftonline.com/<tenant id>/v2.0`. A plan without `builtin_auth` or
  `edge`, or with a list of issuers, `organizations`, `common`, a v1 or a non-Entra issuer, is
  refused. That tenant should be `builtin_auth.tenant_id`: a plan where it is not warns through
  the check `builtin_auth_edge_tenant_is_builtin_auth_tenant`, because a registration lives in
  one tenant.
- **No secret.** `ca-edge` serves no browser sign-in, so its registration names no client secret
  and `ca-edge` carries none. Like the frontend's, its gate admits only tokens issued to the
  registration itself.
- **The recovery fallback never turns it off.** `builtin_auth_recovery_until` turns off
  `ca-frontend`'s gate and `ca-api`'s, never this one.
- **Alerted.** Every write to `ca-edge`'s auth configuration raises the activity-log alert
  `alert-<prefix>-edge-auth-config-write`, which exists whenever the switch is on.
- **Nothing else moves.** Turning the switch on or off adds or removes `ca-edge`'s
  `authConfigs/current` (`module.masterly.azapi_resource.builtin_auth["edge"]`) and the alert;
  `ca-edge`'s container app, its Envoy configuration, and the other gates stay as they are.

To set it up, use an app registration in your tenant (one you already use for built-in auth is
fine; the module takes over its configuration):

1. Add `https://<frontend host>/.auth/login/aad/callback` as a **Web** redirect URI and enable
   **ID tokens**.
2. Add a client secret and pass it as `builtin_auth_client_secret`. The module stores it as the
   Container App secret `microsoft-provider-authentication-secret` (a Key Vault reference with
   `enable_key_vault`), the name Azure gives it. It is on `ca-frontend`, which uses it, and also
   on `ca-api`, which uses it with `builtin_auth_api` and carries it either way, so that turning
   the switch on or off, or upgrading from 0.19.0 or 0.19.1, never moves the secret.
3. Set `builtin_auth = { tenant_id = "...", client_id = "..." }`, with the tenant the module
   deploys to.
4. Before `builtin_auth_api`: set `requestedAccessTokenVersion` to `2` in the registration's
   manifest, so the workload tokens are v2.0.

An install that already configured built-in auth on the frontend by hand imports that
configuration once, in the first apply that sets `builtin_auth`, or the apply fails because it
already exists:

```hcl
import {
  to = module.masterly.azapi_resource.builtin_auth["frontend"]
  id = "/subscriptions/<subscription id>/resourceGroups/<aca resource group>/providers/Microsoft.App/containerApps/ca-frontend/authConfigs/current"
}
```

**Upgrading from 0.19.0 or 0.19.1.** Those versions also configured `ca-api`. Unless you set
`builtin_auth_api = true`, the first plan on this version destroys that one resource,
`module.masterly.azapi_resource.builtin_auth["api"]` (the api's `authConfigs/current`), and
changes nothing else: the frontend's configuration, both apps and their secrets stay as they are.
Set `builtin_auth_api = true` to keep it only once ca-frontend and ca-edge send their
workload-identity token; before that it refuses every BFF call (see
[The api's gate](#the-apis-gate-builtin_auth_api)). If your configuration still has the
`for_each` import block those versions documented, with `"api"` in it, narrow it to the frontend
as above or delete it first: without `builtin_auth_api = true`, an import block for `["api"]`
names an instance this version does not have, and the plan fails. An install that configured
built-in auth on `ca-api` by hand and never imported it keeps that configuration; remove it in
the portal (the app's **Authentication** page) if you want the api reached without it.

#### Behind a reverse proxy (`builtin_auth.forward_proxy`)

With a proxy that replaces `Host` in front of `ca-frontend`, such as Azure Front Door, set
`forward_proxy = { convention = "Standard" }` in `builtin_auth`, so the gate builds its sign-in
callback from `X-Forwarded-Host`. Unset, the body is written exactly as before and nothing changes
on upgrade. [Behind a reverse proxy](networking.md#behind-a-reverse-proxy-azure-front-door-a-gateway)
has the whole topology, including why it must be set only when every request comes through the
proxy.

#### Recovery fallback: turning the gates off (`builtin_auth_recovery_until`)

When users cannot pass the platform sign-in, for example during an Entra outage, and no other way
in is available, `builtin_auth_recovery_until` turns `ca-frontend`'s built-in authentication off,
and with `builtin_auth_api` `ca-api`'s too, until a time you set, so that a browser reaches the
application's own sign-in, including its break-glass path. Set it to an RFC 3339 UTC time, such as
`2026-11-14T15:30:00Z`, and apply.

- **At most 60 minutes.** A time more than 60 minutes after the plan is refused. To extend the
  window, plan and apply again with a new time.
- **Only behind a network restriction.** It is refused unless something besides the gate limits
  who reaches the frontend: a non-empty `ingress_allowed_cidrs`,
  `frontend_ingress_external = false`, or `aca_internal_load_balancer = true`. It is also refused
  without `builtin_auth`.
- **The api's gate with `builtin_auth_api`, and nothing else.** Without `builtin_auth_api`,
  `ca-api` has no gate and the window changes nothing on it. With it, the window turns the api's
  gate off as well: under an Entra outage neither `ca-frontend`'s nor `ca-edge`'s
  workload-identity token can be issued, so the gate would otherwise refuse every call. Only the
  gates' `platform.enabled` changes; the rest of both configurations, and `ca-api`'s ingress and
  environment, stay as they are, so the application is not told the gate is off and its own
  authentication stays in front. Relaxing the api's own sign-in check during an Entra outage is
  not set by this input. A published `ca-api` (`api_ingress_external`) always sits behind
  `ingress_allowed_cidrs`.
- **Restored at the next plan, not at the time itself.** Terraform does not run on its own: the
  gates come back at the first plan and apply after the time has passed. Run that apply as soon
  as the window ends. A plan that still sets a passed time turns the gates back on and warns
  through the check `builtin_auth_recovery_window_has_expired`; remove the input then.
- **Alerted both ways.** With `builtin_auth` set, the module creates the activity-log alert
  `alert-<prefix>-frontend-auth-config-write`, which fires on every write to `ca-frontend`'s auth
  configuration and notifies the install's action group (`alert_email` or
  `alert_action_group_id`). With `builtin_auth_api`, it also creates
  `alert-<prefix>-api-auth-config-write`, which does the same for `ca-api`'s. Both exist for as
  long as their gate does, not only during a window. They fire on the disable and the restore,
  any change made outside Terraform, and also an apply that changes `builtin_auth` itself;
  confirm each one was intended. The api's alert covers every write after it exists, not the
  apply that turns `builtin_auth_api` on or off: turning it on creates the alert and `ca-api`'s
  configuration in the same apply, so that first write can land before the alert does, and
  turning it off deletes the configuration and the alert together. With `builtin_auth_edge`,
  `alert-<prefix>-edge-auth-config-write` does the same for `ca-edge`'s, which the window never
  writes.

The configuration is written with the `Azure/azapi` provider, because azurerm has no resource
for it; the same provider starts the [migrate job](data-plane.md#the-migrate-job) at apply. The module
requires that provider whether or not you set `builtin_auth`, so an
air-gapped install mirrors it alongside azurerm, random, tls and time.

### The BFF's DPoP key (`enable_bff_dpop_key`)

The frontend's BFF proves possession of a key (DPoP) on every call it makes to the api for a
signed-in user, and the api binds each session to the key that proved its sign-in. With
`enable_bff_dpop_key = true` the module generates that key and hands it to `ca-frontend` alone:

- **What the frontend reads.** `MASTERLY_BFF_DPOP_KEY`, an EC P-256 private key in PKCS#8 PEM, and
  during a rotation `MASTERLY_BFF_DPOP_KEY_PREVIOUS`, the outgoing key. With the input off (the
  default) the frontend generates a key per process, so a DPoP-bound session does not survive a
  restart and cannot move between frontend replicas.
- **Which releases read it.** The key takes effect with the first frontend release after v0.145.0,
  and the api's session binding and DPoP replay cache arrive with the first api release after
  v0.137.0; on earlier images the key is set but unread. The input is off by default, so installs
  on 0.24.0's images are unaffected apart from the two new required providers.
- **Rotation every 90 days, at an apply.** The key is held in two slots, each replaced by its own
  timer, so a new key takes over every 90 days. A timer expires on the clock, but the key is
  replaced by the first apply after that: an install nobody applies keeps its key. Each rotation
  rolls `ca-frontend` twice, once when the new key arrives and once when the outgoing key is
  removed.
- **A 60-minute overlap.** For 60 minutes after a rotation the outgoing key stays on `ca-frontend`
  as `MASTERLY_BFF_DPOP_KEY_PREVIOUS`, so sessions bound to it (renewed within 15 minutes) survive
  the change; the first apply after those 60 minutes removes it. With the vault on, ACA re-reads a
  versionless Key Vault reference within 30 minutes, which the 60 minutes cover.
  Applying at least monthly keeps the slots about 90 days apart. If a slot expires inside the
  other slot's overlap, the older key's overlap is shortened to the gap between the two rotations;
  the key that was current immediately before the second rotation becomes `_PREVIOUS`. If both
  slots expire before the next apply, both keys are replaced together without retaining the
  outgoing key, and users must sign in again once.
- **Where the key is held.** With `enable_key_vault = true` each slot is a vault secret
  (`install-bff-dpop-key-a`, `install-bff-dpop-key-b`) that `ca-frontend` references by its
  versionless URL as its own identity, which holds Key Vault Secrets User on those two secrets
  alone, never on the vault. Both secrets stay for as long as the input is on: a rotation writes a
  new version, and never deletes a secret that purge protection would then keep the name of.
  Without the vault the key is a Container App secret on `ca-frontend`. `ca-api`, `ca-workers` and
  `caj-migrate` carry neither: the api checks each proof against the session's binding and reads
  no BFF key.
- **The private key is in Terraform state**, as the other secrets the module generates are, so
  whoever can read the state can read the key. With the vault on, the apps identity's app secrets
  role on the vault (and ca-workers' own, when it has one) can read these secrets too, as it can
  every install secret there.
- **Two more providers.** The key and its timers use `hashicorp/tls` and `hashicorp/time`. The module
  requires both whether or not the input is on, so a calling configuration's `terraform init`
  installs them, and an air-gapped install mirrors them.
- **The api's replay cache.** The api keeps a cache of DPoP proofs it has seen. Its target is Azure
  Managed Redis (`enable_redis` with `redis_offering = "managed"`); without Redis the cache is in
  memory and allowed on one api replica only, which is why `api_max_replicas > 1` requires
  `enable_redis`.

## Workload identities: one per role (ADR 0120 §6)

Each part of the install runs as a user-assigned managed identity of its own, holding only the
grants that part uses, so a compromised app reaches no more than its own role needs. `<prefix>` is
`name_prefix`. With `acr_id` set, the module grants `AcrPull` to each identity below that pulls an
image; with `acr_id` null, grant it yourself to the matching `*_identity_principal_id` output.
With `registry_identity_id` set, none of them pulls: every app and job also carries that identity,
which you created and granted pull yourself, and pulls as it, and the module grants `AcrPull` to
none of the identities below, whatever `acr_id` says. Each still runs as itself: its grants,
`AZURE_CLIENT_ID`, Key Vault references and database role are unchanged, and the `AcrPull` in the
table below is then not held.

| Identity | Runs | Holds | Never holds |
|---|---|---|---|
| `id-<prefix>-frontend` | `ca-frontend` | `AcrPull`; Key Vault Secrets User on each of its own secrets only | Any vault-scope role, Service Bus, Redis, ACS, database access |
| `id-<prefix>-apps` | `ca-api` | `AcrPull`; the app secrets role on the vault; the signing key reader role on the vault (`keys/read`: a key's public half, for the audit signing-key, export and verify routes); on the audit vault, the signing key reader role and the audit head reader role (`getSecret`); Service Bus Data Sender; ACS Email Owner; on `redis_auth = "entra"` a Redis data access policy; with `migrations = "job"` on the starter server, the DML-only database role `masterly_api` | Key Vault Crypto Officer or any key create or sign right; Service Bus receive; with `migrations = "job"`, any Postgres administrator |
| `id-<prefix>-workers` | `ca-workers` | `AcrPull`; the app secrets role and the signing keys role on the vault; the signing keys role on the audit vault; Service Bus Data Sender and Data Receiver, and Data Owner on the jobs queue only while `ca-workers` scales on it; ACS Email Owner; on `redis_auth = "entra"` a Redis data access policy; with `migrations = "job"` on the starter server, the DML-only database role `masterly_workers` | Key Vault Crypto Officer; any Postgres administrator |
| `id-<prefix>-migrate` | `caj-migrate`, with `migrations = "job"`; attached to no Container App and no ingress | `AcrPull`; Key Vault Secrets User on each of its own secrets and on the BYO-DB secrets named in `migrate_byo_database_secret_names`; on `database_auth = "entra"`, the starter server's only Microsoft Entra administrator | Any vault-scope role, any key right, Service Bus, Redis, ACS |
| `id-<prefix>-edge` | `ca-edge`, with `edge` set | `AcrPull` at most, for an image on the install's registry | Data, queue, secret or key rights |

The vault roles are four roles the module defines on the data resource group, each with an
install-unique name, instead of the built-in Key Vault Secrets Officer and Crypto Officer, which
also carry purge, backup, restore, recover and rotate:

| Role | Data actions | Held by |
|---|---|---|
| `Masterly app secrets (<prefix>-<suffix>)` | `secrets/getSecret/action`, `secrets/setSecret/action`, `secrets/delete`, `secrets/readMetadata/action` | `id-<prefix>-apps`, `id-<prefix>-workers` |
| `Masterly signing key reader (<prefix>-<suffix>)` | `keys/read` | `id-<prefix>-apps` |
| `Masterly signing keys (<prefix>-<suffix>)` | `keys/create/action`, `keys/read`, `keys/sign/action`, `secrets/getSecret/action`, `secrets/setSecret/action` | `id-<prefix>-workers` |
| `Masterly audit head reader (<prefix>-<suffix>)` | `secrets/getSecret/action` | `id-<prefix>-apps`, on the audit vault only |

The first three are assigned on the install's vault. ADR 0120's amendment of 2026-10-25 asks for
the erasure and audit grants to reach those names alone. A role assignment cannot name a key that
does not exist yet, the application creates each signing key at runtime, and Key Vault's conditions
cover secret actions only, so that scope needs a vault holding only those objects.

**Audit checkpoint vault.** The module provisions the **audit vault**, `kva-<prefix>-<suffix>`,
for the key `audit-checkpoint-signing-<env>` and the secret `audit-checkpoint-head-<env>`: the
infrastructure portion of ADR 0033 §10 and ADR 0120 §6. The protection takes effect only once an
application release reads `MASTERLY_AUDIT_KEYVAULT_URL`. Until then, the audit key and head remain
in the main vault under its existing grants. The module change alone does not move them or remove
`ca-api`'s main-vault secret-write access; application support requires a separate release.

On the audit vault the core worker pool's identity holds the signing keys role. With workers on
their own identity, `id-<prefix>-apps` holds the signing key reader role and the audit head reader
role, `keys/read` and `getSecret` in total. Once a supporting application release uses this vault,
these grants prevent `ca-api` from signing a checkpoint or overwriting the head there. No other
principal and no built-in role is granted there. The module sets its URI on `ca-api` and
`ca-workers` as `MASTERLY_AUDIT_KEYVAULT_URL` and publishes the output `audit_key_vault_uri`.
Terraform writes nothing into it, so `key_vault_deployer_ip_rules` does not open it: in production
its public endpoint stays off.

The erasure names do not have one yet, so on the install's vault the signing roles reach every key,
which holds no keys besides its Environments' signing keys, and neither role can delete or purge
one. Defining the roles needs `Microsoft.Authorization/roleDefinitions/write` on the data resource
group: Owner or User Access Administrator, not Role Based Access Control Administrator.
`scripts/preflight.sh --principal <deployer object id>` checks it.

**The signing keys need api v0.138.0 or later on `ca-api`.** From that release only the workers
process creates and signs with them; on an earlier api image `ca-api` still does, and with only key
read erasure fails. With the Key Vault on, the plan refuses an `api_image` tagged below v0.138.0
(the release channel's default is checked through `MANIFEST.json`), and warns when the reference
names no tag it can read, such as a digest alone.

**`ca-api` keeps ACS Email Owner.** api v0.138.0 sends organization invitations and notification
verification codes from `ca-api` itself, while it handles the request, so the grant stays with
`ca-api` until a release moves those emails to the workers.

**Without the vault and with `acr_id` null**, where the apps pull from a registry as their
identities and you grant AcrPull yourself, `ca-workers` also stays on `id-<prefix>-apps`:
`id-<prefix>-workers` would be created in the apply that moves `ca-workers` to it, before you could
grant it AcrPull. Set `acr_id` or `registry_identity_id`, or turn the vault on, and it moves.

**The one shape where two apps share an identity in production.** With `migrations = "start"` and
`database_auth = "entra"` on the starter server, both `ca-api` and `ca-workers` migrate at start
and sign in to Postgres as the server's Entra administrator, `id-<prefix>-apps`, so `ca-workers`
runs as that identity, which then also holds the signing keys role (key signing and secret-write
permissions on both the main and audit vaults), Service Bus Data Receiver and the jobs
queue's Data Owner. This is a departure from ADR 0120 §6, and in `mode = "production"`
every plan warns about it (the check `production_migrations_at_start`). `migrations = "job"`, what
a new production install sets, removes it: see
[The migrate job](data-plane.md#the-migrate-job).
