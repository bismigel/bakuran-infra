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

# The IPv6 path from the networks used outside the LAN is intermittently lossy,
# and every client that prefers AAAA pays for it. Repeated curls from one
# dual-stack client against jellyfin.bismigel.dev:
#
#   v4  dns=0.013  tcp=0.023  ttfb=0.094      v6  dns=0.015  tcp=1.044  ttfb=1.246
#   v4  dns=0.015  tcp=0.025  ttfb=0.185      v6  dns=0.015  tcp=0.025  ttfb=0.240
#   v4  dns=0.012  tcp=0.022  ttfb=0.078      v6  dns=5.016  tcp=5.027  ttfb=5.215
#   v4  dns=0.012  tcp=0.022  ttfb=0.151      v6  dns=0.011  tcp=0.022  ttfb=0.192
#
# Two shapes, same cause. A 1.0s handshake and a 5.0s lookup are both
# retransmission: the 5.016s figure is a DNS query that went unanswered and was
# retried on the 5s timer, and the 1.04s connect is a lost SYN. When the path
# works it is as fast as IPv4 (0.02s), so this is loss, not latency — which is
# worse for a video stream, because it fails in bursts instead of being
# uniformly slow.
#
# Browsers hide it with Happy Eyeballs; Jellyfin clients and TVs do not, so they
# stall, tear the stream down and re-request — the ffmpeg restart loop.
#
# While this is "on", Cloudflare answers AAAA for every proxied hostname in the
# zone, and there is no per-hostname way to suppress it. Turning the zone-level
# setting off removes the AAAA answers, so no client can select the lossy path
# and no resolver has an AAAA to retry. Revert by deleting this block if IPv6
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
