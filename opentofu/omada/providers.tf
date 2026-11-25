# Omada controller. Credentials come from the environment, never from this file:
#   TF_VAR_omada_url        https://192.168.10.32:8043   (or wherever the controller runs)
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

variable "omada_site" {
  type        = string
  default     = "Bakuran"
  description = "Site name in the controller (a new site is not marked primary, so it must be named)"
}

# The site has to be named explicitly. A freshly created site is not reported as *primary*, and the
# provider refuses to guess ("no site specified and no primary site found") - which is the right
# call: adopting a network into the wrong site would be worse than failing.
provider "omada" {
  url      = var.omada_url
  username = var.omada_username
  password = var.omada_password
  site     = var.omada_site
}
