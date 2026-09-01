# Values marked "bundle" come from your Masterly install bundle. Values marked "secret"
# should reach Terraform as TF_VAR_<name> environment variables, never a committed file —
# note that *.tfvars is gitignored in this repository for that reason.

variable "subscription_id" {
  type        = string
  description = "The Azure subscription the install lands in."
}

variable "org_id" {
  type        = string
  description = "Your Masterly Organization id (bundle). The licence's `sub` claim must match it."
}

variable "install_id" {
  type        = string
  description = "A short slug naming this install, e.g. \"prod\". Distinct from the bundle's control-plane install id."
  default     = "prod"
}

variable "org_name" {
  type        = string
  description = "Display name for the Organization."
}

variable "location" {
  type        = string
  description = "Azure region. Must offer Container Apps, your Postgres flavour, Key Vault and Redis — the lowest-availability dependency wins."
  default     = "swedencentral"
}

variable "masterly_region" {
  type        = string
  description = "Data-residency region for this install, e.g. \"eu\". Must be permitted by the licence's regions_allowed."
  default     = "eu"
}

variable "api_image_tag" {
  type        = string
  description = "api image tag for this release (bundle release notes)."
}

variable "frontend_image_tag" {
  type        = string
  description = "frontend image tag for this release (bundle release notes)."
}

variable "registry_username" {
  type        = string
  description = "Registry pull credential username (bundle)."
}

variable "registry_password" {
  type        = string
  sensitive   = true
  description = "Registry pull credential secret (bundle, secret)."
}

variable "license_token" {
  type        = string
  sensitive   = true
  description = "The signed licence JWT (bundle, secret). The public half is license-issuer.jwk.json beside this example."
}

variable "oidc_tenant_id" {
  type        = string
  description = "Directory (tenant) id of your identity provider."
}

variable "oidc_client_id" {
  type        = string
  description = "Application (client) id of the app registration for Masterly's sign-in."
}

variable "oidc_client_secret" {
  type        = string
  sensitive   = true
  description = "Client secret of that registration (secret)."
}

variable "oidc_redirect_uri" {
  type        = string
  description = "The BFF callback. Leave the placeholder for apply 1; set to https://<frontend_url host>/api/auth/callback for apply 2."
  default     = "https://redirect-not-yet-known.invalid/api/auth/callback"
}

variable "initial_owner_email" {
  type        = string
  description = "The address that becomes the first Owner on first sign-in. Must be one you can actually authenticate as."
}

variable "breakglass_secret_hash" {
  type        = string
  sensitive   = true
  default     = null
  description = "SHA-256 of a strong secret: printf %s '<secret>' | shasum -a 256. Break-glass needs this AND breakglass_owner_email; the email alone arms nothing."
}

variable "external_database_url" {
  type        = string
  sensitive   = true
  default     = null
  description = "Your own Postgres (BYO-DB). The role needs CREATEDB. Null provisions the module's starter server instead."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to every resource the module creates."
}
