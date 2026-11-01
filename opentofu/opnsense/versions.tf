terraform {
  required_version = ">= 1.6.0"

  required_providers {
    opnsense = {
      source = "browningluke/opnsense"
      # Pinned EXACTLY, not `~>`. The provider is pre-1.0 and its README states that
      # schemas may change between releases and that it is not recommended for
      # production until v1.0. An unpinned minor bump could re-plan live firewall
      # rules; upgrading is a reviewed change, not a `tofu init -upgrade`.
      version = "= 0.26.0"
    }
  }

  # State lives with the other OpenTofu roots (same R2 bucket, one key per root).
  # It contains the API-derived resource state - treat it as sensitive, never commit.
  backend "s3" {
    bucket                      = "homelab-backups"
    key                         = "opentofu/opnsense/terraform.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://c13ab6fbc2a53cfe719bca75fdc825c2.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_lockfile                = true
  }
}
