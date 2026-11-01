# Omada controller. Credentials come from the environment, never from this file:
#   TF_VAR_omada_url        https://192.168.2.32:8043   (or wherever the controller runs)
#   TF_VAR_omada_username   ...
#   TF_VAR_omada_password   ...
variable "omada_url" {
  type = string
}

variable "omada_username" {
  type = string
}

variable "omada_password" {
  type      = string
  sensitive = true
}

provider "omada" {
  url      = var.omada_url
  username = var.omada_username
  password = var.omada_password
}
