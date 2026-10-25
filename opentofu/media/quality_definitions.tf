# Per-quality size caps (MB per minute, which is what the *arr APIs use).
#
# Why this file exists: nothing capped 2160p. Stock Radarr ships
# `maxSize: null` for every 2160p class, so a 68G Remux-2160p was accepted and
# became 21% of the whole media library (2026-10-24). recyclarr cannot express
# these numbers (its `quality_definition` only takes TRaSH presets, and those are
# Max = Unlimited), so sizing lives here — exactly one owner per object:
#
#   recyclarr  -> quality_profiles + custom_format scores
#   this file  -> quality_definitions (sizes only)
#
# Units check, from measurements rather than guesses:
#   1080p WEB-DL/Bluray      ~30-45 MB/min   (a 1.8G 60min episode = 30)
#   2160p WEB-DL (DV/HDR)   ~125-310 MB/min  (the 34G replacement = 309)
#   2160p Remux             ~450-750 MB/min  (the 68G Remux = ~620)
#
# So: 1080p capped at 35 (2.1G/h) still admits real 1080p releases; 2160p capped
# at 250 (~15G/h, 30G for a 2h film) blocks remuxes and the fattest WEB-DLs
# while leaving typical 4K WEB-DLs alone.

locals {
  # Untouched qualities keep whatever stock value they have.
  radarr_sizes = {
    "HDTV-720p"    = { max = 22, preferred = 11 }
    "WEBDL-720p"   = { max = 22, preferred = 11 }
    "WEBRip-720p"  = { max = 22, preferred = 11 }
    "Bluray-720p"  = { max = 22, preferred = 11 }
    "HDTV-1080p"   = { max = 35, preferred = 20 }
    "WEBDL-1080p"  = { max = 35, preferred = 20 }
    "WEBRip-1080p" = { max = 35, preferred = 20 }
    "Bluray-1080p" = { max = 35, preferred = 20 }
    "Remux-1080p"  = { max = 60, preferred = 40 } # Radarr name
    # (Sonarr calls the same class "Bluray-1080p Remux".)
    "HDTV-2160p"   = { max = 250, preferred = 150 }
    "WEBDL-2160p"  = { max = 250, preferred = 150 }
    "WEBRip-2160p" = { max = 250, preferred = 150 }
    "Bluray-2160p" = { max = 250, preferred = 150 }
    "Remux-2160p"  = { max = 400, preferred = 300 }
  }

  # Sonarr uses the same quality names for the classes it has.
  sonarr_sizes = {
    "HDTV-720p"          = { max = 22, preferred = 11 }
    "WEBDL-720p"         = { max = 22, preferred = 11 }
    "WEBRip-720p"        = { max = 22, preferred = 11 }
    "Bluray-720p"        = { max = 22, preferred = 11 }
    "HDTV-1080p"         = { max = 35, preferred = 20 }
    "WEBDL-1080p"        = { max = 35, preferred = 20 }
    "WEBRip-1080p"       = { max = 35, preferred = 20 }
    "Bluray-1080p"       = { max = 35, preferred = 20 }
    "Bluray-1080p Remux" = { max = 60, preferred = 40 } # Sonarr name
    "HDTV-2160p"         = { max = 250, preferred = 150 }
    "WEBDL-2160p"        = { max = 250, preferred = 150 }
    "WEBRip-2160p"       = { max = 250, preferred = 150 }
    "Bluray-2160p"       = { max = 250, preferred = 150 }
    "Bluray-2160p Remux" = { max = 400, preferred = 300 }
  }
}

data "radarr_quality_definitions" "all" {}
data "sonarr_quality_definitions" "all" {}

resource "radarr_quality_definition" "size" {
  for_each = local.radarr_sizes

  # Look the id up by title so this survives an *arr upgrade renumbering ids.
  id             = one([for qd in data.radarr_quality_definitions.all.quality_definitions : qd.id if qd.title == each.key])
  title          = each.key
  max_size       = each.value.max
  preferred_size = each.value.preferred
}

resource "sonarr_quality_definition" "size" {
  for_each = local.sonarr_sizes

  id             = one([for qd in data.sonarr_quality_definitions.all.quality_definitions : qd.id if qd.title == each.key])
  title          = each.key
  max_size       = each.value.max
  preferred_size = each.value.preferred
}

output "radarr_caps" {
  value = { for k, v in local.radarr_sizes : k => v.max }
}

output "sonarr_caps" {
  value = { for k, v in local.sonarr_sizes : k => v.max }
}
