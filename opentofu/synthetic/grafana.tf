# The production edge, checked with k6 from Grafana Synthetic Monitoring's public probes.
# The performance/uptime plane: reachability, latency, TLS expiry - the complement to Checkly's
# browser journey. Probes are the public ones (us-east / eu-west / ap-south), verified live via
# /api/v1/probe: 1=Sydney, 3=Ohio, 4=NorthCalifornia, 14=London.
resource "grafana_synthetic_monitoring_check" "bismigel_http" {
  job       = "bismigel.dev http"
  target    = "https://bismigel.dev"
  probes    = [3, 4, 14, 1]
  frequency = 60000
  timeout   = 10000

  settings {
    http {
      method             = "GET"
      fail_if_ssl        = false
      fail_if_not_ssl    = false
      valid_status_codes = [200]
    }
  }
}

resource "grafana_synthetic_monitoring_check" "bismigel_tls" {
  job       = "bismigel.dev tls"
  target    = "bismigel.dev:443"
  probes    = [3, 4, 14, 1]
  frequency = 3600000
  timeout   = 10000

  settings {
    tcp {
      tls = true
    }
  }
}

resource "grafana_synthetic_monitoring_check" "edge_api" {
  job       = "edge api reachability"
  target    = "https://grafana.bismigel.dev"
  probes    = [3, 14]
  frequency = 60000
  timeout   = 10000

  settings {
    http {
      method             = "GET"
      fail_if_ssl        = false
      fail_if_not_ssl    = false
      valid_status_codes = [302]
    }
  }
}
