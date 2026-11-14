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

The default. The module creates a VNet from `vnet_address_space`, two subnets, private
endpoints for Postgres, Key Vault, and Redis, and the private DNS zones those need. With
`registry_private_endpoint = true` (the `managed_identity` and `customer_registry` registry
modes, with `acr_id` set) it adds one more: a private endpoint to your registry's `registry`
subresource, and a `privatelink.azurecr.io` zone linked to the VNet, so image pulls stay on the
VNet.

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
| 1 and 2: the module builds the network | `egress_firewall = { next_hop_ip = "10.0.0.4" }`: the module creates `rt-<name_prefix>-aca` in `rg-<name_prefix>-aca` with one route, `0.0.0.0/0` to that address as a virtual appliance, and attaches it to `snet-aca`. Or `egress_firewall = { route_table_id = "/subscriptions/.../routeTables/<name>" }`: the module attaches your route table to `snet-aca` as it is, and creates none |
| 3: injected subnets | Your platform team attaches the hub's route table (`0.0.0.0/0` to the firewall) to the injected ACA subnet. `egress_firewall` is refused at plan there: a subnet holds one route table, and the module attaching its own would replace the hub's. The module creates no route table and no association on injected subnets, so the one the hub attached is never touched |

The `egress_route` output shows the route table in effect and the next-hop address, and is null
when `egress_firewall` is unset.

**Only on a workload-profiles environment.** Azure ignores a route on a Consumption-only
Container Apps environment, so egress would stay open while you believe it is filtered. The
module therefore refuses `egress_firewall` unless the environment's subnet is delegated to
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
list is Consumption-only. The `terraform output` form needs your root configuration to re-export
the module's `aca_environment_id` output (`output "aca_environment_id" { value =
module.<name>.aca_environment_id }`). Without that, use `-n aca-<name_prefix> -g
rg-<name_prefix>-aca` instead of `--ids`. On an injected subnet, run the same check before your
platform team attaches the hub's route table.

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

**Public ingress (topology 1).** The same reasoning applies to replies to internet clients that
reach the environment's public endpoint: they must leave by the path the request came in on.
Check Microsoft's [Control outbound traffic with user defined routes](https://learn.microsoft.com/azure/container-apps/user-defined-routes)
for its current guidance on public ingress alongside a `0.0.0.0/0` route to a firewall before
you rely on that combination. Topology 2 has no public endpoint, which avoids the question.

**On a running install**, the route applies as soon as the apply attaches it. Open the
destinations below on your firewall first. **On a fresh install** the module attaches the route
once Azure has created the environment (that is when the workload-profile check can run), so
the environment's first outbound connections, before the attachment, can take Azure's default
path. Where nothing may leave except through the firewall from the first connection, use
injected subnets with the hub's route table already attached (topology 3).

### What your firewall must admit

Every destination the Container Apps subnet reaches outside the VNet, with what reaches it and
what fails when the firewall drops it. Hosts written as an input are the host of that input's
URL.

| Destination | When the install reaches it | What fails when it is blocked |
|---|---|---|
| The Container Apps outbound set: the FQDNs and service tags in Microsoft's [Securing a virtual network in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/firewall-integration), including Microsoft Container Registry and Microsoft Entra ID | Always: the environment's own platform components | The environment provisions but cannot start a replica: each revision stays with no ready replica. Microsoft versions the set, so it is not copied here |
| Microsoft Entra ID for managed identities (`login.microsoftonline.com`, service tag `AzureActiveDirectory`; part of the set above) | Always: the apps' identities get tokens for the registry (`managed_identity` and `customer_registry` modes), Key Vault references (`enable_key_vault`), and Postgres and Redis with `database_auth = "entra"` | Every pull, secret reference or database sign-in that uses an identity fails: a new revision has no ready replica, or the apps cannot open their database connection |
| The image registry: its login server (`masterly.azurecr.io` by default, or `registry_location`) and its data endpoint (`<registry>.<region>.data.azurecr.io` with dedicated data endpoints, otherwise the registry's `*.blob.core.windows.net` storage; see [Configure rules to access an Azure container registry behind a firewall](https://learn.microsoft.com/azure/container-registry/container-registry-firewall-access-rules)) | Always, **unless** `registry_private_endpoint = true`, which keeps pulls on the registry's private endpoint in the VNet | The image pull fails: a new revision (a fresh install, an upgrade or a restart onto a new replica) has no ready replica, and `ContainerAppSystemLogs` records the failed pull |
| Your identity provider's issuer and its endpoints: the discovery document under `oidc_authority`, the token endpoint it names, and the signing keys at `oidc_jwks_uri` (all `https://login.microsoftonline.com/<tenant>/...` when only `oidc_tenant_id` is set) | `identity_binding = "oidc"`: `ca-frontend`'s BFF signs users in against the authority, and `ca-api` fetches the signing keys. With `builtin_auth`, Azure's built-in authentication on `ca-frontend` reaches the same IdP | With the token endpoint or discovery document unreachable, sign-in fails with an error after the IdP redirects back. With the keys unreachable, `ca-api` cannot validate a token, so authenticated requests are refused |
| Masterly's control plane: the host of `license_issuer_url` | `license_issuer_url` set (licence refresh) | Licence refresh fails. After seven days without a successful refresh the install is read-only: reads, exports and sign-in continue, writes are refused, until refresh succeeds again |
| Masterly's control plane: the host of `telemetry_url` | `telemetry_url` set (fleet telemetry) | Usage reports do not reach the control plane. Licence refresh is a separate call (ADR 0074) and is not affected |
| Azure Monitor (service tag `AzureMonitor`) | Always: the environment sends the apps' console and system logs through Azure Monitor (`logs_destination = "azure-monitor"`) | New rows stop arriving in `ContainerAppConsoleLogs` and `ContainerAppSystemLogs`, so the log-search alerts and the diagnostic bundle see nothing new while the apps keep serving |
| Key Vault (`<vault>.vault.azure.net`) | `enable_key_vault` outside `mode = "production"`, where the vault keeps public network access. In production it is reached over its private endpoint | A revision whose secrets are Key Vault references does not start: it has no ready replica |
| Your Key Vault holding the frontend certificate | `frontend_custom_domain` set, unless that vault has a private endpoint the environment reaches | The environment cannot read the certificate, so the binding of your hostname fails, at the first apply or at the next certificate rotation |
| Service Bus (`<namespace>.servicebus.windows.net`, TCP 5671 and 443) | `enable_service_bus` with a public namespace: any SKU outside production, and Standard in production. A Premium namespace in production is private | The apps cannot open their Service Bus connection, so work handed over the bus does not run |
| Azure Communication Services (`*.communication.azure.com`) | `email_acs_enabled` | Email is not sent |
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
| 110 | Allow | `AzureLoadBalancer` | TCP 30000-32767 | Container Apps platform requirement for a Consumption-only environment |
| 120 | Allow | `snet-aca` | any | Container Apps platform requirement: traffic within the infrastructure subnet |
| 4000 | Deny | any | any | Everything not admitted above |

**`snet-private-endpoints`**:

| Priority | Access | Source | Protocol / ports | Why |
|---|---|---|---|---|
| 100 | Allow | `snet-aca` | TCP 443, 5432, 6380, 10000 | Key Vault and the registry's private endpoint (443), Postgres, Azure Cache for Redis, Azure Managed Redis |
| 4000 | Deny | any | any | Everything not admitted above |

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

### Topology 3: what your own subnets should carry

On an injected spoke the module creates no NSG and associates none. A subnet holds exactly one,
so attaching ours would replace whatever your platform team put there, from outside their own
configuration. The tables above are the baseline those subnets are expected to meet, and two
rows of them are not optional: without the `AzureLoadBalancer` and intra-subnet rules the
Container Apps environment provisions and then serves nothing, and without `snet-aca` reaching
your endpoints subnet on the data-plane ports the apps cannot open a database connection.

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

## Landing-zone notes

The install runs in its own VNet: the ACA environment is VNet-integrated (runtime subnet,
/23 — an ACA consumption requirement) and the provisioned Postgres is reachable **only via
a private endpoint**; private DNS keeps the server FQDN unchanged for the apps. The
frontend stays the single public surface, behind the optional ingress IP allowlist.

Landing-zone accommodations:

- A first VNet prefix of /21 or larger derives the subnets automatically; a smaller
  allocation sets `aca_subnet_prefix` + `private_endpoints_subnet_prefix` explicitly.
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

## Transport security

Everything published by the install is HTTPS-only. `ca-frontend` always redirects `http://`
to `https://`, and `ca-api` does the same **as soon as `api_ingress_external = true`** — a
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
