# Security-relevant zone settings. These mirror the current production edge.

resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.zone_id
  setting_id = "ssl"
  value      = "full"
}

resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = var.zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = var.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# Clients with half-working IPv6 pay about a second per connection before they
# fall back to IPv4. Measured from a dual-stack client against
# jellyfin.bismigel.dev:
#
#   v4  dns=0.013s  tcp=0.023s  ttfb=0.094s
#   v6  dns=0.015s  tcp=1.044s  ttfb=1.246s
#
# DNS is identical on both paths — the cost is the IPv6 TCP/TLS handshake and
# the throughput that follows. Browsers mask it with Happy Eyeballs (~250ms of
# delay); Jellyfin's clients, TVs and other native apps do not, and for a video
# stream the same path shows up as buffering: the player cannot pull HLS
# segments fast enough, tears the transcode down, and re-requests — which is
# exactly the ffmpeg restart / "cannot serve ... no transcode is running"
# pattern in the Jellyfin log.
#
# While this is "on", Cloudflare answers AAAA for every proxied hostname in the
# zone, and there is no per-hostname way to suppress it. Turning the zone-level
# setting off removes the AAAA answers, so every client uses IPv4 — the path
# that is 45x faster to establish here. Revert by deleting this block if IPv6
# becomes reliable from the networks used outside the LAN.
resource "cloudflare_zone_setting" "ipv6" {
  zone_id    = var.zone_id
  setting_id = "ipv6"
  value      = "off"
}

resource "cloudflare_zone_setting" "security_header" {
  zone_id    = var.zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 15552000
      include_subdomains = true
      preload            = false
      nosniff            = false
    }
  }
}
