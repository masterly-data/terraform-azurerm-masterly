### Documentation

- **Leftover diagnostic settings after a destroy that stopped partway.** `docs/data-plane.md`,
  "Destroying a production install", now says what to do when the targets of the module's
  diagnostic settings were deleted outside Terraform, for example with their resource group, and
  an apply under the same `name_prefix` fails on `azurerm_monitor_diagnostic_setting` with
  `already exists - needs to be imported`. It lists the 16 settings the module creates with their
  targets and the conditions that create them, and gives the `az monitor diagnostic-settings list`
  and `delete` commands. The delete is for a destroyed install only, by exact name and target id:
  never a prefix wildcard or a loop over `list`, and never against a live install. A destroy
  Terraform completes needs no cleanup. No module behaviour changes.
