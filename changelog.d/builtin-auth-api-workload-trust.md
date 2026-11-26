### Added

- With `builtin_auth_api = true`, the module wires both ends of the workload token `ca-api`'s gate
  admits (ADR 0120 §2, ADR 0119). `ca-frontend` gets `MASTERLY_API_AUDIENCE`
  (`builtin_auth.client_id`) and `AZURE_CLIENT_ID` (`id-<name_prefix>-frontend`'s client id), so
  it requests the token as its own identity even when `registry_identity_id` attaches a second
  one. `ca-api`, and `ca-workers`, which shares its env, get `MASTERLY_WORKLOAD_ISSUER` (the gate's
  `https://login.microsoftonline.com/<builtin_auth.tenant_id>/v2.0`),
  `MASTERLY_WORKLOAD_JWKS_URI` (`…/<tenant>/discovery/v2.0/keys`),
  `MASTERLY_WORKLOAD_API_AUDIENCE` (the same audience), `MASTERLY_WORKLOAD_FRONTEND_CLIENT_ID`,
  `MASTERLY_WORKLOAD_EDGE_CLIENT_ID` (`ca-edge`'s identity with `edge`, the empty string without
  it), `MASTERLY_WORKLOAD_RECOVERY_CLIENT_ID` (the empty string until `ca-recovery` exists,
  MAS-2979) and `MASTERLY_L1_TOKEN_REQUIRED = "true"`.
- The check `builtin_auth_tenant_is_the_deployment_tenant`: with `builtin_auth_api`, a plan whose
  `builtin_auth.tenant_id` is not the tenant the module deploys to warns, because the workload
  identities' tokens then never match the trust.

### Changed

- Turning `builtin_auth_api` on or off now changes the env of `ca-frontend`, `ca-api` and
  `ca-workers` (a new revision of each), where it changed neither app before. With it off (the
  default) none of the settings above is set and nothing plans differently.
- **Audience: the bare client id.** Easy Auth always admits its registration's own client id as an
  audience, the module passes no `allowed_additional_audience`, and a v2.0 token requested for the
  bare GUID carries it as `aud`. An `api://<client_id>` form would need an additional audience on
  the gate, which the module does not add. The live check that the gate accepts it belongs to the
  test install (MAS-4469).
- **`MASTERLY_L1_TOKEN_REQUIRED` goes on with the gate**, as the layered-authentication design
  (§18, M4: "the same deployment turns `MASTERLY_L1_TOKEN_REQUIRED` on") and ADR 0119's
  2026-11-07 amendment ("It turns on at M4") say. With it on, the application refuses a request
  that carries no workload token whatever the module tells it about L1, so ADR 0119's open
  question 1 does not arise with the setting on.
- **The recovery window's expiry does not reach `ca-api` yet.** `builtin_auth_recovery_until`
  still changes nothing in `ca-api`'s env, and `MASTERLY_L1_TOKEN_REQUIRED` stays `"true"` in the
  window, so until MAS-5233 and MAS-5228 hand the application the window's expiry, a request in
  the window without a workload token is refused at L2 rather than let through.
- `MASTERLY_SERVE_AUDIENCE` stays unset everywhere: `ca-serve` has no gate yet (MAS-3192).

### Security

- **Prerequisite: v2.0 access tokens.** `builtin_auth.client_id`'s app registration must have
  `requestedAccessTokenVersion = 2`. Without it Entra issues v1 tokens
  (`iss = https://sts.windows.net/<tenant>/`) and the application refuses every workload token,
  so every call from `ca-frontend` is refused.
- **Release dependency.** Turn `builtin_auth_api` on only with an api release that verifies the
  workload token and accepts empty `MASTERLY_WORKLOAD_EDGE_CLIENT_ID` and
  `MASTERLY_WORKLOAD_RECOVERY_CLIENT_ID` (MAS-5562), and a frontend release that sends it. An
  api release that requires all six settings non-empty refuses to start.
- An absent role is the empty string, never another identity's client id, so no token from the
  apps, workers or migrate identity is admitted as `ca-edge` or `ca-recovery`. Every new value is a
  public identifier (client ids, a tenant issuer, a JWKS URI); the change adds no output, no
  diagnostic setting and no secret.
