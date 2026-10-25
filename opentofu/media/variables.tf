variable "radarr_url" {
  type    = string
  default = "http://192.168.2.81:7878"
}

variable "radarr_api_key" {
  type      = string
  sensitive = true
}

variable "sonarr_url" {
  type    = string
  default = "http://192.168.2.81:8989"
}

variable "sonarr_api_key" {
  type      = string
  sensitive = true
}
