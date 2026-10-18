output "pooler_url" {
  value       = local.pooler_url
  sensitive   = true
  description = "The api's install-level DSN on pooler_port: the root module's database-url secret."
}

output "direct_url" {
  value       = local.direct_url
  sensitive   = true
  description = "The same role and database on direct_port, bypassing the pooler: the root module's database-direct-url secret."
}
