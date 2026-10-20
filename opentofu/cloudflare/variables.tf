variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "account_id" {
  type    = string
  default = "c13ab6fbc2a53cfe719bca75fdc825c2"
}

variable "zone_id" {
  type    = string
  default = "d7786ec1130918385079b8f224f271b5"
}

variable "domain" {
  type    = string
  default = "bismigel.dev"
}
