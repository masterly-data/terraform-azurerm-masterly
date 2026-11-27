### Added

- Input `builtin_auth_opt_out` (`object({ reason = string })`, **null by default**): the recorded
  decision to run a `mode = "production"` install without `builtin_auth`, the platform sign-in
  gate on `ca-frontend`. Every plan with it warns, quoting the reason. Refused with an empty or
  blank reason, and together with `builtin_auth`. In `mode = "demo"` it is accepted and has no
  effect.

### Changed

- **Breaking:** `mode = "production"` is the security profile (ADR 0117 item 10, decision 3 of
  MAS-4424): a production plan is refused unless `builtin_auth` or `builtin_auth_opt_out` is set.
  **Migration note, a production install without `builtin_auth`:** the next plan is refused. Set
  `builtin_auth` and `builtin_auth_client_secret` (the variable's description says what to
  register: `https://<frontend host>/.auth/login/aad/callback` on the app registration), or set
  `builtin_auth_opt_out = { reason = "..." }` to record why the install runs without the gate;
  each plan then warns and quotes the reason.
- **Breaking:** `api_ingress_external = true` is refused at plan without `edge`, in every mode:
  `ca-api` is reachable from outside only through `ca-edge`. With `edge` set `ca-api` stays
  internal whatever `api_ingress_external` says, a plan that sets it warns that it is ignored,
  and the `api_url` output is null. **Migration note, `api_ingress_external = true` without
  `edge`:** the next plan is refused. Set `edge = {}` (with `ingress_allowed_cidrs` listing the
  networks your clients call from), move the Python SDK and other clients outside the
  environment from `api_url` to the `edge_url` output (`/v1` and `/mcp` under it reach
  `ca-api`), and set `api_ingress_external = false`. An install that already sets `edge` and
  `api_ingress_external = true` loses direct access to `ca-api`, whose ingress is updated in
  place to internal: its clients move to `edge_url` too.
- **Breaking:** in production, `builtin_auth.frontend_excluded_paths` unset means `["/",
  "/start"]`, the start page, instead of `[]`, and any other list is refused. In demo, unset
  still means `[]` and any list of absolute paths is accepted. **Migration note, the production
  excluded paths become `["/", "/start"]`:** a production install with `builtin_auth` and
  `frontend_excluded_paths` unset sees `ca-frontend`'s auth configuration updated in place to
  exclude `/` and `/start`. Those two paths are then served without the platform sign-in gate
  (the network allowlist and the application's own sign-in still apply), so the frontend
  release you run should serve `/` as a pure redirect and `/start` as a self-contained page
  (ADR 0117 decisions 2 and 3). A production install that sets any other list is refused:
  remove `frontend_excluded_paths`.

### Security

- Every published app is HTTPS only, and the plan refuses otherwise: an app with external
  ingress and plain HTTP is refused by the Container App submodule, and `ca-edge` carries a
  postcondition. `ca-api`'s internal `http://ca-api` hop in the runtime environment, which the
  environment's mutual TLS encrypts, still allows it.
- In demo, with or without `builtin_auth`, nothing changes: `ca-api`'s ingress, the frontend's
  excluded paths and the auth configurations plan exactly as before.
