# Outputs of identity.tf: the image references and the identities' ids.

# What the install pulls and how, after the deprecated inputs and the release channel are
# resolved: the answer to "which images will this plan seed, from where, with what credential",
# without reading the plan's container blocks. No credential material, only the mode.
output "image_references" {
  value = {
    api                      = local.api_image
    frontend                 = local.frontend_image
    registry_server          = local.registry_server
    registry_credential_mode = local.registry_credential_mode
    release_channel          = var.release_channel
    release_version          = local.release_channel_version
  }
  description = "The api and frontend image references the apps are created with, the registry server they pull from (empty when the apps have no registry block, as when registry_location, registry_credential_mode, a pull credential and acr_id are all omitted), the resolved registry_credential_mode, and the release channel with the MANIFEST.json release it resolved to. The release names where the default references came from; an image set explicitly is reported as given."
}

output "apps_identity_principal_id" {
  value       = module.apps_identity.principal_id
  description = "Principal (object) id of the BACKEND apps' user-assigned identity (the api, and the workers unless they have their own) — grant AcrPull on your registry scope to this principal when acr_id is left null in the managed_identity or customer_registry mode. The frontend, the migrate job with migrations = \"job\", and the workers wherever workers_identity_principal_id is set have their own; grant each."
}

output "apps_identity_client_id" {
  value       = module.apps_identity.client_id
  description = "Client id of the backend apps' user-assigned identity (DefaultAzureCredential's AZURE_CLIENT_ID)."
}

output "frontend_identity_principal_id" {
  value       = module.frontend_identity.principal_id
  description = "Principal (object) id of the frontend's own user-assigned identity — image pull only. Grant AcrPull on your registry scope to this principal too when acr_id is left null."
}

output "migrate_identity_principal_id" {
  value       = one(module.migrate_identity[*].principal_id)
  description = "Principal (object) id of the migrate job's own user-assigned identity (id-<prefix>-migrate, the job caj-migrate runs as), with migrations = \"job\"; null otherwise. Grant AcrPull on your registry scope to this principal too when acr_id is left null in the managed_identity or customer_registry mode, or the job cannot pull the api image."
}

output "workers_identity_principal_id" {
  value       = one(module.workers_identity[*].principal_id)
  description = "Principal (object) id of ca-workers' own user-assigned identity (id-<prefix>-workers, which ca-workers runs and pulls as), wherever ca-workers exists and the install has a Key Vault, except migrations = \"start\" with database_auth = \"entra\" on the starter server; null otherwise, where ca-workers runs as the apps identity. Grant AcrPull on your registry scope to this principal before applying when acr_id is left null in the managed_identity or customer_registry mode, or ca-workers cannot pull the api image."
}
