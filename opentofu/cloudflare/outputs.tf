# What Artifact Server needs to configure its OIDC client. Read these with `tofu output -raw <name>` and put them in the
# cluster secret (Bitwarden -> ExternalSecret), never in a file in this repository.

output "artifact_server_oidc_client_id" {
  description = "OIDC client id for Artifact Server (Cloudflare Access SaaS app)"
  value       = cloudflare_zero_trust_access_application.artifact_server.saas_app.client_id
}

output "artifact_server_oidc_issuer" {
  description = "OIDC issuer URL Artifact Server validates tokens against"
  value       = "https://bakuran.cloudflareaccess.com/cdn-cgi/access/sso/oidc/${cloudflare_zero_trust_access_application.artifact_server.saas_app.client_id}"
}

# `sensitive = true` keeps this out of plan output and CI logs. Note the provider returns `client_secret` only in the
# create/update response, so a plain refresh can leave it empty in state; if this output ever reads as blank, rotate the
# client secret in Cloudflare rather than assuming the value was never set.
output "artifact_server_oidc_client_secret" {
  description = "OIDC client secret for Artifact Server (sensitive; store in Bitwarden, never commit)"
  value       = cloudflare_zero_trust_access_application.artifact_server.saas_app.client_secret
  sensitive   = true
}

# Turnstile for the Jiffley Shortlist host. The site key is public (it ships in the page); the secret is what the app
# verifies with, so it is marked sensitive and read once with `tofu output -raw ...` into Bitwarden.
output "turnstile_jiffley_shortlist_sitekey" {
  value = cloudflare_turnstile_widget.jiffley_shortlist.sitekey
}

output "turnstile_jiffley_shortlist_secret" {
  value     = cloudflare_turnstile_widget.jiffley_shortlist.secret
  sensitive = true
}

# The access application's AUD tag, for the app that verifies `Cf-Access-Jwt-Assertion` itself. It exists only after the
# application is created, so it is read here rather than copied out of the dashboard:
#   tofu output -raw jiffley_shortlist_access_aud      -> Bitwarden `easyshortlist-secrets` / `easyshortlist-cf-access-aud`
output "jiffley_shortlist_access_aud" {
  value = cloudflare_zero_trust_access_application.jiffley_shortlist_admin.aud
}
