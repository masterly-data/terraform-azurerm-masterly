# The azurerm mock data every per-concern test file shares (MAS-4478), exactly what
# the module's single plan-test file declared inline before it was split. Kept apart from tests/mocks/migrate, which also pins
# object_id and resource ids these runs never had.

# The Key Vault resource validates tenant_id as a UUID, and since azurerm v5.14.0 a role
# assignment validates principal_id as one too (kv_secrets_officer_deployer grants the
# deploying principal, client_config's object_id). The auto-generated mock values are random
# strings, so pin both; the object_id is the one tests/mocks/migrate uses.
mock_data "azurerm_client_config" {
  defaults = {
    tenant_id = "00000000-0000-0000-0000-000000000000"
    object_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
  }
}

# The lookup entra-auth.tf makes for an existing server or cache. Empty by default — every run
# is a NEW install unless it says otherwise with an override_data block (see the runs in
# entra_auth.tftest.hcl, "Authentication to Postgres and Redis").
mock_data "azurerm_resources" {
  defaults = {
    resources = []
  }
}
