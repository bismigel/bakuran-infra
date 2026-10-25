terraform {
  required_version = ">= 1.6.0"

  required_providers {
    radarr = {
      source = "devopsarr/radarr"
    }
    sonarr = {
      source = "devopsarr/sonarr"
    }
  }

  # Same R2 bucket as opentofu/cloudflare, separate key.
  backend "s3" {
    bucket                      = "homelab-backups"
    key                         = "opentofu/media/terraform.tfstate"
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
