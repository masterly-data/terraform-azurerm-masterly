# The starter server's connection URLs (MAS-2365), from known inputs — no provider, no cloud access.
#
# The postgres_pgbouncer runs in install.tftest.hcl prove the root module gives this module the
# pooler and direct ports, the role and the auth mode for each database_auth. There the server's
# fqdn and the password are only known after apply, so these runs prove the exact strings.

variables {
  server_fqdn = "psql-masterly-abc123.postgres.database.azure.com"
}

run "password_urls_on_the_pooler_and_the_server" {
  command = plan

  module {
    source = "./modules/postgres-connection-urls"
  }

  variables {
    auth_mode   = "password"
    role        = "masterly_admin"
    password    = "fixture-password"
    pooler_port = "6432"
  }

  assert {
    condition     = output.pooler_url == "postgresql+asyncpg://masterly_admin:fixture-password@psql-masterly-abc123.postgres.database.azure.com:6432/postgres?ssl=require"
    error_message = "On password with the pooler, pooler_url must be masterly_admin with its password on :6432/postgres?ssl=require."
  }

  assert {
    condition     = output.direct_url == "postgresql+asyncpg://masterly_admin:fixture-password@psql-masterly-abc123.postgres.database.azure.com:5432/postgres?ssl=require"
    error_message = "On password, direct_url must be the same role, password and postgres database on :5432, never the pooler."
  }
}

run "entra_urls_carry_no_password" {
  command = plan

  module {
    source = "./modules/postgres-connection-urls"
  }

  variables {
    auth_mode   = "entra"
    role        = "id-masterly-apps-test"
    pooler_port = "6432"
  }

  assert {
    condition     = output.pooler_url == "postgresql+asyncpg://id-masterly-apps-test@psql-masterly-abc123.postgres.database.azure.com:6432/postgres?ssl=require"
    error_message = "On entra with the pooler, pooler_url must be the identity's role alone on :6432/postgres?ssl=require."
  }

  assert {
    condition     = output.direct_url == "postgresql+asyncpg://id-masterly-apps-test@psql-masterly-abc123.postgres.database.azure.com:5432/postgres?ssl=require"
    error_message = "On entra, direct_url must be the same role and postgres database on :5432, with no password."
  }

  assert {
    condition     = !can(regex("://[^@/]*:", output.pooler_url)) && !can(regex("://[^@/]*:", output.direct_url))
    error_message = "On entra, neither URL's userinfo may carry a password."
  }
}

# Without the pooler both URLs are the server itself, as the install-level DSN was before
# postgres_pgbouncer existed.
run "without_the_pooler_both_urls_are_on_the_server" {
  command = plan

  module {
    source = "./modules/postgres-connection-urls"
  }

  variables {
    auth_mode   = "password"
    role        = "masterly_admin"
    password    = "fixture-password"
    pooler_port = "5432"
  }

  assert {
    condition     = output.pooler_url == "postgresql+asyncpg://masterly_admin:fixture-password@psql-masterly-abc123.postgres.database.azure.com:5432/postgres?ssl=require"
    error_message = "Without the pooler, pooler_url must be the server itself on :5432, unchanged from before postgres_pgbouncer."
  }
}

run "entra_refuses_a_password" {
  command = plan

  module {
    source = "./modules/postgres-connection-urls"
  }

  variables {
    auth_mode   = "entra"
    role        = "id-masterly-apps-test"
    password    = "fixture-password"
    pooler_port = "6432"
  }

  expect_failures = [var.password]
}

run "password_requires_a_password" {
  command = plan

  module {
    source = "./modules/postgres-connection-urls"
  }

  variables {
    auth_mode   = "password"
    role        = "masterly_admin"
    pooler_port = "6432"
  }

  expect_failures = [var.password]
}
