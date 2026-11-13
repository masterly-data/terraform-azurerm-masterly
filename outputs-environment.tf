# Outputs of environment.tf: the Container App Environment.

output "aca_environment_id" {
  value       = module.aca_env.id
  description = "Resource ID of the Container App Environment."
}
