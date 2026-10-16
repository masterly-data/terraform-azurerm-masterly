# Self-test fixture for the iac-scan job. NOT part of the module: it is never applied, and
# the job's real scan skips this directory. It is one deliberately insecure Key Vault, so the
# job can prove the scanner still reports a misconfiguration before it trusts a clean result.
# If the scanner ever stops reading Terraform, a green scan would otherwise mean nothing.

resource "azurerm_key_vault" "known_bad" {
  name                = "iac-scan-self-test"
  location            = "swedencentral"
  resource_group_name = "iac-scan-self-test"
  tenant_id           = "00000000-0000-0000-0000-000000000000"
  sku_name            = "standard"

  # The known-bad setting: public network access with the firewall open to everyone.
  public_network_access_enabled = true

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}
