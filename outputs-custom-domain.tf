# Outputs of custom-domain.tf: the custom domain's verification value.

# Sensitive only because the provider marks the environment's attribute so; it is the value
# published in DNS. Read it with `terraform output -raw custom_domain_verification_id`.
output "custom_domain_verification_id" {
  value       = module.aca_env.custom_domain_verification_id
  sensitive   = true
  description = "The value of the asuid.<hostname> TXT record Azure checks before it binds frontend_custom_domain's hostname to ca-frontend. Azure derives it from the subscription, so it can be read before the first apply as well (docs/networking.md). Marked sensitive because the provider marks it; it is not a secret."
}
