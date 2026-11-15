# Real time_rotating starts have one-second precision. Give successive test rotations distinct
# starts without depending on how quickly the test runner executes the intervening plan.
terraform {
  required_providers {
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

resource "time_sleep" "gap" {
  create_duration = "1s"
}
