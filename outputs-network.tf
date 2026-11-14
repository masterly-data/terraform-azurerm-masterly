# Outputs of network.tf: the environment subnets (ADR 0120 §4).

output "environment_subnet_ids" {
  value       = local.env_subnet_ids
  description = "The ids of the front, app and workers environment subnets, as a map keyed front, app and workers: the subnets the module created, or front_subnet_id, app_subnet_id and workers_subnet_id on an injected network. Each value is null when the install has no such subnet (a VNet smaller than /21 without explicit prefixes, or an injected network without the three ids)."
}

output "environment_subnet_prefixes" {
  value       = local.env_subnet_published_prefixes
  description = "The CIDRs of the front, app and workers environment subnets, as a map keyed front, app and workers. Each value is null when the module did not create the subnet, including on an injected network, where the prefixes are the platform team's and the module does not read them."
}
