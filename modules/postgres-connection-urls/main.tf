# The starter server's connection URLs (ADR 0003, MAS-2365): the URL the api and the workers use
# for their sessions, which goes through the built-in PgBouncer when the root module turns it on,
# and the direct URL on the server itself for what a transaction pooler cannot carry (CREATE
# DATABASE, migrations). Both use the same role, database and TLS requirement; only the port
# differs.
#
# No resources and no provider: the URLs are composed here so that a plan-only test can check the
# exact strings from known inputs (tests/postgres_connection_urls.tftest.hcl), where in the root
# module the server's fqdn is only known after apply.

locals {
  # On entra the userinfo is the role alone: the api presents a token, and no URL carries a
  # password (entra-auth.tf in the root module).
  userinfo = var.auth_mode == "entra" ? var.role : "${var.role}:${var.password}"

  pooler_url = "postgresql+asyncpg://${local.userinfo}@${var.server_fqdn}:${var.pooler_port}/${var.database_name}?ssl=require"
  direct_url = "postgresql+asyncpg://${local.userinfo}@${var.server_fqdn}:${var.direct_port}/${var.database_name}?ssl=require"
}
