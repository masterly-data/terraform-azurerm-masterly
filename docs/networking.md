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
- `private_endpoints_subnet_id` — a **different** subnet, with private endpoint network
  policies disabled. A delegated subnet cannot hold private endpoints, so these cannot be the
  same subnet; the module refuses that at plan too.

**Centralised private DNS.** If your hub owns the privatelink zones, inject them and the module
creates neither the zone nor the VNet link — linking the hub zone to this spoke is your
platform team's side:

```hcl
postgres_private_dns_zone_id  = "/subscriptions/.../privateDnsZones/privatelink.postgres.database.azure.com"
key_vault_private_dns_zone_id = "/subscriptions/.../privateDnsZones/privatelink.vaultcore.azure.net"
redis_private_dns_zone_id     = "/subscriptions/.../privateDnsZones/privatelink.redis.azure.net"
```

Each is independent: inject the ones your hub owns and let the module create the rest.

**Egress.** If the spoke routes outbound through a firewall or NVA, that is a UDR on the ACA
subnet — yours to write, since the subnet is yours. The install needs to reach your identity
provider and the container registry it pulls images from.

## Upgrading an existing install

Making the network injectable gave three resources a `count`, which changes their address in
state. The module carries `moved` blocks for all three, so the upgrade plans as **no changes**
for an install that keeps building its own network.

Moving a *running* install onto an existing spoke is not an in-place change: the ACA
environment's infrastructure subnet cannot be swapped underneath it. That is a rebuild, and
worth deciding before the first apply rather than after.
