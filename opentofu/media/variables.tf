variable "radarr_url" {
  type    = string
  default = "http://192.168.10.81:7878"
}

variable "radarr_api_key" {
  type      = string
  sensitive = true
}

variable "sonarr_url" {
  type    = string
  default = "http://192.168.10.81:8989"
}

variable "sonarr_api_key" {
  type      = string
  sensitive = true
}

variable "telegram_bot_token" {
  type      = string
  sensitive = true
}

# The chat (or user) the *arr notifications go to — same one Alertmanager uses.
variable "telegram_chat_id" {
  type    = string
  default = "607008268"
}
