terraform {
  required_version = ">= 1.6"
  required_providers {
    checkly = {
      source  = "checkly/checkly"
      version = "~> 1.7"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 2.15"
    }
  }
}

provider "checkly" {
  api_key    = var.checkly_api_key
  account_id = var.checkly_account_id
}

# Synthetic Monitoring checks live in the main grafana provider, configured with BOTH
# the instance service-account token (auth) and the SM access token (sm_access_token).
# The sm_url is the regional SM API (ca-east-0), discovered from the SM datasource's apiHost.
provider "grafana" {
  url             = var.grafana_url
  auth            = var.grafana_auth
  sm_url          = var.sm_url
  sm_access_token = var.sm_access_token
}
