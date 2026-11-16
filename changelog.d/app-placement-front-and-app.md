### Added

- `frontend_environment`, `edge_environment` and `api_environment` (default `"aca"` each) choose
  where `ca-frontend`, `ca-edge` and `ca-api` run (ADR 0120 §4-§5). With the defaults, an install
  plans no change. The three move together: either all three stay `"aca"`, or
  `frontend_environment = "front"`, `edge_environment = "front"` and `api_environment = "app"`.
  Any other mix is refused at plan, as is a placement on an install that has no front and app
  environments.
- With the apps moved, `ca-frontend` and `ca-edge` call `ca-api` at
  `https://ca-api.<app environment default domain>` and verify its certificate. The BFF's
  `MASTERLY_API_BASE_URL` uses that address. The edge's Envoy cluster connects on 443 through an
  upstream TLS context: the host as SNI, the chain checked against the image's CA bundle, and the
  certificate's DNS name matched. `ca-api` in the app environment, which is always internal, takes
  VNet-only ingress and refuses plain HTTP. `api_ingress_external = true` is refused there.
  The name resolves through the app environment's private DNS zone. With
  `environment_private_dns_enabled = false`, your hub must create that zone and its record.
- With `ca-frontend` on the front environment and the Key Vault private endpoint on, the
  private-endpoint NSG gains one rule, `allow-key-vault-from-front-subnet`. It admits the front
  subnet to the endpoint's own address (/32) on TCP 443 only, so the front reaches no database,
  Redis or Service Bus. `ca-frontend` still reads only its own secrets, as its own identity.
- `modules/aca-env-workload-profiles` takes `identity_ids` and outputs `identity_ids` and
  `custom_domain_verification_id`, as `modules/aca-env-consumption` does.
  `modules/aca-container-app` outputs `environment_id`.

### Changed

- Setting the three inputs REPLACES `ca-frontend`, `ca-edge` and `ca-api`, a destroy then create
  with downtime. Their FQDNs change, and with them `frontend_url` and `edge_url`. The
  custom-domain certificates and custom domains are created again on the front environment, and
  the certificate identities move from `aca-<name_prefix>` to it.
  `custom_domain_verification_id` then reads the front environment's, so the `asuid.<hostname>`
  TXT records must carry the new value before the apply that moves the apps. Plan the move on a
  test install first.
- On an injected network (`aca_subnet_id` and `private_endpoints_subnet_id`), the module creates
  no private-endpoint NSG. Before moving `ca-frontend` to the front environment, the hub must
  admit the front subnet to the Key Vault private endpoint on TCP 443, or the frontend cannot
  resolve its vault secret references.
- `egress_firewall` is refused with any of the three apps off `"aca"`. The route table is attached
  to snet-aca only, and the front and app environment subnets get no route table, so the moved
  apps' egress would not be forced.
