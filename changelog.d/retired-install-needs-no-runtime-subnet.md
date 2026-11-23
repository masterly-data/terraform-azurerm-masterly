### Changed

- **Breaking for an install already retired on a network the module builds.** With
  `retire_runtime_environment = true` the install has no runtime subnet. On a network the module
  builds, the module no longer creates `snet-aca`, its network security group
  `nsg-<name_prefix>-aca` and their association, and `nsg-<name_prefix>-private-endpoints` loses
  `allow-data-plane-from-apps`, the rule admitting `snet-aca`. On an injected network,
  `aca_subnet_id` is no longer needed: `private_endpoints_subnet_id` with `front_subnet_id`,
  `app_subnet_id` and `workers_subnet_id` is the whole network, and the module reads the virtual
  network from `front_subnet_id` when `aca_subnet_id` is unset. With `retire_runtime_environment`
  false (the default) nothing changes, and the plan now refuses `private_endpoints_subnet_id`
  without `aca_subnet_id`, because `aca-<name_prefix>` would have nowhere to run.

  Migration: an install that has not set `retire_runtime_environment` plans no change. An install
  that set it on an earlier version plans, on a network the module builds, only the deletion of
  `snet-aca`, `nsg-<name_prefix>-aca` and their association, and an in-place update of
  `nsg-<name_prefix>-private-endpoints` removing `allow-data-plane-from-apps`; every other subnet
  keeps its prefix. Read the plan before applying it: nothing else should change. Azure releases
  the subnet only once `aca-<name_prefix>` is fully deleted, so an install that sets
  `retire_runtime_environment` and upgrades in one apply may need a second apply for the subnet.
  On an injected network the plan shows no change: `aca_subnet_id` may stay set, and the module
  creates nothing on it. If you remove it and the plan shows the private DNS zone links replaced,
  `aca_subnet_id` and `front_subnet_id` spell the virtual network's id differently; keep
  `aca_subnet_id` set. Your platform team can delete or reuse the runtime subnet once
  `aca-<name_prefix>` is gone. If you ever set `retire_runtime_environment` back to false, the
  install needs a runtime subnet of /23 or larger again.

- A retired install fits a small address space. With `retire_runtime_environment = true` and no
  explicit environment prefixes, a first `vnet_address_space` prefix of /22 to /24 is carved in
  quarters: front, app and workers in the first three, the private endpoints in the fourth unless
  `private_endpoints_subnet_prefix` places them elsewhere. A /24 for the environments plus a /28 for
  the private endpoints is a complete install (`docs/networking.md`, "A /24 and a /28"). Before,
  `vnet_address_space` refused anything smaller than a /21 without an explicit runtime /23.

- The refusal of `retire_runtime_environment = true` while a workload still runs in
  `aca-<name_prefix>` is now a precondition on the `rg-<name_prefix>-aca` resource group rather
  than a validation on the variable. It refuses the same plans with the same message; only the
  address an error names has changed.

### Documentation

- The /23 requirement now applies only to the runtime subnet while `aca-<name_prefix>` runs, in the
  variable descriptions (`aca_subnet_id`, `aca_subnet_prefix`, `private_endpoints_subnet_prefix`,
  `vnet_address_space` and the environment subnet inputs), `docs/networking.md` and the README.
  `docs/networking.md` adds a worked /24 + /28 layout, an injected-network example with no runtime
  subnet, and what retiring does to the runtime subnet on each network shape.
