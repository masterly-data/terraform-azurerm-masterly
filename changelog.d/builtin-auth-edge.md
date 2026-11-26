### Added

- Input `builtin_auth_edge` (bool, **off by default**): Container Apps built-in authentication on
  `ca-edge` as a default-deny backstop behind Envoy (ADR 0120, as amended by ADR 0117 and
  clarified 2026-11-22). With it on, the platform answers `401`, with no redirect, to every
  request without a token issued to `builtin_auth.client_id` by the issuer in
  `oidc_allowed_issuers`, on every path except the machine paths Envoy's `jwt_authn` validates:
  `/v1`, `/v1/*`, `/mcp`, `/.well-known/oauth-protected-resource` and
  `/.well-known/oauth-protected-resource/mcp`. An excluded path matches exactly and `/v1/*` the
  tree below `/v1`, so with it on the platform refuses `/mcp/<sub>` paths, `/v1x` and `/`.
  `ca-edge`'s registration names no client secret and `ca-edge` carries none, and
  `builtin_auth_recovery_until` never turns this gate off. A plan that sets it without
  `builtin_auth`, without `edge`, or without `oidc_allowed_issuers` (or `oidc_tenant_id`) naming
  exactly one `https://login.microsoftonline.com/<tenant id>/v2.0` is refused, and one whose
  issuer tenant is not `builtin_auth.tenant_id` warns.
- With `builtin_auth_edge`, the activity-log alert `alert-<name_prefix>-edge-auth-config-write`
  on every write to `ca-edge`'s auth configuration, routed like the frontend's and `ca-api`'s.

### Security

- Off (the default), nothing changes: no auth configuration on `ca-edge`, and the frontend's
  and `ca-api`'s gates, `ca-edge`'s container app and its Envoy configuration plan exactly as
  before.
