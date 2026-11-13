### Changed

- Internal refactor: the module's plan tests move from one file into one file per concern under `tests/` (`network.tftest.hcl`, `keyvault.tftest.hcl`, `postgres.tftest.hcl` and the rest), with their shared azurerm mock data in `tests/mocks/install/`. The same 438 runs pass, unchanged. No input, output or resource changes.
