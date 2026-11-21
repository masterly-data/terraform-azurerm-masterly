### Added

- **`edge.jwt_authn`: token validation on `ca-edge`, off by default.** Unset (null, the default),
  `ca-edge` is configured exactly as before and does no authentication of its own. Set it to
  `{ audiences = [...] }` and `ca-edge` validates the bearer token in the `Authorization` header on
  `/v1` (the ca-serve routes included) and `/mcp` before forwarding: signed by the install's Entra
  tenant's keys, unexpired, issued by that one tenant and carrying one of `audiences`. A request
  with no token or a token that fails is answered `401` by the edge and never reaches `ca-api`; a
  token that passes reaches `ca-api` unchanged, and `ca-api` still checks it. The edge trusts
  exactly one issuer: with `edge.jwt_authn` set, the plan is refused unless
  `oidc_allowed_issuers` is the single `https://login.microsoftonline.com/<tenant GUID>/v2.0` and
  `oidc_jwks_uri` is that tenant's `/discovery/v2.0/keys` (as `oidc_tenant_id` sets them), and
  unless `audiences` lists at least one non-empty value. `ca-edge` then reaches
  `login.microsoftonline.com` on 443 itself for the signing keys, through `egress_firewall` when
  that is set. The rate limits are unchanged. Setting it rolls a new `ca-edge` revision; see
  `docs/networking.md`.
