# Production install

A complete `mode = "production"` install: OIDC against your own identity provider, Key
Vault, Redis, dedicated pipeline workers, a highly-available Postgres, and a
scaled-out api.

The full walkthrough — Azure prerequisites, quota lead times, upgrades and rollback —
is at **[masterlydata.com/docs/self-hosted](https://masterlydata.com/docs/self-hosted/install/)**.
This example is the Terraform half.

## What you need first

From your Masterly install bundle: `org_id`, the registry pull credential, the licence
JWT, and `license-issuer.jwk.json` (place it beside this example, or point `file()`
somewhere else). From your own directory: an app registration for Masterly's sign-in.

`mode = "production"` is gated at **plan** time. If any of it is missing, Terraform
refuses before touching Azure and names what is absent.

## Two applies, not one

Without a custom domain the frontend hostname is an **output** of the first apply, so it
cannot be registered at your IdP beforehand.

1. Apply with `oidc_redirect_uri` left at its placeholder default.
2. Read `frontend_url`, register `https://<host>/api/auth/callback` at your IdP.
3. Set `oidc_redirect_uri` and apply again.

Apply 1 comes up healthy in full production posture — that value is read only during
sign-in, never at boot and never by the readiness probe — so the second apply changes
one environment variable rather than flipping the install's whole posture.

## Secrets

Supply them as environment variables, not in a file:

```bash
export TF_VAR_registry_password='...'
export TF_VAR_license_token='...'
export TF_VAR_oidc_client_secret='...'
```

`*.tfvars` is gitignored in this repository on purpose. Note also that **Terraform state
holds every one of these in plaintext** — treat the state backend as a secrets store:
Entra-only auth, versioning on, RBAC scoped to the principal that deploys.

## Reading the plan

The first apply creates roughly 40 resources. Two worth checking before you approve:

- **Postgres** — `GP_Standard_D2ds_v5` with zone-redundant HA is two servers' worth of
  compute. Confirm your vCore quota covers it; a fresh subscription commonly starts at 0.
- **`redis_offering`** — this example sets `"managed"`. If you already run an Azure Cache
  for Redis and mean to keep it, set `"cache"`; applying `"managed"` over it plans a
  destroy of your running session store.
