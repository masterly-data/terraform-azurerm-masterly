# Outputs of environment.tf: the Container App Environments.

output "aca_environment_id" {
  value       = module.aca_env.id
  description = "Resource ID of the Container App Environment the apps run in (aca-<name_prefix>), except ca-frontend, ca-edge and ca-api when frontend_environment, edge_environment and api_environment move them."
}

output "container_app_environments" {
  value = {
    for k in ["front", "app", "workers"] : k => (
      contains(keys(module.environments), k) ? {
        id                = module.environments[k].id
        default_domain    = module.environments[k].default_domain
        static_ip_address = module.environments[k].static_ip_address
        internal          = local.container_app_environment_internal[k]
      } : null
    )
  }
  description = "The front, app and workers Container Apps environments (ADR 0120), keyed front, app and workers: id, default_domain, static_ip_address and internal (true when the environment has an internal load balancer: app and workers always, the front when aca_internal_load_balancer is true). A hub that owns DNS (environment_private_dns_enabled = false) creates, for each internal environment, a private DNS zone named default_domain with a wildcard (*) A record to static_ip_address, linked to the install's VNet. A key's value is null where the install has no such environment, which is when environment_subnet_ids has no subnet for it. By default no app runs in these environments; frontend_environment, edge_environment and api_environment move ca-frontend and ca-edge to front and ca-api to app."
}

output "egress_route" {
  value = length(azurerm_subnet_route_table_association.aca) == 0 ? null : {
    route_table_id = local.egress_route_table_id
    next_hop_ip    = try(var.egress_firewall.next_hop_ip, null)
  }
  description = "The forced-tunnel route on the Container Apps subnet (snet-aca), with egress_firewall set: route_table_id, the route table attached to it (the module's, or yours), and next_hop_ip, the firewall address the module's route table sends 0.0.0.0/0 to (null with your own route table). Null when egress_firewall is unset."
}
