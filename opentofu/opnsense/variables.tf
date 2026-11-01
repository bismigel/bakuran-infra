variable "opnsense_uri" {
  description = "OPNsense base URL, e.g. https://192.168.2.1"
  type        = string
  default     = "https://192.168.2.1"
}

variable "opnsense_api_key" {
  description = "API key (System > Access > Users > root > API keys). Supplied from BWS via env, never committed."
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret" {
  description = "API secret. Supplied from BWS via env, never committed."
  type        = string
  sensitive   = true
}
