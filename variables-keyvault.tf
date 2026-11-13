# Inputs read by keyvault.tf: the secret names of a bring-your-own database.

variable "migrate_byo_database_secret_names" {
  type        = set(string)
  default     = []
  nullable    = false
  description = "Existing per-Environment BYO-DB connection secret names in this install's Key Vault that the migrate job may read. Default empty grants no runtime secret access. Add each sealed connection_ref's secret name and apply before provisioning; update this set when a connection gets a new secret name. Names only, never DSNs, URLs or install-* secrets. Requires migrations = \"job\"; grants Key Vault Secrets User at each secret, never at the vault."

  validation {
    condition     = length(var.migrate_byo_database_secret_names) == 0 || var.migrations == "job"
    error_message = "migrate_byo_database_secret_names requires migrations = \"job\"; otherwise leave it empty."
  }

  validation {
    condition     = alltrue([for name in var.migrate_byo_database_secret_names : can(regex("^[0-9A-Za-z-]{1,127}$", name)) && !can(regex("(?i)^install-", name))])
    error_message = "migrate_byo_database_secret_names must contain only BYO-DB connection secret names (1-127 letters, digits or hyphens), never paths, URLs or reserved install-* secrets."
  }
}
