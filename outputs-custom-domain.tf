# Outputs of custom-domain.tf: the custom domains' verification value.

# Sensitive only because the provider marks the environment's attribute so; it is the value
# published in DNS. Read it with `terraform output -raw custom_domain_verification_id`.
output "custom_domain_verification_id" {
  # The environment that holds the certificates: aca-<prefix>, or the front environment with
  # frontend_environment and edge_environment = "front". try() as for the apps' environment ids
  # (environment.tf): a missing environment is refused at plan. aca-<prefix> is read through
  # one(), as it may be retired (retire_runtime_environment), and then the key is "front".
  value       = local.certificate_environment_key == "aca" ? one(module.aca_env[*].custom_domain_verification_id) : try(module.environments[local.certificate_environment_key].custom_domain_verification_id, one(module.aca_env[*].custom_domain_verification_id))
  sensitive   = true
  description = "The value of the asuid.<hostname> TXT record Azure checks before it binds frontend_custom_domain's hostname to ca-frontend, or edge_custom_domain's to ca-edge: the same value for each hostname, one record per hostname. Read from the environment the two apps run in: aca-<name_prefix>, or aca-<name_prefix>-front with frontend_environment and edge_environment = \"front\", so the records must follow it when the apps move. Azure derives it from the subscription, so it can be read before the first apply as well (docs/networking.md). Marked sensitive because the provider marks it; it is not a secret."
}
