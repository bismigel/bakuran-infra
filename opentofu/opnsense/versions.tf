terraform {
  required_version = ">= 1.6.0"

  required_providers {
    opnsense = {
      source = "matthew-on-git/opnsense"
      # Pinned EXACTLY, not `~>`, and the reason is measured rather than inherited: the
      # provider published four releases on 2026-11-04 alone (v0.11 -> v0.14) and 84 commits in
      # 30 days. This root manages live firewall rules on the only router in the estate, so an
      # unpinned minor bump could re-plan them between breakfast and dinner. Upgrading is a
      # reviewed change that starts with `tofu plan`, not a `tofu init -upgrade`.
      #
      # Migrated from `browningluke/opnsense` 0.26.0 on 2026-11-04: same objects, new provider,
      # imported rather than recreated (no apply touched the appliance).
      version = "= 0.31.1"
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
