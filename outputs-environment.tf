# Outputs of environment.tf: the Container App Environment.

output "aca_environment_id" {
  value       = module.aca_env.id
  description = "Resource ID of the Container App Environment."
}

output "egress_route" {
  value = length(azurerm_subnet_route_table_association.aca) == 0 ? null : {
    route_table_id = local.egress_route_table_id
    next_hop_ip    = try(var.egress_firewall.next_hop_ip, null)
  }
  description = "The forced-tunnel route on the Container Apps subnet (snet-aca), with egress_firewall set: route_table_id, the route table attached to it (the module's, or yours), and next_hop_ip, the firewall address the module's route table sends 0.0.0.0/0 to (null with your own route table). Null when egress_firewall is unset."
}
