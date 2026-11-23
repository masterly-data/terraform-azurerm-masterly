# Outputs of network.tf: the environment subnets (ADR 0120 §4) and what each needs to reach (§5).

output "environment_subnet_ids" {
  value       = local.env_subnet_ids
  description = "The ids of the front, app and workers environment subnets, as a map keyed front, app and workers: the subnets the module created, or front_subnet_id, app_subnet_id and workers_subnet_id on an injected network. With split_processing the map also has core and outbound, and with extensions extension (core_subnet_id, outbound_subnet_id and extension_subnet_id on an injected network). Each value is null when the install has no such subnet (a VNet smaller than /21 without explicit prefixes, or an injected network without the three ids)."
}

output "environment_subnet_prefixes" {
  value       = local.env_subnet_published_prefixes
  description = "The CIDRs of the front, app and workers environment subnets, as a map keyed front, app and workers, and with split_processing and extensions also core, outbound and extension. Each value is null when the module did not create the subnet, including on an injected network, where the prefixes are the platform team's and the module does not read them."
}

output "outbound_allowlist" {
  value       = local.outbound_allowlist
  description = "What each subnet's workloads reach outside the VNet, for your firewall to admit when you force egress through it (ADR 0120 §5). A map keyed by each environment the install has: aca (aca-<name_prefix> on snet-aca) until retire_runtime_environment retires it, and front, app and workers, core and outbound (split_processing) and extension (extensions) where their subnets exist. Each value is a list of entries: destination (an FQDN, possibly a leading wildcard, or an Azure service tag), kind (\"fqdn\" or \"service_tag\"), protocol (\"TCP\"), ports (a list of port numbers as strings), why (what reaches it and what fails when it is blocked) and source (the document or the input it comes from). Every subnet carries the Container Apps platform set (Microsoft Container Registry, Microsoft Entra ID and Azure Monitor, from Microsoft Learn's \"Securing a virtual network in Azure Container Apps\" as read on the date each entry's source names, and Azure management, which ADR 0120 §5 adds) and the image registry (unless registry_private_endpoint); the rest sits only on the subnet where the workload that reaches it runs, so front never lists Postgres, Redis, Service Bus or Communication Services. The Key Vault, Service Bus and Communication Services names are known after the first apply. Destinations reached over a private endpoint in the VNet are not listed, and nor are the targets you configure in the application (webhooks, an SMTP relay, a BYO-DB Environment's database). The module adds no outbound NSG rule or route from it: docs/networking.md says how to use it. It holds hosts and ports only, never a URL's credentials."
}
