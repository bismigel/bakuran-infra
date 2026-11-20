# The production edge, checked from Checkly's public locations - the Playwright/user-journey plane.
# Browser check = "does a real user actually see the site" (k6 cannot do this).
resource "checkly_check" "bismigel_site_browser" {
  name      = "bismigel.dev renders (browser)"
  type      = "BROWSER"
  activated = true
  frequency = 10
  locations = ["us-east-1", "eu-west-1"]
  runtime_id = "2026.04"
  script     = file("${path.module}/../../synthetic/browser-journey.js")
  double_check = true

  alert_settings {
    escalation_type = "RUN_BASED"
    run_based_escalation {
      failed_run_threshold = 2
    }
  }
}

# API check = "is the edge reachable" - cheaper and more frequent than the browser check.
resource "checkly_check" "bismigel_site_api" {
  name      = "bismigel.dev reachable (api)"
  type      = "API"
  activated = true
  frequency = 5
  locations = ["us-east-1", "eu-west-1", "ap-south-1"]

  request {
    method = "GET"
    url    = "https://bismigel.dev"
    assertion {
      source     = "STATUS_CODE"
      comparison = "EQUALS"
      target     = "200"
    }
  }

  alert_settings {
    escalation_type = "RUN_BASED"
    run_based_escalation {
      failed_run_threshold = 2
    }
  }
}
