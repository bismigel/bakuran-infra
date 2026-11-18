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

variable "ciceley_zone_id" {
  type    = string
  default = "bfca3075a1f1d5d2836aca7f4558af0b"
}

variable "miguel_zone_id" {
  type    = string
  default = "0ee0ef4302ab23094e39aae78ca9492e"
}

# Household members allowed through Zero Trust Access, supplied at plan time (Bitwarden: access-household-emails).
#
# A literal address here used to be one family member's personal email, committed to a repository that is now public.
# The owner's address stays in the clear - it is in every commit's metadata anyway - but a second person's does not
# belong in a public repo, and an email is not a value that can be "just a placeholder": Access policies are live
# configuration, so the value has to keep working. Hence a variable rather than redaction.
variable "household_emails" {
  description = "Additional emails allowed through Access (from Bitwarden: access-household-emails)"
  type        = list(string)
}

# Where cloudflared sends traffic. ClusterIPs of the two ingress controllers, not host ports: see tunnel.tf.
variable "public_target" {
  description = "Service the public ingress controller exposes (svc ingress-nginx-controller)"
  type        = string
  default     = "http://10.43.46.55:80"
}

variable "admin_target" {
  description = "Service the Access-gated ingress controller exposes (svc ingress-nginx-admin-controller)"
  type        = string
  default     = "http://10.43.15.7:80"
}

# The mailbox that receives security@bismigel.dev. It is a variable rather than a literal because the destination address has to be
# verified from that mailbox, and a report that silently bounces is the failure this address exists to avoid.
variable "security_mailbox" {
  description = "Destination mailbox for security@bismigel.dev (must be verified by clicking Cloudflare's email)"
  type        = string
  default     = "miguelarbis@protonmail.com"
}

variable "operator_email" {
  type        = string
  description = "The single address allowed on operator-only surfaces (ArgoCD, Longhorn, the agent)."
  default     = "bismigel@pm.me"
}
