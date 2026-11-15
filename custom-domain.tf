# ca-frontend on the customer's own hostname, with the customer's own certificate, read from the
# customer's Key Vault (frontend_custom_domain). Off by default: unset, nothing here is created
# and the frontend answers on its Container Apps FQDN only, exactly as before the input existed.
# ca-edge gets the same, on a hostname of its own, with edge_custom_domain (below).
#
# The certificate's private key never passes through Terraform. The input carries a reference,
# the versionless secret id, and no certificate or password; the environment reads the key from
# the vault itself, as a dedicated identity, and because the reference names no version it picks
# up a certificate renewed in the vault without an apply.
#
# Certificates managed by Container Apps are not offered: Azure cannot issue one for an app on an
# internal environment (aca_internal_load_balancer), which is where a customer's Application
# Gateway terminates in front of the install.

locals {
  frontend_custom_domain   = var.frontend_custom_domain != null
  frontend_custom_hostname = local.frontend_custom_domain ? var.frontend_custom_domain.hostname : null

  # The certificate's secret name, the last segment of the versionless id (variables-custom-domain.tf has
  # checked its shape), for the role assignment's scope.
  frontend_certificate_secret_name = local.frontend_custom_domain ? element(split("/", var.frontend_custom_domain.certificate_key_vault_secret_id), 4) : null
}

# The identity the environment reads the certificate as. Its own, never the frontend's: the
# frontend runs code an attacker reaches first, and a read on the certificate would hand them the
# private key of the customer's hostname. It is attached to the environment (module.aca_env) and
# to no Container App, and holds one role, below.
module "frontend_certificate_identity" {
  source = "./modules/user-assigned-identity"
  count  = local.frontend_custom_domain ? 1 : 0

  name                = "id-${var.name_prefix}-frontend-cert"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# Key Vault Secrets User on the certificate's secret alone, never the vault: the customer's vault
# may hold anything else. A certificate's key is readable only through its secret, so this is the
# narrowest grant that loads it. Scoped by the secret's ARM id, built from the vault id and the
# name, as kv_byo_database_reader_migrate (keyvault.tf) does for a secret this module does not
# manage. The principal that applies needs the right to create it on that vault.
resource "azurerm_role_assignment" "frontend_certificate_reader" {
  count = local.frontend_custom_domain ? 1 : 0

  scope                = "${var.frontend_custom_domain.key_vault_id}/secrets/${local.frontend_certificate_secret_name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.frontend_certificate_identity[0].principal_id
}

resource "azurerm_container_app_environment_certificate" "frontend" {
  count = local.frontend_custom_domain ? 1 : 0

  name                         = "cert-${var.name_prefix}-frontend"
  container_app_environment_id = module.aca_env.id

  # A reference only: no certificate_blob_base64, no certificate_password.
  certificate_key_vault {
    identity            = module.frontend_certificate_identity[0].id
    key_vault_secret_id = var.frontend_custom_domain.certificate_key_vault_secret_id
  }

  tags = local.tags

  # The read must be granted before the environment loads the certificate. Entra RBAC is
  # eventually consistent, so a first apply can still land inside the propagation window and
  # fail here; re-running the apply is the remedy, as for the install's own vault (keyvault.tf).
  depends_on = [azurerm_role_assignment.frontend_certificate_reader]
}

# The hostname on ca-frontend, by SNI, with the certificate above. A resource of its own rather
# than a block on the app, so the app's own configuration (module "frontend") is unchanged by it:
# the same ingress, the same ingress_allowed_cidrs, still HTTPS only. Azure checks the
# asuid.<hostname> TXT record (custom_domain_verification_id) when it creates this, so the record
# must exist before the apply that does; docs/networking.md says when the A or CNAME record can.
resource "azurerm_container_app_custom_domain" "frontend" {
  count = local.frontend_custom_domain ? 1 : 0

  name                                     = local.frontend_custom_hostname
  container_app_id                         = module.frontend.id
  container_app_environment_certificate_id = azurerm_container_app_environment_certificate.frontend[0].id
  certificate_binding_type                 = "SniEnabled"
}

# ca-edge on the customer's own hostname (edge_custom_domain): the same four resources, with a
# certificate identity of their own. Not the frontend's, so neither app's certificate is readable
# through the other's grant; and never the edge's own identity (id-<prefix>-edge), which faces the
# internet and holds no secret role (ADR 0120).

locals {
  # edge_custom_domain's validation refuses it without edge; the second operand only keeps the
  # binding's azurerm_container_app.edge[0] from being read while that refusal is reported.
  edge_custom_domain   = var.edge_custom_domain != null && local.edge_enabled
  edge_custom_hostname = local.edge_custom_domain ? var.edge_custom_domain.hostname : null

  edge_certificate_secret_name = local.edge_custom_domain ? element(split("/", var.edge_custom_domain.certificate_key_vault_secret_id), 4) : null
}

# Attached to the environment (module.aca_env) and to no Container App, ca-edge included.
module "edge_certificate_identity" {
  source = "./modules/user-assigned-identity"
  count  = local.edge_custom_domain ? 1 : 0

  name                = "id-${var.name_prefix}-edge-cert"
  resource_group_name = azurerm_resource_group.aca.name
  location            = var.location
  tags                = local.tags
}

# Key Vault Secrets User on the certificate's secret alone, never the vault.
resource "azurerm_role_assignment" "edge_certificate_reader" {
  count = local.edge_custom_domain ? 1 : 0

  scope                = "${var.edge_custom_domain.key_vault_id}/secrets/${local.edge_certificate_secret_name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.edge_certificate_identity[0].principal_id
}

resource "azurerm_container_app_environment_certificate" "edge" {
  count = local.edge_custom_domain ? 1 : 0

  name                         = "cert-${var.name_prefix}-edge"
  container_app_environment_id = module.aca_env.id

  # A reference only: no certificate_blob_base64, no certificate_password.
  certificate_key_vault {
    identity            = module.edge_certificate_identity[0].id
    key_vault_secret_id = var.edge_custom_domain.certificate_key_vault_secret_id
  }

  tags = local.tags

  # As for the frontend's: the read is granted first, and a first apply inside RBAC's propagation
  # window is re-run.
  depends_on = [azurerm_role_assignment.edge_certificate_reader]
}

# The hostname on ca-edge, by SNI. A resource of its own, so ca-edge's ingress (edge.tf) is
# unchanged by it: the same allowlist, still HTTPS only. Azure checks the asuid.<hostname> TXT
# record when it creates this, as for the frontend.
resource "azurerm_container_app_custom_domain" "edge" {
  count = local.edge_custom_domain ? 1 : 0

  name                                     = local.edge_custom_hostname
  container_app_id                         = azurerm_container_app.edge[0].id
  container_app_environment_certificate_id = azurerm_container_app_environment_certificate.edge[0].id
  certificate_binding_type                 = "SniEnabled"
}
