### Added

- **`egress_firewall` input: forced-tunnel egress through your firewall.** Set `next_hop_ip` to your firewall's private IPv4 address and the module creates `rt-<name_prefix>-aca` with one route, `0.0.0.0/0` to that address as a virtual appliance, with BGP route propagation kept on; or set `route_table_id` and it attaches your own route table unchanged. Either way the table goes on `snet-aca` only, never on `snet-private-endpoints`, whose traffic stays inside the VNet. Refused at plan with both or neither field set, with a next hop that is not one IPv4 address, with injected subnets (the hub's route table there is the platform team's to attach), and on a Consumption-only environment, where Azure ignores the route (for a new environment that half of the check runs at apply). The default, null, attaches nothing, so an existing install plans no change.
- **`egress_route` output.** The route table in effect on `snet-aca` and the next-hop address; null when `egress_firewall` is unset.
- **`modules/aca-env-consumption`: `read_workload_profiles` input and `workload_profile_names` output**, Azure's own list of the environment's workload profiles, read with azapi only when asked. The nested module now declares the `Azure/azapi` provider, which the root module already requires.

### Changed

- **docs/networking.md, "Egress"**, rewritten for forced tunnelling: `egress_firewall` on a network the module builds, the hub's route table on injected subnets, and a table of every destination the Container Apps subnet reaches outside the VNet, with what reaches it and what fails when the firewall drops it. The outbound-NSG advice for a Consumption-only environment is gone: every environment the module builds is a workload-profiles environment (ADR 0104).
