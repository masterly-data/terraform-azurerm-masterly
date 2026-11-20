# Network topologies

The module serves three topologies from one artifact. There is no per-customer fork: a fork
means the next security fix has to be applied in as many places as you have customers.

Everything below is additive — the default is topology 1, and an install already running it
stays on it without changing a line.

| | Who owns the network | Reached from | Set |
|---|---|---|---|
| **1. Public ingress** (default) | the module | the internet, narrowed by `ingress_allowed_cidrs` | nothing |
| **2. Private ingress** | the module | VPN / ExpressRoute only | `aca_internal_load_balancer = true` |
| **3. Hub-and-spoke** | your platform team | whichever of the above the spoke allows | `aca_subnet_id` + `private_endpoints_subnet_id` |

Topologies 2 and 3 compose: a spoke with an internal load balancer is the common enterprise
landing-zone shape.

## 1. Public ingress behind an allowlist

The default. The module creates a VNet from `vnet_address_space`, the runtime subnet
`snet-aca`, the private-endpoint subnet, the three environment subnets `snet-front`, `snet-app`
and `snet-workers` (see [The environment subnets](#the-environment-subnets)), private
endpoints for Postgres, Key Vault, and Redis, and the private DNS zones those need. With
`registry_private_endpoint = true` (the `managed_identity` and `customer_registry` registry
modes, with `acr_id` set) it adds one more: a private endpoint to your registry's `registry`
subresource, and a `privatelink.azurecr.io` zone linked to the VNet, so image pulls stay on the
VNet. It is refused with `frontend_environment = "front"` (see the private-endpoint NSG below).

`ingress_allowed_cidrs` narrows who can reach the frontend. **An empty list means
unrestricted, not deny-all** — that is Azure's semantics, not ours, and it is the one default
here worth being deliberate about.

## 2. Private ingress — VPN or ExpressRoute only

```hcl
aca_internal_load_balancer = true
```

The Container App Environment gets an internal load balancer and **no public endpoint**. The
apps answer only inside the VNet.

Leave `frontend_ingress_external` at `true`. On an internal environment `external` means
"reachable from the VNet", not "reachable from the internet" — setting it false leaves the
frontend reachable from nothing at all, including your VPN. The module refuses that
combination at plan rather than letting you discover it after an apply.

**What you must provide:** private resolution for the environment's default domain — a private
DNS zone for it, linked to your VNet. Azure does not create that for you, and without it the
frontend resolves to nothing from inside the network.

`oidc_redirect_uri` must be the host your users actually reach, and your identity provider
must be able to redirect a browser there. A private host is fine — the browser resolves it,
not the IdP — but the IdP must still have it registered. With `frontend_custom_domain` set the
module derives it from your hostname; see [ca-frontend on your own domain](#ca-frontend-on-your-own-domain).

## 3. Hub-and-spoke — join a network you already own

```hcl
aca_subnet_id               = "/subscriptions/.../virtualNetworks/vnet-spoke/subnets/snet-aca"
private_endpoints_subnet_id = "/subscriptions/.../virtualNetworks/vnet-spoke/subnets/snet-pe"
```

The module creates **no VNet and no subnets**. Your platform team keeps ownership of the spoke,
which is usually the point.

One caveat on permissions: if the module still creates the privatelink DNS zones, it has to
**link them to your VNet**, and that needs rights on the VNet. Inject the zones as well (below)
and it needs nothing on your network at all — that combination is the one to ask for if your
platform team is counting the permissions they grant.

Both are required together — half an injected network is refused at plan. The VNet is derived
from the subnet id, so the two can never disagree.

**What the subnets must be:**

- `aca_subnet_id` — **/23 or larger**, delegated to `Microsoft.App/environments`. Azure refuses
  the environment otherwise, and the module cannot delegate a subnet it does not own.
- `private_endpoints_subnet_id` — a **different** subnet. A delegated subnet cannot hold
  private endpoints, so these cannot be the same subnet; the module refuses that at plan too.
  Leave private endpoint network policies **enabled** on it if you want the NSG rules below to
  apply to the endpoints — disabled, they are there and inert.
- `front_subnet_id`, `app_subnet_id` and `workers_subnet_id` (optional; all three or none) —
  the [environment subnets](#the-environment-subnets): each **/27 or larger**, delegated to
  `Microsoft.App/environments`, in the **same VNet** as `aca_subnet_id`, and three subnets of
  their own: none of them may be another of them, `aca_subnet_id` or
  `private_endpoints_subnet_id`. The module refuses each of those at plan. It cannot check a
  subnet's size without reading your spoke, so the size is yours to get right.

**Centralised private DNS.** If your hub owns the privatelink zones, inject them and the module
creates neither the zone nor the VNet link — linking the hub zone to this spoke is your
platform team's side:

```hcl
postgres_private_dns_zone_id  = "/subscriptions/.../privateDnsZones/privatelink.postgres.database.azure.com"
key_vault_private_dns_zone_id = "/subscriptions/.../privateDnsZones/privatelink.vaultcore.azure.net"
redis_private_dns_zone_id     = "/subscriptions/.../privateDnsZones/privatelink.redis.azure.net"

# Only used by a private Service Bus namespace (servicebus_sku = "Premium" in production).
servicebus_private_dns_zone_id = "/subscriptions/.../privateDnsZones/privatelink.servicebus.windows.net"
```

Each is independent: inject the ones your hub owns and let the module create the rest.

The registry's endpoint has no zone input: `registry_private_endpoint` always creates its own
`privatelink.azurecr.io` zone and links it to the spoke. A virtual network links to only one
zone of a name, so if your hub already links `privatelink.azurecr.io` to this spoke, leave
`registry_private_endpoint` off and have your platform team add the registry's private endpoint
(subresource `registry`) on their side, in the hub zone.

## Egress

By default the install's outbound traffic takes Azure's default path: the module's NSGs carry
inbound rules only, so Azure's `AllowInternetOutBound` applies. To send all of it through your
own firewall instead (forced tunnelling), route the Container Apps subnet's `0.0.0.0/0` to the
firewall. Your firewall then decides what passes, and it must admit the destinations
[listed below](#what-your-firewall-must-admit).

| Topology | How |
|---|---|
| 1: public ingress | Not offered: `egress_firewall` is refused at plan while `aca_internal_load_balancer = false` ([why](#forced-tunnelling-needs-an-internal-environment)). Make the environment internal and publish the frontend through your Application Gateway, which is topology 2 |
| 2: the module builds the network, internal environment (`aca_internal_load_balancer = true`) | `egress_firewall = { next_hop_ip = "10.0.0.4" }`: the module creates `rt-<name_prefix>-aca` in `rg-<name_prefix>-aca` with one route, `0.0.0.0/0` to that address as a virtual appliance, and attaches it to `snet-aca`. Or `egress_firewall = { route_table_id = "/subscriptions/.../routeTables/<name>" }`: the module attaches your route table to `snet-aca` as it is, and creates none |
| 3: injected subnets | Your platform team attaches the hub's route table (`0.0.0.0/0` to the firewall) to the injected ACA subnet, and to `workers_subnet_id` before `workers_environment` or `migrate_job_environment` is set to `"workers"`. `egress_firewall` is refused at plan there: a subnet holds one route table, and the module attaching its own would replace the hub's. The module creates no route table and no association on injected subnets, so the one the hub attached is never touched |

The `egress_route` output shows the route table in effect and the next-hop address, and is null
when `egress_firewall` is unset.

**Only on a workload-profiles environment.** Azure ignores a route on a Container Apps
environment that reports no workload profile, so egress would stay open while you believe it is
filtered. The module therefore refuses `egress_firewall` unless the environment's subnet is delegated to
`Microsoft.App/environments` and Azure lists at least one workload profile on the environment.
Every environment the module builds meets both (ADR 0104): its subnet is delegated, and on a
delegated subnet Azure creates a workload-profiles environment with the `Consumption` profile
filled in. For an existing environment the module reads the profiles at plan, and for a new one
at apply, after Azure has created it. To check an environment yourself:

```sh
az containerapp env show \
  --ids "$(terraform output -raw aca_environment_id)" \
  --query properties.workloadProfiles
```

A list with a profile of type `Consumption` is a workload-profiles environment; `null` or an empty
list is an environment without workload profiles. The `terraform output` form needs your root
configuration to re-export the module's `aca_environment_id` output (`output "aca_environment_id" { value =
module.<name>.aca_environment_id }`). Without that, use `-n aca-<name_prefix> -g
rg-<name_prefix>-aca` instead of `--ids`. The output is null once `aca-<name_prefix>` is retired
([Retiring the runtime environment](#retiring-the-runtime-environment)), and `egress_firewall` is
refused by then, since every move off `aca-<name_prefix>` refuses it. On an injected subnet, run the
same check before your platform team attaches the hub's route table.

**The private endpoints are unaffected.** No route goes on `snet-private-endpoints`: it has
private endpoint network policies enabled, under which a route table there would apply to
private-endpoint traffic as well and send the data plane's replies through the firewall. The
apps' traffic to Postgres, Key Vault, Redis, a private Service Bus namespace and the registry's
private endpoint stays inside the VNet, where the VNet's own route is more specific than
`0.0.0.0/0` and wins over it. Your firewall needs no rule for any of them.

**BGP route propagation stays on** in the module's route table. Routes a VPN or ExpressRoute
gateway propagates (topology 2's clients, over a peered hub's gateway) are more specific than
`0.0.0.0/0` and keep winning over it, so replies to those clients go back the way their requests
came rather than through the firewall, where a stateful firewall would drop them. A route table
of your own (`route_table_id`) needs the same.

**On a running install**, the route applies as soon as the apply attaches it. Open the
destinations below on your firewall first. **On a fresh install** the module attaches the route
once Azure has created the environment (that is when the workload-profile check can run). It
creates `ca-api`, `ca-frontend`, `ca-workers`, `ca-edge` (with `edge` set) and `caj-migrate` only after that, so their first
image pull, migration run, database connection and outbound call already go through the
firewall. Only the environment's own provisioning, before the attachment, can take Azure's
default path. Where nothing may leave except through the firewall from the first connection,
use injected subnets with the hub's route table already attached (topology 3).

### Forced tunnelling needs an internal environment

`egress_firewall` is refused at plan unless `aca_internal_load_balancer = true`. What Microsoft
Learn documents, read on 2026-11-14:

- [Securing a virtual network in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/firewall-integration)
  and [Control outbound traffic with user defined routes](https://learn.microsoft.com/azure/container-apps/user-defined-routes)
  support user-defined routes on workload-profiles environments only. The locked-down shape they
  describe is an internal environment behind an Application Gateway, with a route to the firewall
  on the environment's subnet.
- Learn's page on network security groups for Container Apps says that on an external
  workload-profiles environment, inbound traffic arrives through a public IP in the
  environment's managed resource group, not through the subnet.
- No page documents public ingress combined with `0.0.0.0/0` to a firewall.

Our reading, not Learn's: replies to internet clients must leave by the path their requests came
in on, and nothing documented says they do once the subnet's default route points at a stateful
firewall. The module therefore does not offer that combination. Topology 2 has no public endpoint, so the
question does not arise there. To publish the frontend to the internet with egress forced, put
your Application Gateway in front of the internal environment (`frontend_custom_domain`, see
"Behind an Application Gateway" under
[The record that routes the hostname](#the-record-that-routes-the-hostname)).

### What your firewall must admit

Every destination the Container Apps subnet reaches outside the VNet, with what reaches it and
what fails when the firewall drops it. Hosts written as an input are the host of that input's
URL.

| Destination | When the install reaches it | What fails when it is blocked |
|---|---|---|
| The Container Apps outbound set: the FQDNs and service tags in Microsoft's [Securing a virtual network in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/firewall-integration), including Microsoft Container Registry and Microsoft Entra ID | Always: the environment's own platform components | The environment provisions but cannot start a replica: each revision stays with no ready replica. Microsoft versions the set, so it is not copied here |
| Microsoft Entra ID for managed identities (`login.microsoftonline.com`, service tag `AzureActiveDirectory`; part of the set above) | Always: the apps' identities get tokens for the registry (`managed_identity` and `customer_registry` modes), Key Vault references (`enable_key_vault`), and Postgres and Redis with `database_auth = "entra"` | Every pull, secret reference or database sign-in that uses an identity fails: a new revision has no ready replica, or the apps cannot open their database connection |
| The image registry: its login server (`masterly.azurecr.io` by default, or `registry_location`) and its data endpoint (`<registry>.<region>.data.azurecr.io` with dedicated data endpoints, otherwise the registry's `*.blob.core.windows.net` storage; see [Configure rules to access an Azure container registry behind a firewall](https://learn.microsoft.com/azure/container-registry/container-registry-firewall-access-rules)) | Always, **unless** `registry_private_endpoint = true`, which keeps pulls on the registry's private endpoint in the VNet | The image pull fails: a new revision (a fresh install, an upgrade or a restart onto a new replica) has no ready replica, and `ContainerAppSystemLogs` records the failed pull |
| Docker Hub (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`) | `edge` set with `edge.image` unset: `ca-edge` pulls the upstream Envoy image anonymously | `ca-edge`'s image pull fails, so its revision has no ready replica. Mirror the image instead (see [Where the edge's image comes from](#where-the-edges-image-comes-from)) |
| Your identity provider's issuer and its endpoints: the discovery document under `oidc_authority`, the token endpoint it names, and the signing keys at `oidc_jwks_uri` (all `https://login.microsoftonline.com/<tenant>/...` when only `oidc_tenant_id` is set) | `identity_binding = "oidc"`: `ca-frontend`'s BFF signs users in against the authority, and `ca-api` fetches the signing keys. With `builtin_auth`, Azure's built-in authentication on `ca-frontend` reaches the same IdP | With the token endpoint or discovery document unreachable, sign-in fails with an error after the IdP redirects back. With the keys unreachable, `ca-api` cannot validate a token, so authenticated requests are refused |
| Masterly's control plane: the host of `license_issuer_url` | `license_issuer_url` set (licence refresh) | Licence refresh fails. After seven days without a successful refresh the install is read-only: reads, exports and sign-in continue, writes are refused, until refresh succeeds again |
| Masterly's control plane: the host of `telemetry_url` | `telemetry_url` set (fleet telemetry) | Usage reports do not reach the control plane. Licence refresh is a separate call (ADR 0074) and is not affected |
| Azure Monitor (service tag `AzureMonitor`) | Always: the environment sends the apps' console and system logs through Azure Monitor (`logs_destination = "azure-monitor"`) | New rows stop arriving in `ContainerAppConsoleLogs` and `ContainerAppSystemLogs`, so the log-search alerts and the diagnostic bundle see nothing new while the apps keep serving |
| Key Vault (`<vault>.vault.azure.net`) | `enable_key_vault` outside `mode = "production"`, where the vault keeps public network access. In production it is reached over its private endpoint | A revision whose secrets are Key Vault references does not start: it has no ready replica |
| Your Key Vault holding the frontend or edge certificate | `frontend_custom_domain` or `edge_custom_domain` set, unless that vault has a private endpoint the environment reaches | The environment cannot read the certificate, so the binding of your hostname fails, at the first apply or at the next certificate rotation |
| Service Bus (`<namespace>.servicebus.windows.net`, TCP 5671 and 443) | `enable_service_bus` with a public namespace: any SKU outside production, and Standard in production. A Premium namespace in production is private | The apps cannot open their Service Bus connection, so work handed over the bus does not run |
| Azure Communication Services (`*.communication.azure.com`) | `email_acs_enabled` | Email is not sent |
| Your own Postgres: the host and port of `external_database_url`, and of `external_database_admin_url` where it names another host | `external_database_url` set (the module provisions no server and no private endpoint) and the server is outside the VNet. A server reached over peering or a private endpoint in the VNet stays off the route | `ca-api` and `ca-workers` cannot open their database connection, so no revision becomes ready. With `migrations = "job"`, `caj-migrate` fails too, and a fresh install never completes its migrations |
| Targets you configure in the application: webhooks, an SMTP relay, a BYO-DB Environment's database, stream push endpoints, a local AI endpoint | Each target you configure | That one feature's call fails; the rest of the install is unaffected |

The platform claims above come from Microsoft Learn:
[Networking in Azure Container Apps environment](https://learn.microsoft.com/azure/container-apps/networking)
(the environment types),
[Control outbound traffic with user defined routes](https://learn.microsoft.com/azure/container-apps/user-defined-routes)
(routes are honoured on workload-profiles environments only), and
[Securing a virtual network in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/firewall-integration)
(the required outbound set).

## ca-frontend on your own domain

`frontend_custom_domain` binds your hostname to `ca-frontend` with your certificate from your
Key Vault, in any of the three topologies (docs/identity.md's
[ca-frontend on your own domain](identity.md#ca-frontend-on-your-own-domain-frontend_custom_domain)
has the input and what it creates). The module creates no DNS record, gateway or Front Door:
you create the records below, in your own DNS, and the gateway if you put one in front.

### Before the first apply

1. **The `asuid.<hostname>` TXT record.** Azure checks it when it binds the hostname, which is
   during the first apply, so it must exist and resolve before you run it. Its value is the
   Container Apps custom-domain verification id. Azure derives it from the subscription, not
   from the environment, so you can read it before the environment exists:

   ```sh
   az rest --method post \
     --url "https://management.azure.com/subscriptions/<subscription id>/providers/Microsoft.App/getCustomDomainVerificationId?api-version=2024-03-01"
   ```

   The response is the id, as a JSON string. After the apply the module's `custom_domain_verification_id` output carries the same value
   (`terraform output -raw custom_domain_verification_id`; it is marked sensitive because the
   provider marks it, and it is not a secret). For `masterly.example.com` the record is
   `asuid.masterly.example.com TXT <that value>`.
2. **Your IdP's redirect URI**, `https://<hostname>/api/auth/callback`, on `identity_binding =
   "oidc"`. The module sets the same value on the frontend, so nothing changes after the apply.
3. **Read on the certificate for the environment's identity is the module's**, but the deploying
   identity must be allowed to create that role assignment on the vault: Owner, User Access
   Administrator or Role Based Access Control Administrator there. The vault must use Azure RBAC
   authorization and be reachable from the Container App Environment; the module does not change
   your vault's network.

If the first apply stops at the binding with a domain-verification error, Azure did not find a
record it checks: the TXT record is missing or has not propagated yet, or, without a gateway,
Azure wants the routing record below as well, which can only point at the environment once the
apply has created it. Create or fix the record and apply again. Everything else, including the
redirect URI, is already in place and does not change, so nothing has to be edited.

### The record that routes the hostname

**Without a gateway** (topology 1, or topology 2 reached directly over the VPN): point the
hostname at the environment, with either

- a **CNAME** to `ca-frontend`'s Container Apps FQDN, `ca-frontend.<environment default
  domain>` (`az containerapp show -n ca-frontend -g rg-<name_prefix>-aca --query
  properties.configuration.ingress.fqdn -o tsv`), or
- an **A** record to the environment's static IP (`az containerapp env show -n
  aca-<name_prefix> -g rg-<name_prefix>-aca --query properties.staticIp -o tsv`).

Both targets exist only once the environment does, so this record follows the first apply; the
hostname answers once it resolves. On topology 2 the record goes in the private DNS your VPN
clients resolve, not in public DNS.

**Behind an Application Gateway** (topology 2, `aca_internal_load_balancer = true`): the public
record points at the gateway, an **A** record to its frontend public IP or a **CNAME** to its DNS
name, and can exist before the first apply because the gateway is yours. Set the gateway up so
that the request reaches `ca-frontend` under your hostname, because the environment picks the
app and the certificate by it:

| Gateway setting | Value |
|---|---|
| Listener | HTTPS on 443 for your hostname, with your certificate (the gateway can read the same Key Vault secret) |
| Backend pool | The environment's static IP (`properties.staticIp`, above), reachable from the gateway's subnet |
| Backend settings: protocol and port | **HTTPS**, 443. Not HTTP: `ca-frontend` takes HTTPS only, and port 80 answers with a redirect |
| Backend settings: host name | **Keep your hostname** as the backend host: "pick host name from incoming request", or override it with your hostname itself. Never the default domain or the IP: the environment would not route the request to `ca-frontend` |
| Backend settings: trusted certificate | Your certificate's issuer; "well-known CA certificate" when a public CA issued it, otherwise upload your private root |
| Health probe | HTTPS, host = **your hostname**, path **`/api/healthz`** (`ca-frontend`'s liveness path), healthy on 200-399 |

`ingress_allowed_cidrs` applies to the hostname as it does to the FQDN, and behind a gateway the
address `ca-frontend` sees is the gateway's: include the gateway subnet's range in it, and do the
per-client narrowing on the gateway. The `snet-aca` NSG admits `VirtualNetwork` on 443 on an
internal environment, which covers a gateway in the same VNet or a peered one.

## Network security baseline

Every subnet the module creates carries a network security group, and each one ends in an
explicit inbound deny. That deny is the point. A subnet with **no** NSG is not closed — it
inherits Azure's default rules, which allow everything the `VirtualNetwork` service tag
covers: this VNet, every network peered to it, and every on-premises range reachable through
a gateway attached to it. On a spoke somebody later peers into a wider estate, that is a door
that opens by itself.

**`snet-aca`**, the Container Apps infrastructure subnet:

| Priority | Access | Source | Protocol / ports | Why |
|---|---|---|---|---|
| 100 | Allow | `Internet` — or `VirtualNetwork` with `aca_internal_load_balancer = true` | TCP 80, 443 | Reach the apps. 80 carries Azure's 301 to `https://`, so dropping it turns that redirect into a timeout |
| 110 | Allow | `AzureLoadBalancer` | TCP 30000-32767 | Container Apps platform requirement: the platform's load balancer reaches the environment on the ephemeral range |
| 120 | Allow | `snet-aca` | any | Container Apps platform requirement: traffic within the infrastructure subnet |
| 4000 | Deny | any | any | Everything not admitted above |

**`snet-private-endpoints`**:

| Priority | Access | Source | Protocol / ports | Why |
|---|---|---|---|---|
| 100 | Allow | `snet-aca` | TCP 443, 5432, 6380, 10000 | Key Vault and the registry's private endpoint (443), Postgres, Azure Cache for Redis, Azure Managed Redis |
| 110 | Allow | `snet-app` | the same ports | The app environment (present with the [environment subnets](#the-environment-subnets)) |
| 120 | Allow | `snet-workers` | the same ports | The workers environment (likewise) |
| 130 | Allow | `snet-front` | TCP 443, to the Key Vault private endpoint's address (/32) only | Only with `frontend_environment = "front"` and the vault's private endpoint: `ca-frontend` resolves its vault secret references |
| 4000 | Deny | any | any | Everything not admitted above |

`snet-front` is otherwise never a source here: the front environment is the one that faces your
users, and the internet when it is external, so it opens no connection to Postgres, PgBouncer,
Redis or Service Bus. Its one exception (ADR 0120 amendment, 2026-11-16) is the Key Vault
private endpoint's own address on 443, and only once `ca-frontend` runs there; reaching the vault
grants no secret, since `ca-frontend` reads its own secrets only, as its own identity. Once
`ca-frontend` runs there, it does pull its image from the front subnet. With
`registry_private_endpoint` the registry resolves to its private endpoint, which this NSG does
not admit from `snet-front`, so the plan refuses `frontend_environment = "front"` with
`registry_private_endpoint = true`, on either network shape.
On an injected network the module creates no NSG here, so your hub must admit the front subnet to
the Key Vault private endpoint on 443 before moving `ca-frontend`. The `snet-aca` rule stays for
as long as the apps run there.

The module sets `private_endpoint_network_policies = "Enabled"` on that subnet, without which
an NSG on a private-endpoint subnet does not apply to private-endpoint traffic at all. Note
that this governs route tables there as well: a user-defined route attached to that subnet
begins to apply to private-endpoint traffic too.

Azure Managed Redis picks "an available port" rather than guaranteeing 10000, so when that
offering is enabled the module reads the real port from the database and admits it alongside.

A private Service Bus namespace (`enable_service_bus = true` with `servicebus_sku = "Premium"`
in `mode = "production"`) adds TCP 5671, AMQP over TLS, which is how the apps' Service Bus
client connects. Its AMQP-over-WebSockets fallback uses 443, which the rule already admits.

`postgres_pgbouncer = true` adds TCP 6432, the starter server's built-in PgBouncer, which
listens on the same private endpoint as Postgres; the apps' `MASTERLY_DATABASE_URL` goes there.
With injected subnets the rule is the operator's: admit 6432 before turning the input on, or
the apps cannot reach the pooler, and remove it only after the apps have rolled back to 5432.

**No outbound rules.** Azure's default `AllowInternetOutBound` stays. Container Apps needs
a long, Microsoft-versioned egress set — image pull, Microsoft Container Registry, Entra ID,
Azure Monitor — and a copy of it written into this module would go stale into an environment
that provisions and then cannot start a replica. Egress is narrowed by routing it through your
firewall, not by an NSG; see [Egress](#egress) above.

**The allowlist still does the narrowing.** `ingress_allowed_cidrs` is enforced by Container
Apps ingress, and it is deliberately not what the NSG's source says: an empty list is a legal
configuration meaning *unrestricted*, and an NSG rule cannot express an empty source — it
would have to become a deny, turning a documented default into an outage. The NSG is a second
layer under the allowlist, not a replacement for it.

### The environment subnets

The install is moving from one Container Apps environment in `snet-aca` (`aca-<name_prefix>`) to
three workload-profiles Container Apps environments, each in a subnet of its own (ADR 0120):
**front** (the frontend, the one environment callers reach), **app** (the api, reached only from
the front) and **workers** (no inbound caller). The subnets sit beside `snet-aca`, which keeps
serving the apps until they move. The placement inputs below move them, and
`retire_runtime_environment` then deletes `aca-<name_prefix>` once nothing runs in it. `snet-aca`,
its NSG and the private-endpoint rule from it stay in this version: the environment is retired,
the subnet is not yet. [Retiring the runtime environment](#retiring-the-runtime-environment) gives
the order.

On a network the module builds, `front_subnet_prefix`, `app_subnet_prefix` and
`workers_subnet_prefix` set the three ranges, all three or none, each /27 or larger, inside
`vnet_address_space` and clear of every other subnet; the plan refuses anything else. With none
set and a first VNet prefix of /21 or larger, the module takes the /24s at index 5, 6 and 7 of
it: `10.20.5.0/24`, `10.20.6.0/24` and `10.20.7.0/24` on the default `10.20.0.0/16`, beside
`snet-aca` (`10.20.0.0/23`) and the private-endpoint subnet (`10.20.4.0/24`). A smaller VNet, or
explicit `aca_subnet_prefix` and `private_endpoints_subnet_prefix` that already cover those
/24s, gets no environment subnets until the three prefixes are set. The `environment_subnet_ids`
and `environment_subnet_prefixes` outputs carry what was created.

Each subnet holds its environment, `aca-<name_prefix>-front`, `aca-<name_prefix>-app` and
`aca-<name_prefix>-workers`, each declaring the `Consumption` workload profile and sending its
console and system logs to the install's workspace. The app and workers environments always have
an internal load balancer; the front has one exactly when `aca_internal_load_balancer = true`, so
an install that is private today gets no public front. By default no app runs in them: every app,
the migrate job and the custom-domain certificates stay on `aca-<name_prefix>`, which plans no
change.

`frontend_environment = "front"`, `edge_environment = "front"` and `api_environment = "app"`,
set together, move `ca-frontend` and `ca-edge` to the front environment and `ca-api` to the app
environment; any other mix is refused. The custom-domain certificates and their identities follow
the frontend and the edge, and `custom_domain_verification_id` then reads the front environment's.
The callers reach `ca-api` at `https://ca-api.<app environment default domain>` and verify its
certificate: the BFF through `MASTERLY_API_BASE_URL`, the edge through an upstream TLS context
that checks the chain and the host name. `ca-api` takes VNet-only ingress there and refuses plain
HTTP. The move replaces the three apps (new FQDNs, downtime between destroy and create), so plan
it on a test install first. `egress_firewall` is refused with the apps moved, because only
`snet-aca` gets its route table.

Two workloads can be placed in the workers environment, each with its own input:
`ca-workers` with `workers_environment = "workers"`, and `caj-migrate` (with `migrations = "job"`)
with `migrate_job_environment = "workers"`. Each keeps its identity, env and secrets, `ca-workers`
its scale rule, and neither has ingress. Changing either input replaces that workload under the same name, on the
module's api image, so run CD's release again afterwards; a replaced `caj-migrate` also runs once
at apply. An install whose `environment_subnet_ids` are all null gets none of the three
environments, and the plan refuses any of these placement inputs set off `aca-<name_prefix>`
there.

Once every placement is off `aca-<name_prefix>`, `retire_runtime_environment = true` deletes it
and its diagnostic setting. On an existing install, make the moves and the retirement in the
order [Retiring the runtime environment](#retiring-the-runtime-environment) gives, one apply each.

An internal environment's default domain resolves only through a private DNS zone. With
`environment_private_dns_enabled` at its default (`true`), the module creates, for each internal
environment, a zone in `rg-<name_prefix>-aca` named the environment's default domain, a `*` A
record to its static IP, and a link to the install's VNet (on an injected spoke, the VNet of
`aca_subnet_id`), with auto-registration off. Azure assigns the default domain when it creates
the environment, so the zone cannot be injected the way the Key Vault one is. Where your platform
team owns DNS, set it to `false`: the module creates no zone, record or link, and the
`container_app_environments` output gives each environment's `default_domain`,
`static_ip_address` and whether it is `internal`, for the records the hub creates.

`egress_firewall` still attaches its route table to `snet-aca` only ([Egress](#egress)): the
three environment subnets get no route table in this version. So with `egress_firewall` set, the
plan refuses `workers_environment` or `migrate_job_environment` set to `"workers"`: the moved
workload's egress would bypass your firewall. On injected subnets `egress_firewall` is refused
anyway, so the plan cannot see where egress goes: before either input is set to `"workers"`,
your platform team attaches the hub's route table (`0.0.0.0/0` to the firewall) to
`workers_subnet_id` as well, or the moved workload leaves forced tunnelling.

Each subnet carries its own NSG, ending in the same deny. The platform rows are the inbound
rules Microsoft lists for a workload-profiles environment in
[Securing a virtual network in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/firewall-integration);
31080 and 31443 are the ports the environment's edge proxy answers HTTP and HTTPS on, behind
its load balancer.

**`snet-front`**:

| Priority | Access | Source | Protocol / ports | Why |
|---|---|---|---|---|
| 100 | Allow | `Internet` — or `VirtualNetwork` with `aca_internal_load_balancer = true` | TCP 80, 443, 31080, 31443 | Reach the front environment's apps |
| 110 | Allow | `AzureLoadBalancer` | TCP 30000-32767 | Container Apps platform requirement |
| 120 | Allow | `snet-front` | any | Container Apps platform requirement: traffic within the subnet |
| 4000 | Deny | any | any | Everything not admitted above |

**`snet-app`**:

| Priority | Access | Source | Protocol / ports | Why |
|---|---|---|---|---|
| 100 | Allow | `snet-front` | TCP 443, 31443 | HTTPS from the front environment, and from nothing else |
| 110 | Allow | `AzureLoadBalancer` | TCP 30000-32767 | Container Apps platform requirement |
| 120 | Allow | `snet-app` | any | Container Apps platform requirement: traffic within the subnet |
| 4000 | Deny | any | any | Everything not admitted above |

**`snet-workers`**:

| Priority | Access | Source | Protocol / ports | Why |
|---|---|---|---|---|
| 110 | Allow | `AzureLoadBalancer` | TCP 30000-32767 | Container Apps platform requirement |
| 120 | Allow | `snet-workers` | any | Container Apps platform requirement: traffic within the subnet |
| 4000 | Deny | any | any | Everything not admitted above |

No allow rule on `snet-app` or `snet-workers` names `VirtualNetwork` or `Internet`.
`VirtualNetwork` would admit every peered network and every on-premises range behind a
gateway, not only the front.

**An external front's only inbound filter is `ingress_allowed_cidrs`.** The front subnet's NSG
admits the `Internet` tag when the environment is public, for the same reason `snet-aca`'s does:
an NSG rule cannot express the empty allowlist that means *unrestricted*. So on a public install
the apps' IP restrictions, `ingress_allowed_cidrs`, are the whole of who may reach the front, and
an empty list admits everyone. To filter at the network instead, put the front behind a WAF or an
Application Gateway with `aca_internal_load_balancer = true`: the rule then admits
`VirtualNetwork` only.

### Topology 3: what your own subnets should carry

On an injected spoke the module creates no NSG and associates none. A subnet holds exactly one,
so attaching ours would replace whatever your platform team put there, from outside their own
configuration. The tables above are the baseline those subnets are expected to meet, and two
rows of them are not optional: without the `AzureLoadBalancer` and intra-subnet rules the
Container Apps environment provisions and then serves nothing, and without `snet-aca` reaching
your endpoints subnet on the data-plane ports the apps cannot open a database connection.

With `front_subnet_id`, `app_subnet_id` and `workers_subnet_id` set, those three subnets are
yours too, and the baseline each should carry is the tables in
[The environment subnets](#the-environment-subnets), with your own ranges in place of ours:

- **front**: inbound TCP 80, 443, 31080 and 31443 from whoever reaches the front, which is
  `VirtualNetwork` or your Application Gateway's subnet on an internal environment and `Internet`
  on a public one; `AzureLoadBalancer` on TCP 30000-32767; any traffic within the subnet; deny
  everything else.
- **app**: inbound TCP 443 and 31443 from the front subnet's range only; `AzureLoadBalancer` on
  TCP 30000-32767; any traffic within the subnet; deny everything else. Never `VirtualNetwork`.
- **workers**: `AzureLoadBalancer` on TCP 30000-32767; any traffic within the subnet; deny
  everything else.
- **your endpoints subnet**: add the app and workers subnets' ranges as sources on the
  data-plane ports, beside `snet-aca`'s, and never the front subnet's.

**How big a spoke.** Each environment subnet takes /27 at the least. A workload-profiles
environment uses one address per node and per replica, so a /24 each leaves room to scale.
For three environment subnets, the private endpoints and an Application Gateway v2 subnet:

| | Environment subnets | Private endpoints | Application Gateway | Total | Spoke |
|---|---|---|---|---|---|
| **Minimum** | 3 × /27 | /28 | /24 (Azure's recommendation for v2) | 368 addresses | /23 |
| **Recommended** | 3 × /24 | /24 | /24 (Azure's recommendation for v2) | 1,280 addresses | /21 |

The minimum keeps the gateway at the /24 Azure recommends, because a v2 gateway scales out into
its subnet. Azure accepts a /26 for v2, which brings the minimum down to 176 addresses and a /24
spoke, at the cost of the gateway's headroom to scale; treat that as a reduced-capacity option,
not the baseline.

While the apps still run in the legacy environment, the spoke also holds its /23
(`aca_subnet_id`): 880 addresses at the minimum, a /22 (688 with the /26 gateway, still a /22),
and 1,792 recommended, which still fits the /21. That /21 is the layout the module derives for
itself: `snet-aca` at `.0.0/23`, the private endpoints at `.4.0/24`, front, app and workers at
`.5.0`, `.6.0` and `.7.0/24`, and `.2.0/23` free for the Application Gateway.

## Upgrading an existing install

Making the network injectable gave three resources a `count`, which changes their address in
state. The module carries `moved` blocks for all three, so the upgrade plans as **no changes**
for an install that keeps building its own network.

Moving a *running* install onto an existing spoke is not an in-place change: the ACA
environment's infrastructure subnet cannot be swapped underneath it. That is a rebuild, and
worth deciding before the first apply rather than after.

The network security baseline above arrives the same way — additively. On an install that
builds its own network the plan creates two NSGs and their two subnet associations, and
updates `snet-private-endpoints` in place to enable network policies. Neither subnet is
replaced and the Container Apps environment is not touched. Read the plan for your own install
before applying: if you attached your own NSG or a user-defined route to either subnet out of
band, the module's association replaces the first and enabling network policies starts
applying the second to private-endpoint traffic.

The environment subnets arrive additively too. On an install that builds its own network from
a /21 or larger, the plan creates `snet-front`, `snet-app` and `snet-workers`, their three NSGs
and three associations, and updates `nsg-<name_prefix>-private-endpoints` in place with the two
rules for the app and workers subnets. `snet-aca`, its NSG and its rules, the private-endpoint
subnet and both associations keep their addresses, names and prefixes: nothing needs a `moved`
block, nothing is replaced, and the apps in `snet-aca` keep their path to the data plane. Two
things to check in the plan first:

- If you created subnets of your own in the VNet out of band, the derived ranges
  (`.5.0/24`, `.6.0/24` and `.7.0/24` of the first prefix) may already be taken, and the apply
  then fails at Azure. Set `front_subnet_prefix`, `app_subnet_prefix` and
  `workers_subnet_prefix` to free ranges instead.
- With explicit `aca_subnet_prefix` and `private_endpoints_subnet_prefix` that cover those
  ranges, or a VNet smaller than /21, the plan creates no environment subnets and changes
  nothing; set the three prefixes when you want them.

An injected install changes nothing until you set the three subnet ids.

### Retiring the runtime environment

`retire_runtime_environment` gave `aca-<name_prefix>` and its diagnostic setting a `count`. The
module carries `moved` blocks for both (`module.aca_env` to `module.aca_env[0]`, and
`azurerm_monitor_diagnostic_setting.aca_env` to `azurerm_monitor_diagnostic_setting.aca_env[0]`),
so with the input unset the upgrade plans **no changes**: the two moved addresses, and nothing
destroyed or created.

Moving an existing install off `aca-<name_prefix>` takes four applies, in this order. Plan each on
a test install first, and read every plan before you apply it.

1. **Give the install the three environment subnets, and plan the environments.** On a network
   the module builds, a VNet of /21 or larger gets `snet-front`, `snet-app` and `snet-workers` on
   upgrade, or set `front_subnet_prefix`, `app_subnet_prefix` and `workers_subnet_prefix`
   ([The environment subnets](#the-environment-subnets)). On an injected network, set
   `front_subnet_id`, `app_subnet_id` and `workers_subnet_id`. The plan creates
   `aca-<name_prefix>-front`, `-app` and `-workers` beside `aca-<name_prefix>`, and moves no
   app. After the apply, the `container_app_environments` output gives each environment's
   `default_domain` and `static_ip_address`. With `environment_private_dns_enabled = false`, your
   hub creates the private DNS records for the internal ones from it.
2. **Move `ca-workers` and `caj-migrate`.** Set `workers_environment = "workers"`. With
   `migrations = "job"`, also set `migrate_job_environment = "workers"`. Each is replaced under
   the same name in the workers environment. The pipeline pauses until the new `ca-workers` runs,
   and the apply starts one more execution of `caj-migrate`. Both start on the module's api image,
   so run CD's release again afterwards. Neither has ingress, so no address changes.
3. **Move `ca-frontend`, `ca-edge` and `ca-api` together.** Set `frontend_environment = "front"`,
   `edge_environment = "front"` and `api_environment = "app"` in one apply. That apply replaces
   the three apps, with downtime between destroy and create. What changes:
   - **The FQDNs.** `ca-frontend` and `ca-edge` get new Container Apps FQDNs under the front
     environment's default domain, and with them `frontend_url` and `edge_url`. `ca-api` gets
     one under the app environment's. Anything that holds the old URLs needs the new ones: your
     users' bookmarks, an Application Gateway's backend pool, and an allowlist.
   - **The OIDC redirect URI.** Without `frontend_custom_domain`, the BFF's redirect URI is on
     `frontend_url`'s host. Register `https://<new frontend_url host>/api/auth/callback` with your
     identity provider, and set `oidc_redirect_uri` to it, in the same apply. The front
     environment's default domain is known after step 1, so the new host,
     `ca-frontend.<front default_domain>`, can be registered beforehand. With
     `frontend_custom_domain`, the redirect URI stays on your hostname and nothing changes.
   - **The custom-domain records, set before the apply.** With `frontend_custom_domain` or
     `edge_custom_domain`, the certificates and the custom domains are created again on the front
     environment, and `custom_domain_verification_id` reads the front environment's. The
     certificate identities and their Key Vault grants are kept as they are, under the same names;
     the apply attaches them to the front environment instead of aca-<prefix>. Before the apply:
     - Make sure each `asuid.<hostname>` TXT record carries that value. Azure derives it from the
       subscription, so it is normally the value already there.
     - Point each hostname's routing record at the front environment. That is a **CNAME** to
       `ca-frontend.<front default_domain>` or `ca-edge.<front default_domain>`, or an **A**
       record to the front environment's `static_ip_address`. Behind a gateway, point its backend
       there instead.
     Azure checks these records when the apply binds the hostnames again.
   - **SDK and API clients.** They reach the API through `ca-edge`, at `edge_url` or
     `edge_custom_domain`'s hostname, never at `ca-api` directly: `ca-api` in the app environment
     takes traffic from inside the VNet only. Give them the new `edge_url`, or keep your
     hostname, whose record now points at the front environment. The edge forwards to
     `https://ca-api.<app default_domain>` and verifies its certificate.
   - **The front subnet's one rule, on an injected network.** With `ca-frontend` on the front
     environment and the Key Vault private endpoint in use, the hub must add one rule before this
     apply: admit the front subnet to the Key Vault private endpoint, TCP 443, to the endpoint's
     own address (/32) only (ADR 0120 amendment, 2026-11-16). Add nothing wider: no other port,
     no other private endpoint, no Postgres, Redis or Service Bus, and not the whole
     private-endpoint subnet. On a network the module builds, the module adds that rule itself
     ([Network security baseline](#network-security-baseline)).
   - **`egress_firewall`.** The plan refuses `egress_firewall` with the apps moved, as it does in
     step 2 for `ca-workers` and `caj-migrate`. Its route table is attached to `snet-aca` only,
     and the environment subnets get none, so the moved workloads' egress would bypass your
     firewall. Remove `egress_firewall` before step 2. On an injected network, your hub attaches
     its route table to the front, app and workers subnets instead.

   Run CD's release again after this apply too.
4. **Set `retire_runtime_environment = true` and plan the deletion.** The plan must destroy
   exactly two objects, `module.aca_env[0]` (`aca-<name_prefix>`) and
   `azurerm_monitor_diagnostic_setting.aca_env[0]` (`diag-<name_prefix>-aca-env`), and nothing
   else. The `aca_environment_id` output becomes null.

   The plan refuses retirement while anything the module places is still on `aca-<name_prefix>`,
   and names what is left:
   - `ca-frontend`, `ca-edge`, `ca-api`, and a custom-domain certificate;
   - `ca-workers`, with `enable_workers`;
   - `caj-migrate`, with `migrations = "job"`.

   The module cannot see what you created in `aca-<name_prefix>` yourself. Azure deletes the
   environment with every app and job in it, so list the environment's apps and jobs first
   (`az containerapp list` and `az containerapp job list` on `rg-<name_prefix>-aca`, filtered on
   `aca-<name_prefix>`'s id). Move or delete anything else you find.

`snet-aca`, its NSG, the private-endpoint rule from it and `aca_subnet_id` stay after step 4. A
later version retires the subnet. Setting `retire_runtime_environment` back to `false` creates a
new, empty `aca-<name_prefix>`.

## Landing-zone notes

The install runs in its own VNet: the ACA environment is VNet-integrated (runtime subnet,
/23 — an ACA consumption requirement) and the provisioned Postgres is reachable **only via
a private endpoint**; private DNS keeps the server FQDN unchanged for the apps. The
frontend stays the single public surface, behind the optional ingress IP allowlist, unless you
publish the api (`api_ingress_external`) or set `edge` ([The edge proxy](#the-edge-proxy-ca-edge)).

Landing-zone accommodations:

- A first VNet prefix of /21 or larger derives the subnets automatically; a smaller
  allocation sets `aca_subnet_prefix` + `private_endpoints_subnet_prefix` explicitly, and
  `front_subnet_prefix`, `app_subnet_prefix` + `workers_subnet_prefix` for the
  [environment subnets](#the-environment-subnets).
- Hub-and-spoke shops that centralize private DNS pass
  `postgres_private_dns_zone_id` — the module then creates no zone and no VNet link
  (linking the central zone to this VNet is the platform team's side). The same holds for
  `key_vault_private_dns_zone_id`, `redis_private_dns_zone_id` and
  `servicebus_private_dns_zone_id`.
- The registry's private endpoint (`registry_private_endpoint`) always creates its own
  `privatelink.azurecr.io` zone and VNet link; there is no zone-ID input for it. Where the hub
  already links that zone to the VNet, leave it off and add the registry endpoint on the
  platform side ([The registry over a private endpoint](../README.md#the-registry-over-a-private-endpoint)).

> Upgrading from v0.1: `infrastructure_subnet_id` is create-time-only, so the apply
> REPLACES the Container App Environment and the apps — their FQDNs change. The Postgres
> server (and its data) is untouched.

## The API's public address

`public_api_url` tells the install the address something outside it calls the API on: an
absolute `https://` URL with no query string, fragment or credentials — the `api_url` output, or
your own domain in front of the API. When it is set, the module puts it on `ca-api`,
`ca-workers` and `ca-frontend` as `MASTERLY_PUBLIC_API_URL`, with any trailing slash dropped.
The frontend shows it in the catalog's Consume card; the API and the workers build the callback
URL of an external pipeline step from it. Unset (the default), no app gets the variable.

The module writes the value; it cannot tell whether the value works. It does when all three hold:

- `api_ingress_external = true` — otherwise nothing outside the environment reaches the API;
- `ingress_allowed_cidrs` admits whoever calls the API — for an external pipeline step, the
  outbound addresses of the service that runs your code;
- on an internal environment (`aca_internal_load_balancer`), "external" means reachable from the
  VNet, so the caller must be on the VNet or a network connected to it.

The `api_url` output is known only after the API is published, so on a new install either set
your own domain from the start or apply once, then set `public_api_url` from `api_url` and apply
again.

## The edge proxy (ca-edge)

`edge` adds `ca-edge`, the machine entry point for the Python SDK and MCP clients (ADR 0120 §2).
It is **off by default**: with `edge` unset the module creates nothing for it and an install plans
exactly as before. Set `edge = {}` to run it with the module's defaults; the `edge_url` output is
its base URL.

**It does no authentication yet.** It forwards the caller's `Authorization` header to `ca-api`
unchanged, and `ca-api` checks it, exactly as when `ca-api` itself is published with
`api_ingress_external = true`. What the edge adds is a narrower door:

- **Public ingress, on the allowlist.** `ca-edge` is published (external ingress) on
  `ingress_allowed_cidrs`, the same list the frontend uses, HTTPS-only (`http://` is redirected,
  never served). An empty list means unrestricted in Azure, so the plan is refused when `edge`
  is set and the list is empty. On an internal environment (`aca_internal_load_balancer`),
  "external" means reachable from the VNet.
- **Two routes.** `/v1` and `/mcp`, and the paths under them, go to `ca-api` by its app name
  (`http://ca-api`, encrypted underneath by the environment, as in
  [Transport security](#transport-security)). Every other path is answered `404` by the edge
  itself. Routing reads the normalized path, so `/v1/../x` is `/x` and answered `404`; a path
  with an encoded slash or backslash is refused.
- **The ca-serve routes, still answered by `ca-api`.** ADR 0120 §2 sends the replica-eligible
  reads (ADR 0112) to `ca-serve` and everything else to `ca-api`. The module renders that route
  set now: `edge-serve-routes.json` at the module root lists the reads the backend marks
  `x-masterly-serve`, as its `docs/contract/edge-routes.json` publishes them at the backend
  release the file names (`source.ref`). Each entry becomes a route of its own, after the `413`
  guards and before `/v1`, matched on the method exactly and on the path (a `{var}` in a path
  matches one segment without a `:`). Every one of them is **still forwarded to `ca-api`**, with
  the same Host, timeout and rate limits as `/v1`, so no request is answered differently; when
  `ca-serve` passes its gate, moving these reads to it changes only the cluster they forward to.
  A request no serve route matches, another method or another path under `/v1`, takes the `/v1`
  route as before. The list is read from the module's own files at plan time, never fetched, and
  `scripts/check_edge_serve_routes.py` holds it to reads (`GET`, `HEAD`, `POST`) under `/v1/`.
  The routes are part of the Envoy configuration, so applying a module version that adds them or
  changes them **rolls a new `ca-edge` revision**.
- **No identity headers.** The edge removes `x-jwt-payload`, `X-MS-CLIENT-PRINCIPAL`,
  `-ID`, `-IDP` and `-NAME` from every request, and drops any header with an underscore in its
  name, so a caller cannot hand `ca-api` a statement of who it is.
- **Body size and streaming.** A request whose `Content-Length` is larger than
  `edge.max_request_body_bytes` (10 MiB by default) is answered `413`; a body sent without a
  `Content-Length` streams through. Nothing is buffered, and a forwarded request has no total
  time limit, so a streamed MCP or server-sent-events response stays open; a stream with no bytes
  either way for 300 seconds is closed.
- **Rate limits.** Requests to `/v1` and `/mcp` are limited per bearer token and per client
  address. `edge.rate_limit_per_token` (600 by default) is how many requests one `Authorization`
  header value may send per interval; `edge.rate_limit_per_client` (1800 by default) is how many
  one client address may send, whatever tokens it uses, so rotating tokens does not get round the
  per-token limit; `edge.rate_limit_interval_seconds` (60 by default) is the interval both count
  over. A request without an `Authorization` header is held to the per-client limit only. A
  request over either limit is answered **`429` with a `Retry-After` header** of the interval in
  seconds (logged with response flag `RL`); the `413` and `404` answers are never limited. The
  ca-serve routes are `/v1` requests and share `/v1`'s limiter: one budget per token and per
  client across them and the rest of `/v1`, not one per route. The
  client address is the one the Container Apps ingress reports: the edge trusts exactly that one
  `X-Forwarded-For` hop, so a caller cannot choose its own address, and passes the header on to
  `ca-api` unchanged. The token is a key in Envoy's memory only, never in the configuration, the
  plan, a log or a metric name.
- **Limits are kept per replica.** Each `ca-edge` replica counts on its own, with no shared
  state: no Redis and no rate-limit service (ADR 0120 §5). `ca-edge` runs 1 to 3 replicas
  (`max_replicas = 3`), so the effective limit is the configured limit times the replicas
  running: between 1 and 3 times the setting. `/v1` (the ca-serve routes included) and `/mcp`
  are also counted separately. Set the limits for one replica, and expect a caller to be refused
  at the configured limit only while one replica runs. A replica keeps buckets for up to 1000
  distinct tokens and 1000 client addresses for `/v1` and again for `/mcp`, dropping the least
  recently seen; a dropped token's count starts afresh, and the per-client limit still holds.
- **No control plane, no secrets.** Envoy's admin interface is not configured. The whole Envoy
  configuration travels in the container's arguments (`args`), visible in the plan, and holds
  nothing secret; a change to it rolls a new revision. Because it is passed as arguments, the
  image's entrypoint still runs and starts Envoy as the image's unprivileged `envoy` user, not
  root; the listener is on port 8080. A mirror set in `edge.image` must keep that entrypoint. The
  access log, one JSON line per request on the container's output (in your workspace with
  diagnostics on), holds the path without its query string and no `Authorization`, cookie or
  other credential-carrying header.
- **Its own identity.** `ca-edge` runs as `id-<prefix>-edge`, which holds no role on Postgres,
  Key Vault, Service Bus or Redis, and AcrPull only when its image is on the install's registry.

### Where the edge's image comes from

By default `ca-edge` runs the upstream `envoyproxy/envoy` image from **Docker Hub** (v1.40.2,
pinned by digest), and pulls it anonymously. The environment then needs outbound HTTPS to Docker Hub
(`registry-1.docker.io`, `auth.docker.io` and the content host it redirects to,
`production.cloudflare.docker.com`): on a network whose egress goes through a firewall, allow
those, or mirror the image.

To mirror it, copy the image, digest unchanged, to a registry the environment can reach and set
`edge.image` to the copy, for example `myregistry.azurecr.io/envoyproxy/envoy:<tag>@sha256:<digest>`.
The reference must carry a digest; the plan refuses one without. When the copy is on the install's
registry (`registry_location`), `ca-edge` pulls it as `id-<prefix>-edge`: the module grants AcrPull
when `acr_id` is set, and otherwise you grant it to `edge_identity_principal_id`. An install that
pulls with a registry token cannot do that, because `ca-edge` holds no secret: put the mirror on a
registry it pulls from anonymously or as its identity. Changing `edge.image` rolls `ca-edge` on the
next apply; nothing else moves its image.

### ca-edge on your own domain

`edge_custom_domain` binds your hostname to `ca-edge` with your certificate from your Key Vault,
so SDK and MCP clients, and your firewall rules, can name a hostname that does not change with
the environment. It takes the same three fields as `frontend_custom_domain` and works the same
way: a dedicated identity, `id-<prefix>-edge-cert`, attached to the Container App Environment and
to no app, gets Key Vault Secrets User on that one secret; the environment reads the certificate
as that identity from the versionless secret id, so a certificate renewed in the vault is picked
up without an apply; and the binding is SNI, on `ca-edge`, without changing its ingress,
allowlist or HTTPS-only setting. `ca-edge`'s own identity, `id-<prefix>-edge`, never reads the
certificate. `edge_url` becomes `https://<hostname>`.

It needs `edge` set (the plan refuses it otherwise), and a hostname of its own: the plan refuses
`frontend_custom_domain`'s hostname, because each app needs its own (for example
`masterly.example.com` for the frontend and `api.masterly.example.com` for the edge). The
module creates no DNS record. As for the frontend, you provide:

1. **Before the apply that sets it, the `asuid.<hostname>` TXT record**, for example
   `asuid.api.masterly.example.com TXT <value>`. The value is the same verification id as for
   the frontend, `custom_domain_verification_id` (readable before the first apply, as
   [Before the first apply](#before-the-first-apply) shows). With both custom domains set, there
   are two TXT records with the same value, one per hostname.
2. **The deploying identity's right to create the role assignment** on your vault, and the vault's
   reachability: it must use Azure RBAC authorization and be reachable from the Container App
   Environment, or have a private endpoint it reaches (the Key Vault row in
   [What your firewall must admit](#what-your-firewall-must-admit)).
3. **The record that routes the hostname**, once the environment exists: a **CNAME** to
   `ca-edge`'s Container Apps FQDN, `ca-edge.<environment default domain>` (`az containerapp show
   -n ca-edge -g rg-<name_prefix>-aca --query properties.configuration.ingress.fqdn -o tsv`), or
   an **A** record to the environment's static IP, as in
   [The record that routes the hostname](#the-record-that-routes-the-hostname). Behind an
   Application Gateway, the record points at the gateway instead.

There is no redirect URI to register: the edge does no sign-in. If the apply stops at the binding
with a domain-verification error, fix the record and apply again, as for the frontend.

### Running the edge behind an Application Gateway

`edge_custom_domain` gives the edge your own hostname and certificate without a gateway. For a WAF,
or to terminate the hostname at a gateway you already run, put an Application Gateway in front of
it:

- **Backend pool:** `ca-edge`'s Container Apps FQDN (`ca-edge.<environment domain>`, the `edge_url`
  host while `edge_custom_domain` is unset), HTTPS on port 443, with the host name picked from the
  backend target, so the Container Apps ingress sees its own hostname. With `edge_custom_domain`
  set, keep your hostname as the backend host instead, as for the frontend's gateway above.
- **Allowlist:** add the gateway's outbound address to `ingress_allowed_cidrs` (its public IP for a
  public environment, its subnet for an internal one), and remove the client ranges the gateway
  now admits for you.
- **Timeouts:** raise the backend setting's request timeout (20 seconds by default) above the
  longest stream your MCP clients hold, or the gateway cuts what the edge keeps open.
- **Health probe:** the edge answers `/` with `404`, so a probe on `/` that accepts `404` shows
  the edge is up without calling `ca-api`.
- **Rate limits:** the client address the edge sees is the gateway's, so every client behind the
  gateway shares one `edge.rate_limit_per_client` bucket. Raise it to what all your clients
  together may send, and limit individual clients at the gateway; the per-token limit still
  applies to each token.
- **Logging:** keep the gateway's own access and WAF logs free of full URLs and request bodies,
  as [If you front this install with a WAF, CDN, or gateway](../README.md#if-you-front-this-install-with-a-waf-cdn-or-gateway)
  says.

## Transport security

Everything published by the install is HTTPS-only. `ca-frontend` and, with `edge` set,
`ca-edge` always redirect `http://` to `https://`, and `ca-api` does the same **as soon as
`api_ingress_external = true`** — a
published api trusts a bearer token and nothing else, so serving it on port 80 would put
the whole credential on the wire for anyone in the path. An IP allowlist bounds who can
reach an endpoint; it says nothing about what a network in between can read.

While the api stays internal (the default) it keeps serving plain HTTP, because the only
thing calling it is the frontend's BFF at `http://ca-api` — an app-name address, which is
the one form that cannot drift, and which no TLS certificate can match. That hop is not
left in the clear: the Container Apps environment runs with **peer-to-peer encryption**
on, so Azure encrypts traffic between apps inside the environment with certificates it
manages and rotates. Applications keep speaking `http://` and the platform encrypts
underneath — this is Azure's `peerTrafficConfiguration.encryption`, and it is what makes
the internal `allowInsecure` acceptable rather than merely convenient.

Verify it on a running install:

```bash
az containerapp env show -n aca-masterly -g rg-masterly-aca \
  --query properties.peerTrafficConfiguration.encryption.enabled
```

Check it after an out-of-band change rather than relying on `terraform plan`: the provider
writes both of Azure's peer settings from one input but refreshes state from only one of
them, so a console or CLI change to peer-traffic encryption alone shows up as no drift.

Microsoft notes that peer-to-peer encryption may add response latency and lower maximum
throughput under high load. The module deliberately exposes no input to turn it off: the
hop it protects is the one carrying every authenticated request in the install, and a knob
that quietly trades that away is worth less than the throughput it buys back. If you
measure a real problem, open an issue with the numbers rather than reaching for `az` — an
out-of-band change to peer-traffic encryption is invisible to `terraform plan` (above),
which makes it exactly the kind of setting that stops being true without anyone noticing.
