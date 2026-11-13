# Tests

`terraform test` runs every `*.tftest.hcl` here: the per-concern plan files (one per module concern,
such as `network.tftest.hcl` or `keyvault.tftest.hcl`), the files whose runs apply, and the nested
modules' own files. Add a run to the file of the concern it asserts on. A run that applies goes last
in its file, after every plan run that does not read its state.

## What every plan file starts with

Each per-concern plan file starts with the same two parts. Copy them into a new file:

- the three mock providers, with azurerm loading the shared mock data:
  `mock_provider "azurerm" { source = "./tests/mocks/install" }`, then `mock_provider "random" {}`
  and `mock_provider "azapi" {}`;
- the same file-wide `variables` block: location, org_id, install_id, the two images,
  acr_login_server, key_vault_deployer_ip_rules and alert_email, with the comments that say why the
  last two are set for every run.

To change one of those values, change it in every plan file at once. The block is repeated on
purpose. A shared `terraform.tfvars.json` here would reach every test file, and it changed the
outcome of runs in `release_channel`, `workers_identity` and `workers_identity_unchanged`, which
rely on the images or `acr_login_server` being unset (MAS-4478). A `*.tfvars` file is ruled out
anyway: `.gitignore` ignores it with no exception, on purpose.
