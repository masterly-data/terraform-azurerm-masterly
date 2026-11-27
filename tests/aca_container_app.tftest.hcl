# The aca-container-app submodule's own guards, run against the submodule directly (mock
# providers — no cloud access). The root module always passes a scale rule an identity it
# attaches, so these refusals cannot be reached through it; they are proven here instead.

mock_provider "azurerm" {}

variables {
  name                       = "ca-test"
  resource_group_name        = "rg-test"
  environment_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/aca-test"
  image                      = "registry.example.invalid/api:v0.0.0"
  ingress_enabled            = false
  user_assigned_identity_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-attached"]
}

# A scale rule authenticates as an identity attached to the app; one that is not attached is
# refused at plan rather than by Azure at apply.
run "a_scale_rule_identity_not_attached_to_the_app_is_refused" {
  command = plan

  module {
    source = "./modules/aca-container-app"
  }

  variables {
    custom_scale_rules = [{
      name             = "jobs-queue"
      custom_rule_type = "azure-servicebus"
      metadata         = { queueName = "jobs", namespace = "sb-test", messageCount = "5" }
      identity_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-other"
    }]
  }

  expect_failures = [azurerm_container_app.this]
}

# The same rule with the attached identity, and one with no identity, plan.
run "a_scale_rule_with_the_attached_identity_or_none_plans" {
  command = plan

  module {
    source = "./modules/aca-container-app"
  }

  variables {
    custom_scale_rules = [
      {
        name             = "jobs-queue"
        custom_rule_type = "azure-servicebus"
        metadata         = { queueName = "jobs", namespace = "sb-test", messageCount = "5" }
        identity_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-attached"
      },
      {
        name             = "no-identity"
        custom_rule_type = "azure-servicebus"
        metadata         = { queueName = "jobs", namespace = "sb-test", messageCount = "5" }
      },
    ]
  }

  assert {
    condition     = length(output.scale.custom_scale_rules) == 2
    error_message = "Both scale rules must reach the app."
  }
}

# Threat: a published app serves plain HTTP, so a bearer token crosses the network in clear.
# The root never asks for it (security_profile.tftest.hcl asserts every app it publishes), so the
# refusal is proven here, where it can be reached.
run "external_ingress_with_plain_http_is_refused" {
  command = plan

  module {
    source = "./modules/aca-container-app"
  }

  variables {
    ingress_enabled        = true
    ingress_external       = true
    ingress_target_port    = 8001
    ingress_allow_insecure = true
  }

  expect_failures = [var.ingress_allow_insecure]
}

# Plain HTTP on internal ingress (ca-api's in-environment hop), and external ingress without it,
# both plan.
run "internal_ingress_with_plain_http_plans" {
  command = plan

  module {
    source = "./modules/aca-container-app"
  }

  variables {
    ingress_enabled        = true
    ingress_external       = false
    ingress_target_port    = 8001
    ingress_allow_insecure = true
  }

  assert {
    condition     = output.ingress_external == false && output.ingress_allow_insecure == true
    error_message = "Internal ingress may keep plain HTTP for the hop inside the environment."
  }
}

run "external_ingress_without_plain_http_plans" {
  command = plan

  module {
    source = "./modules/aca-container-app"
  }

  variables {
    ingress_enabled     = true
    ingress_external    = true
    ingress_target_port = 3000
  }

  assert {
    condition     = output.ingress_external == true && output.ingress_allow_insecure == false
    error_message = "External ingress must default to HTTPS only."
  }
}
