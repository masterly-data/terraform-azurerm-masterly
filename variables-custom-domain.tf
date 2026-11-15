# Inputs read by custom-domain.tf: the frontend's and the edge's custom domains.

variable "frontend_custom_domain" {
  type = object({
    hostname                        = string
    certificate_key_vault_secret_id = string
    key_vault_id                    = string
  })
  default     = null
  description = "Serve ca-frontend on your own hostname, with your own TLS certificate held in your own Key Vault. Null (the default) binds no hostname and creates nothing, exactly as before this input existed. hostname: a bare lowercase FQDN such as masterly.example.com, with no scheme, port, path or wildcard. certificate_key_vault_secret_id: the certificate's secret id WITHOUT a version, https://<vault>.vault.azure.net/secrets/<certificate name>; the private key never leaves the vault and never enters Terraform, and because the reference names no version the environment picks up a renewed certificate in the vault without an apply. key_vault_id: the resource id of the vault that holds it, which must use Azure RBAC authorization and be reachable from the Container App Environment. The module creates a dedicated identity, id-<prefix>-frontend-cert, attached to the Container App Environment and to no app, and grants it Key Vault Secrets User on that one secret alone; the principal that applies must be allowed to create that role assignment on the vault (Owner, User Access Administrator or Role Based Access Control Administrator there). With identity_binding = \"oidc\" the redirect URI derives from the hostname, https://<hostname>/api/auth/callback, so oidc_redirect_uri can stay unset and a production install is one apply. The asuid.<hostname> TXT record (the custom_domain_verification_id, readable before the first apply) must exist before the apply that binds the hostname; docs/networking.md lists it, the A or CNAME record and when each can be created, and the Application Gateway settings."

  # Conditionals, not `||`: before Terraform 1.12 both sides of `||` are evaluated, and the right
  # side reads attributes of a null object when the input is unset (as builtin_auth).
  validation {
    condition = var.frontend_custom_domain == null ? true : (
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.frontend_custom_domain.hostname)) &&
      try(length(var.frontend_custom_domain.hostname) <= 253, false)
    )
    error_message = "frontend_custom_domain.hostname must be a bare lowercase fully qualified domain name such as masterly.example.com: no scheme, port, path, wildcard, IP address or uppercase letters, at least one dot, and labels of a-z, 0-9 and hyphens that neither start nor end with a hyphen, the last starting with a letter."
  }

  # Versionless, so the vault is where the certificate rotates. A versioned id would pin the
  # environment to one certificate until someone re-applies, and it expires there.
  validation {
    condition     = var.frontend_custom_domain == null ? true : can(regex("^https://[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]\\.vault\\.(azure\\.net|azure\\.cn|usgovcloudapi\\.net)/secrets/[a-zA-Z0-9-]{1,127}$", var.frontend_custom_domain.certificate_key_vault_secret_id))
    error_message = "frontend_custom_domain.certificate_key_vault_secret_id must be the certificate's versionless secret id, https://<vault>.vault.azure.net/secrets/<certificate name>: under /secrets/ (not /certificates/), with no version segment and no trailing slash, so a certificate renewed in the vault is picked up without an apply."
  }

  # The grant is made on key_vault_id, and the certificate is read from the vault the secret id
  # names: refuse a pair that disagrees, rather than grant on one vault and read from another.
  validation {
    condition = var.frontend_custom_domain == null ? true : (
      can(regex("^/subscriptions/[^/]+/resource[gG]roups/[^/]+/providers/Microsoft\\.KeyVault/vaults/[^/]+$", var.frontend_custom_domain.key_vault_id)) &&
      lower(try(regex("^/subscriptions/[^/]+/resource[gG]roups/[^/]+/providers/Microsoft\\.KeyVault/vaults/([^/]+)$", var.frontend_custom_domain.key_vault_id)[0], "")) ==
      lower(try(regex("^https://([^.]+)\\.", var.frontend_custom_domain.certificate_key_vault_secret_id)[0], "-"))
    )
    error_message = "frontend_custom_domain.key_vault_id must be the resource id of the vault that holds the certificate (/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>), and <name> must be the vault certificate_key_vault_secret_id points at."
  }
}

variable "edge_custom_domain" {
  type = object({
    hostname                        = string
    certificate_key_vault_secret_id = string
    key_vault_id                    = string
  })
  default     = null
  description = "Serve ca-edge, the machine entry point for the Python SDK and MCP clients, on your own hostname, with your own TLS certificate held in your own Key Vault. Requires edge. Null (the default) binds no hostname and creates nothing, and edge_url stays the Container Apps FQDN. The same shape and rules as frontend_custom_domain, with a different hostname: hostname: a bare lowercase FQDN such as api.masterly.example.com, with no scheme, port, path or wildcard, and not frontend_custom_domain's. certificate_key_vault_secret_id: the certificate's secret id WITHOUT a version, https://<vault>.vault.azure.net/secrets/<certificate name>; the private key never leaves the vault and never enters Terraform, and the environment picks up a renewed certificate without an apply. key_vault_id: the resource id of the vault that holds it, which must use Azure RBAC authorization and be reachable from the Container App Environment. The module creates a dedicated identity, id-<prefix>-edge-cert, attached to the Container App Environment and to no app (never to ca-edge, whose identity holds no secret role), and grants it Key Vault Secrets User on that one secret alone; the principal that applies must be allowed to create that role assignment on the vault. The asuid.<hostname> TXT record (the custom_domain_verification_id) must exist before the apply that binds the hostname; docs/networking.md lists it and the A or CNAME record."

  # Conditionals, not `||`, as in frontend_custom_domain above.
  validation {
    condition = var.edge_custom_domain == null ? true : (
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.edge_custom_domain.hostname)) &&
      try(length(var.edge_custom_domain.hostname) <= 253, false)
    )
    error_message = "edge_custom_domain.hostname must be a bare lowercase fully qualified domain name such as api.masterly.example.com: no scheme, port, path, wildcard, IP address or uppercase letters, at least one dot, and labels of a-z, 0-9 and hyphens that neither start nor end with a hyphen, the last starting with a letter."
  }

  # Versionless, so the vault is where the certificate rotates.
  validation {
    condition     = var.edge_custom_domain == null ? true : can(regex("^https://[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]\\.vault\\.(azure\\.net|azure\\.cn|usgovcloudapi\\.net)/secrets/[a-zA-Z0-9-]{1,127}$", var.edge_custom_domain.certificate_key_vault_secret_id))
    error_message = "edge_custom_domain.certificate_key_vault_secret_id must be the certificate's versionless secret id, https://<vault>.vault.azure.net/secrets/<certificate name>: under /secrets/ (not /certificates/), with no version segment and no trailing slash, so a certificate renewed in the vault is picked up without an apply."
  }

  # The grant is made on key_vault_id, and the certificate is read from the vault the secret id
  # names: refuse a pair that disagrees.
  validation {
    condition = var.edge_custom_domain == null ? true : (
      can(regex("^/subscriptions/[^/]+/resource[gG]roups/[^/]+/providers/Microsoft\\.KeyVault/vaults/[^/]+$", var.edge_custom_domain.key_vault_id)) &&
      lower(try(regex("^/subscriptions/[^/]+/resource[gG]roups/[^/]+/providers/Microsoft\\.KeyVault/vaults/([^/]+)$", var.edge_custom_domain.key_vault_id)[0], "")) ==
      lower(try(regex("^https://([^.]+)\\.", var.edge_custom_domain.certificate_key_vault_secret_id)[0], "-"))
    )
    error_message = "edge_custom_domain.key_vault_id must be the resource id of the vault that holds the certificate (/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<name>), and <name> must be the vault certificate_key_vault_secret_id points at."
  }

  # The hostname binds to ca-edge, which exists only with edge set: refused here rather than at the
  # binding, whose precondition would never run while edge, and so the binding, is off.
  validation {
    condition     = var.edge_custom_domain == null ? true : var.edge != null
    error_message = "edge_custom_domain binds a hostname to ca-edge, which exists only with edge set: set edge as well (edge = {} for its defaults), or leave edge_custom_domain unset."
  }

  # One hostname, one app: Azure refuses a second binding of the same name in the environment, and
  # the frontend and the edge serve different paths.
  validation {
    condition = var.edge_custom_domain == null ? true : (
      var.frontend_custom_domain == null ? true : lower(var.edge_custom_domain.hostname) != lower(var.frontend_custom_domain.hostname)
    )
    error_message = "edge_custom_domain.hostname must differ from frontend_custom_domain.hostname: ca-frontend and ca-edge each need a hostname of their own (for example masterly.example.com and api.masterly.example.com), with a certificate that covers it."
  }
}
