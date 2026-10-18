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
endpoints for Postgres, Key Vault, and Redis, and the private DNS zones those need.

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
not the IdP — but the IdP must still have it registered.

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

**Egress.** What you can do to outbound traffic on the ACA subnet depends on the type of
Container Apps environment, and Azure honours a route or a NAT Gateway on that subnet for only
one of the two types. A route Azure ignores filters nothing, so check your environment first:

```sh
az containerapp env show \
  --ids "$(terraform output -raw aca_environment_id)" \
  --query properties.workloadProfiles
```

The `terraform output` form needs your root configuration to re-export the module's
`aca_environment_id` output (`output "aca_environment_id" { value = module.<name>.aca_environment_id }`).
Without that, use `-n aca-<name_prefix> -g rg-<name_prefix>-aca` instead of `--ids`.

| Result | Environment type | Egress options on the ACA subnet |
|---|---|---|
| `null` or an empty list | Consumption-only | **No UDR and no NAT Gateway** — Azure does not support either. Narrow egress with your own outbound NSG on the ACA subnet, built from service tags, that admits the Container Apps required outbound set (see [firewall-integration](https://learn.microsoft.com/azure/container-apps/firewall-integration)) |
| A list with a profile of type `Consumption` | Workload profiles | A UDR to a hub firewall or NVA, or a NAT Gateway, is supported. The firewall must admit the Container Apps required outbound set |

**Do not write a UDR for a Consumption-only environment.** Azure ignores it, and egress stays
open while you believe it is filtered.

**A firewall that drops the required set breaks the install.** On a workload-profiles
environment, force egress through a firewall that does not admit the required outbound set
and the environment still provisions, but it cannot start a replica. The set is long and
Microsoft versions it, so it is not copied here; take the FQDNs, service tags and NSG rules
from [Securing a virtual network in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/firewall-integration).
The install also needs to reach your identity provider and the container registry it pulls
images from.

On a network the module builds (topologies 1 and 2) the module's NSG adds no outbound rule, so
Azure's default `AllowInternetOutBound` applies.

The support claims above come from Microsoft Learn:
[Networking in Azure Container Apps environment](https://learn.microsoft.com/azure/container-apps/networking)
(the environment types),
[Control outbound traffic with user defined routes](https://learn.microsoft.com/azure/container-apps/user-defined-routes)
(UDR and NAT Gateway), and
[Securing a virtual network in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/firewall-integration)
(the required outbound set and the outbound NSG for a Consumption-only environment).

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
| 100 | Allow | `snet-aca` | TCP 443, 5432, 6380, 10000 | Key Vault, Postgres, Azure Cache for Redis, Azure Managed Redis |
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

**Outbound is untouched.** Azure's default `AllowInternetOutBound` stays. Container Apps needs
a long, Microsoft-versioned egress set — image pull, Microsoft Container Registry, Entra ID,
Azure Monitor — and a copy of it written into this module would go stale into an environment
that provisions and then cannot start a replica. Whether and how egress can be narrowed
depends on the environment type; see **Egress** above.

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
