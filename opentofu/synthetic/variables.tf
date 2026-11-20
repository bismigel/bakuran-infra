variable "checkly_api_key" {
  type      = string
  sensitive = true
}
variable "checkly_account_id" {
  type = string
}

variable "grafana_url" {
  type    = string
  default = "https://livelybookcase1371.grafana.net/"
}
variable "grafana_auth" {
  type      = string
  sensitive = true
}
variable "sm_url" {
  type    = string
  default = "https://synthetic-monitoring-api-ca-east-0.grafana.net"
}
variable "sm_access_token" {
  type      = string
  sensitive = true
}
