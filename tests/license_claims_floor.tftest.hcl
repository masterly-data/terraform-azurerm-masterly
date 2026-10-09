# The licence claims-floor check (ADR 0013, amended 2026-10-06, point 5 "By a re-issued bundle"),
# against a synthetic release manifest — no provider, no cloud access.
#
# The runs in install.tftest.hcl prove the root module refuses the plan when this check says so,
# against the module's real MANIFEST.json. These prove the check itself, which needs releases whose
# api images verify a claims version above 0: none has been released yet, so a synthetic manifest
# is the only way to show a licence passing against an image at or above its floor.
#
# The tokens are the shape of a licence and nothing more. Each is a JOSE header, an empty payload
# ("e30" is "{}") and the word "unsigned" where a signature goes: no key signed them, none could
# verify them, and only the header is read here. The headers, base64url-decoded:
#   floor 2: {"alg":"ES256","typ":"JWT","kid":"fixture","masterly_claims_version":2,"masterly_claims_floor":2}
#   floor 1: {"alg":"ES256","typ":"JWT","kid":"fixture","masterly_claims_version":1,"masterly_claims_floor":1}
#   version 2, floor 1: {"alg":"ES256","typ":"JWT","kid":"fixture","masterly_claims_version":2,"masterly_claims_floor":1}
#   none: {"alg":"ES256","typ":"JWT","kid":"fixture"}
#   floor 2, base64url alphabet: {"alg":"ES256","typ":"JWT","kid":"fixture?","masterly_claims_version":2,"masterly_claims_floor":2}
#     (the "?" encodes as "_", and the segment needs one "=" of padding to decode)

variables {
  manifest = {
    schema_version = 1
    releases = {
      # Cut before api_claims_version existed: reads as 0.
      "1.0.0"  = { images = { api = "registry.example.invalid/api:v1.0.0" } }
      "1.1.0"  = { images = { api = "registry.example.invalid/api:v1.1.0" }, api_claims_version = 1 }
      "1.1.1"  = { images = { api = "registry.example.invalid/api:v1.1.0" }, api_claims_version = 1 }
      "1.10.0" = { images = { api = "registry.example.invalid/api:v1.10.0" }, api_claims_version = 2 }
      "1.2.0"  = { images = { api = "registry.example.invalid/api:v1.9.0" }, api_claims_version = 2 }
    }
  }

  floor_2_token        = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZpeHR1cmUiLCJtYXN0ZXJseV9jbGFpbXNfdmVyc2lvbiI6MiwibWFzdGVybHlfY2xhaW1zX2Zsb29yIjoyfQ.e30.unsigned"
  floor_1_token        = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZpeHR1cmUiLCJtYXN0ZXJseV9jbGFpbXNfdmVyc2lvbiI6MSwibWFzdGVybHlfY2xhaW1zX2Zsb29yIjoxfQ.e30.unsigned"
  v2_floor_1           = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZpeHR1cmUiLCJtYXN0ZXJseV9jbGFpbXNfdmVyc2lvbiI6MiwibWFzdGVybHlfY2xhaW1zX2Zsb29yIjoxfQ.e30.unsigned"
  headerless_token     = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZpeHR1cmUifQ.e30.unsigned"
  url_alphabet_floor_2 = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZpeHR1cmU_IiwibWFzdGVybHlfY2xhaW1zX3ZlcnNpb24iOjIsIm1hc3Rlcmx5X2NsYWltc19mbG9vciI6Mn0.e30.unsigned"
}

# The acceptance case: a floor above the pinned image's claims version is refused, and the message
# names the image's version, the licence's floor and the api tag to move to.
run "a_floor_above_the_image_is_refused_and_names_the_tag" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = var.floor_2_token
    api_image     = "registry.example.invalid/api:v1.1.0"
  }

  assert {
    condition     = output.refused && output.token_claims_floor == 2 && output.image_claims_version == 1
    error_message = "A licence with floor 2 must be refused on an api image that verifies claims version 1."
  }

  # v1.9.0 and v1.10.0 both verify 2. The oldest is v1.9.0 — by semver, not as text, where
  # "v1.10.0" sorts first.
  assert {
    condition     = output.move_to_tag == "v1.9.0"
    error_message = "The tag to move to must be the oldest recorded api release at or above the floor, ordered by semver."
  }

  assert {
    condition = alltrue([
      strcontains(output.message, "claims floor of 2"),
      strcontains(output.message, "registry.example.invalid/api:v1.1.0 verifies claims version 1"),
      strcontains(output.message, "The oldest api release that verifies it is v1.9.0."),
    ])
    error_message = "The refusal must name the licence's floor, the pinned image and its claims version, and the api tag to move to."
  }
}

# The same licence against an image at the floor, and above it, passes.
run "the_same_licence_passes_on_an_image_at_the_floor" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = var.floor_2_token
    api_image     = "registry.example.invalid/api:v1.9.0"
  }

  assert {
    condition     = !output.refused && output.message == null && output.image_claims_version == 2
    error_message = "A licence with floor 2 must pass on an api image that verifies claims version 2."
  }
}

run "a_licence_newer_than_the_image_within_its_floor_passes" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = var.v2_floor_1
    api_image     = "registry.example.invalid/api:v1.1.0"
  }

  assert {
    condition     = !output.refused && output.token_claims_version == 2 && output.token_claims_floor == 1
    error_message = "A licence minted at version 2 with floor 1 must pass on an image that verifies 1: the floor decides, not the version."
  }
}

# Air-gapped installs mirror the images into their own registry under the same tags. The tag is
# the build, so a mirrored image is checked like the original.
run "a_mirrored_image_is_checked_by_its_tag" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = var.floor_2_token
    api_image     = "mirror.example.invalid/masterly/api:v1.1.0"
  }

  assert {
    condition     = output.refused && output.image_claims_version == 1
    error_message = "A mirrored api image must be recognised by its tag and checked."
  }
}

run "a_headerless_licence_passes" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = var.headerless_token
    api_image     = "registry.example.invalid/api:v1.0.0"
  }

  assert {
    condition     = !output.refused && output.token_claims_version == 0 && output.token_claims_floor == 0 && output.image_claims_version == 0
    error_message = "A licence with no claims-version header is version 0, floor 0, and passes on every image, including one cut before api_claims_version existed."
  }
}

run "no_licence_passes" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = null
    api_image     = "registry.example.invalid/api:v1.0.0"
  }

  assert {
    condition     = !output.refused && output.token_claims_floor == 0
    error_message = "Without a licence there is nothing to check."
  }
}

# A token whose header is not JSON is the application's to refuse at startup; the plan does not
# second-guess it. This is the placeholder the other test file's runs use.
run "an_undecodable_header_passes" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = "eyJ.fake.jwt"
    api_image     = "registry.example.invalid/api:v1.0.0"
  }

  assert {
    condition     = !output.refused && output.token_claims_floor == 0
    error_message = "A token whose header cannot be decoded must not be refused at plan."
  }
}

# An image no recorded release names — newer than this module version, or built by hand — has no
# known claims version, so nothing is checked and the application's startup check stays the backstop.
run "an_image_the_manifest_does_not_record_is_not_checked" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = var.floor_2_token
    api_image     = "registry.example.invalid/api:v9.9.9"
  }

  assert {
    condition     = !output.refused && output.image_claims_version == null
    error_message = "An api image whose tag no release records must pass unchecked."
  }
}

# A floor above every recorded release names no tag; it says to upgrade the module instead.
run "a_floor_above_every_recorded_release_says_to_upgrade_the_module" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImZpeHR1cmUiLCJtYXN0ZXJseV9jbGFpbXNfdmVyc2lvbiI6MywibWFzdGVybHlfY2xhaW1zX2Zsb29yIjozfQ.e30.unsigned"
    api_image     = "registry.example.invalid/api:v1.10.0"
  }

  assert {
    condition     = output.refused && output.move_to_tag == null && strcontains(output.message, "upgrade the module")
    error_message = "A floor no recorded api release reaches must be refused with the advice to upgrade the module."
  }
}

# base64url is unpadded and uses "-" and "_" where base64 uses "+" and "/".
run "a_header_in_the_base64url_alphabet_decodes" {
  command = plan

  module {
    source = "./modules/license-claims-floor"
  }

  variables {
    license_token = var.url_alphabet_floor_2
    api_image     = "registry.example.invalid/api:v1.1.0"
  }

  assert {
    condition     = output.refused && output.token_claims_floor == 2
    error_message = "A header whose base64url encoding carries \"_\" and needs padding must still decode."
  }
}
