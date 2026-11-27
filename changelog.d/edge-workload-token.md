### Added

- Field `edge.workload_token` (bool, **off by default**): `ca-edge` sends its own
  workload-identity token to `ca-api` (layered authentication, ADR 0120 §2). With it on, on `/v1`
  (the ca-serve routes included) and `/mcp`, after `jwt_authn` has validated the caller, Envoy
  moves the caller's `Authorization` value, scheme included, to `X-Masterly-Credential` and sets
  `Authorization: Bearer <token>`, requested from the app's managed identity endpoint as
  `id-<prefix>-edge` for the audience `builtin_auth.client_id` and cached per Envoy worker until 5
  minutes before it expires. The caller's `DPoP` header is forwarded unchanged. A plan that sets
  it without `builtin_auth` and `builtin_auth_api = true`, or without `edge.jwt_authn`, is
  refused. Turn it on in the same apply as `builtin_auth_api`. With it on, `ca-edge` starts Envoy
  through a short `/bin/sh` script that reads the endpoint's address from `IDENTITY_ENDPOINT`, so
  a mirrored `edge.image` must keep the upstream image's `/bin/sh` and `sed`.
- The check `builtin_auth_api_edge_sends_its_workload_token`: with `builtin_auth_api = true` and
  `edge` set but `edge.workload_token` off, a warning that `ca-api`'s gate answers every SDK, REST
  and MCP call through `ca-edge` with `401`.

### Security

- With `edge.workload_token` on, a request that already carries `X-Masterly-Credential` is
  refused with `400` at the edge, before any token is fetched, so a caller cannot choose the
  credential the application reads as its own. When no token can be had, `ca-edge` answers `503`
  and the request never reaches `ca-api`: the caller's token is never sent on in `Authorization`.
  The routes `ca-edge` answers itself (`413`, `404`) never fetch or carry the token. Neither the
  token nor `IDENTITY_HEADER` is in the configuration, the plan or the access log, and the image's
  entrypoint still runs Envoy as the unprivileged `envoy` user.
- Off (the default), nothing changes: `ca-edge`'s container args, its Envoy configuration
  included, plan exactly as before.
