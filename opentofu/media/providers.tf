provider "radarr" {
  url     = var.radarr_url
  api_key = var.radarr_api_key
}

provider "sonarr" {
  url     = var.sonarr_url
  api_key = var.sonarr_api_key
}
