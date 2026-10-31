# The release channel's choice of the default images, against a synthetic release manifest — no
# provider, no cloud access.
#
# The runs in install.tftest.hcl prove the root module resolves "stable" and "previous" against its
# real MANIFEST.json, and that only the digest differs between them. These prove what the shipped
# manifest never reaches: a release that records no digests, so its reference is pinned by the tag
# of the image it names; a channel that resolves to no release, which refuses the plan unless both
# images are set explicitly; and the ordering of versions as semver, not as text.

variables {
  registry = "registry.example.invalid"

  # 1.1.0 is the newest release and records no digests. Its only older release carries a
  # known_issue, so "previous" has no release here.
  manifest = {
    schema_version = 1
    latest         = "1.1.0"
    releases = {
      "1.0.0" = {
        images      = { api = "registry.example.invalid/api:v1.0.0", frontend = "registry.example.invalid/frontend:v2.0.0" }
        digests     = { api = "sha256:1111111111111111111111111111111111111111111111111111111111111111", frontend = "sha256:2222222222222222222222222222222222222222222222222222222222222222" }
        known_issue = "A synthetic fault, so that \"previous\" skips this release."
      }
      "1.1.0" = {
        images = { api = "registry.example.invalid/api:v1.1.0", frontend = "registry.example.invalid/frontend:v2.1.0" }
      }
    }
  }

  # A manifest whose `latest`, "0.10.0", sorts BEFORE both older releases as text ("0.10.0" <
  # "0.9.0" < "0.9.1"): ordered as text, nothing would be older than latest and "previous" would
  # resolve to nothing. Ordered as versions, 0.9.1 is the newest older release, and its
  # known_issue makes 0.9.0 the answer.
  ordered_manifest = {
    schema_version = 1
    latest         = "0.10.0"
    releases = {
      "0.9.0" = {
        images  = { api = "registry.example.invalid/api:v0.9.0", frontend = "registry.example.invalid/frontend:v0.9.0" }
        digests = { api = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", frontend = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
      }
      "0.9.1" = {
        images      = { api = "registry.example.invalid/api:v0.9.1", frontend = "registry.example.invalid/frontend:v0.9.1" }
        digests     = { api = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", frontend = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" }
        known_issue = "A synthetic fault, so that \"previous\" skips this release."
      }
      "0.10.0" = {
        images  = { api = "registry.example.invalid/api:v0.10.0", frontend = "registry.example.invalid/frontend:v0.10.0" }
        digests = { api = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", frontend = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" }
      }
    }
  }
}

# A release that records no digests is pinned by the tag of the image it names, still under
# release/<role> on the selected registry.
run "a_release_without_digests_is_pinned_by_its_tag" {
  command = plan

  module {
    source = "./modules/release-channel"
  }

  variables {
    channel = "stable"
  }

  assert {
    condition = (
      output.version == "1.1.0" &&
      output.images.api == "registry.example.invalid/release/api:v1.1.0" &&
      output.images.frontend == "registry.example.invalid/release/frontend:v2.1.0"
    )
    error_message = "A release with no digests must resolve to <registry>/release/<role>:<tag>, with the tag of the image the release names."
  }
}

# "previous" with no older release free of a known_issue resolves to nothing, and the plan is
# refused because the apps would have no image.
run "a_channel_with_no_release_and_no_explicit_images_is_refused" {
  command = plan

  module {
    source = "./modules/release-channel"
  }

  variables {
    channel = "previous"
  }

  expect_failures = [output.images]
}

# The same channel plans when both images are set explicitly: they are used as given, and the
# version reports that the channel resolved to no release.
run "a_channel_with_no_release_uses_the_explicit_images" {
  command = plan

  module {
    source = "./modules/release-channel"
  }

  variables {
    channel        = "previous"
    api_image      = "registry.example.invalid/api:v9.9.9"
    frontend_image = "registry.example.invalid/frontend:v9.9.9"
  }

  assert {
    condition = (
      output.version == null &&
      output.images.api == "registry.example.invalid/api:v9.9.9" &&
      output.images.frontend == "registry.example.invalid/frontend:v9.9.9"
    )
    error_message = "With both images set explicitly, a channel that resolves to no release must plan with those images and report no version."
  }
}

# "previous" is the newest release older than `latest` with no known_issue, ordered by semver:
# both older releases sort after "0.10.0" as text (and would make "previous" resolve to nothing),
# 0.9.1 is skipped for its known_issue, and 0.9.0 is the answer.
run "previous_skips_a_known_issue_and_orders_versions_as_semver" {
  command = plan

  module {
    source = "./modules/release-channel"
  }

  variables {
    manifest = var.ordered_manifest
    channel  = "previous"
  }

  assert {
    condition = (
      output.version == "0.9.0" &&
      output.images.api == "registry.example.invalid/release/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" &&
      output.images.frontend == "registry.example.invalid/release/frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    )
    error_message = "\"previous\" must skip a release with a known_issue and order versions as semver, not as text."
  }
}

# The module stands on its own: it refuses a channel it does not know, as the root module does.
run "an_unknown_channel_is_refused" {
  command = plan

  module {
    source = "./modules/release-channel"
  }

  variables {
    channel = "canary"
  }

  expect_failures = [var.channel]
}
