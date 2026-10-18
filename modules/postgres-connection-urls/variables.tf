variable "server_fqdn" {
  type        = string
  description = "The starter Flexible Server's fully qualified domain name."
}

variable "database_name" {
  type        = string
  default     = "postgres"
  description = "The database both URLs connect to. The api's install-level connection is the server's postgres database (ADR 0003); it creates each Environment's database from there."
}

variable "auth_mode" {
  type        = string
  description = "How the api authenticates to the server (the root module's database_auth, resolved): \"password\" puts the password in both URLs; \"entra\" puts none, since the api presents an Entra token instead."

  validation {
    condition     = contains(["password", "entra"], var.auth_mode)
    error_message = "auth_mode must be \"password\" or \"entra\"."
  }
}

variable "role" {
  type        = string
  description = "The login both URLs connect as: masterly_admin on password, the apps' identity's Entra role on entra."
}

variable "password" {
  type        = string
  default     = null
  sensitive   = true
  description = "The role's password on auth_mode = \"password\". Must be null on \"entra\", so no URL can carry one there."

  validation {
    condition     = (var.auth_mode == "password") == (var.password != null)
    error_message = "password is required on auth_mode = \"password\" and must be null on \"entra\"."
  }
}

variable "pooler_port" {
  type        = string
  description = "The port of pooler_url: 6432 for the built-in PgBouncer (postgres_pgbouncer), otherwise 5432, the server itself."
}

variable "direct_port" {
  type        = string
  default     = "5432"
  description = "The port of direct_url: the server itself, never the pooler."
}
