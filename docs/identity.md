# Identity

How the install authenticates its users and which identity each part of it runs as (ADR 0024):
the identity adapter, `ca-frontend` on your own domain, and the built-in authentication in front of
the frontend.

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
called EasyAuth) with Microsoft Entra ID, on `ca-frontend` only. A browser without an Entra
sign-in for your tenant is redirected to Entra sign-in before it reaches the frontend, and a user
who passes it still has to sign in to the application, which decides the member and their
roles. Neither layer relies on the other. Unset (the default), the module configures none.

| App | Unauthenticated request | Who is admitted |
|---|---|---|
| `ca-frontend` | Redirected to Entra sign-in | Users of `tenant_id` signing in through `client_id`. `frontend_excluded_paths` (empty by default) are served without sign-in. |
| `ca-api` | Not gated | The module configures no built-in auth on the api. |

The module gates the frontend only. The api is reached internally: the frontend's server-side
calls go to `ca-api` inside the Container Apps environment, and the module puts no platform gate
on it; the application authenticates its callers as `identity_binding` sets. With
`api_ingress_external = true` the api is also published to `ingress_allowed_cidrs`, and this gate
does not cover it there either; a plan that sets both warns through the check
`builtin_auth_does_not_gate_the_published_api`, on every plan while both are set.

`api_allowed_applications` and `api_allowed_audiences` configured a gate on `ca-api` in 0.19.0
and 0.19.1. They are deprecated and ignored: a plan that sets either succeeds and warns
(`builtin_auth_api_entries_are_ignored`). Remove them from `builtin_auth`.

To set it up, use an app registration in your tenant (one you already use for built-in auth is
fine; the module takes over its configuration):

1. Add `https://<frontend host>/.auth/login/aad/callback` as a **Web** redirect URI and enable
   **ID tokens**.
2. Add a client secret and pass it as `builtin_auth_client_secret`. The module stores it as the
   Container App secret `microsoft-provider-authentication-secret` (a Key Vault reference with
   `enable_key_vault`), the name Azure gives it. It is on `ca-frontend`, which uses it, and also
   on `ca-api`, which carried it while 0.19.0 and 0.19.1 gated the api and keeps it so that
   upgrading changes neither app.
3. Set `builtin_auth = { tenant_id = "...", client_id = "..." }`.

An install that already configured built-in auth on the frontend by hand imports that
configuration once, in the first apply that sets `builtin_auth`, or the apply fails because it
already exists:

```hcl
import {
  to = module.masterly.azapi_resource.builtin_auth["frontend"]
  id = "/subscriptions/<subscription id>/resourceGroups/<aca resource group>/providers/Microsoft.App/containerApps/ca-frontend/authConfigs/current"
}
```

**Upgrading from 0.19.0 or 0.19.1.** Those versions also configured `ca-api`. The first plan on
this version destroys that one resource, `module.masterly.azapi_resource.builtin_auth["api"]`
(the api's `authConfigs/current`), and changes nothing else: the frontend's configuration, both apps
and their secrets stay as they are. If your configuration still has the `for_each` import block
those versions documented, with `"api"` in it, narrow it to the frontend as above or delete it
first: an import block for `["api"]` names an instance this version no longer has, and the plan
fails. An install that configured built-in auth on `ca-api` by hand and never imported it keeps
that configuration; remove it in the portal (the app's **Authentication** page) if you want the
api reached without it.

The configuration is written with the `Azure/azapi` provider, because azurerm has no resource
for it; the same provider starts the [migrate job](data-plane.md#the-migrate-job) at apply. The module
requires that provider whether or not you set `builtin_auth`, so an
air-gapped install mirrors it alongside azurerm and random.
