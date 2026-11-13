# The azurerm mock data every per-concern test file shares (MAS-4478), exactly what
# the module's single plan-test file declared inline before it was split. Kept apart from tests/mocks/migrate, which also pins
# object_id and resource ids these runs never had.

# The Key Vault resource validates tenant_id as a UUID; the auto-generated mock value
# is a random string, so pin the client-config data source.
mock_data "azurerm_client_config" {
  defaults = {
    tenant_id = "00000000-0000-0000-0000-000000000000"
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
