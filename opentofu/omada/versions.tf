terraform {
  required_version = ">= 1.6"
  required_providers {
    omada = {
      # explicit hostname: this provider is published to the Terraform registry, not the OpenTofu one
      source  = "registry.terraform.io/wncservices/omada"
      version = "0.13.2" # latest as of 2026-11-01
    }
  }
  # Same R2 bucket as the OPNsense root, different key, so one credential reaches both.
  backend "s3" {
    bucket                      = "homelab-backups"
    key                         = "opentofu/omada/terraform.tfstate"
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
