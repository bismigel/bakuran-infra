# Root folders. Small, but they are the one piece of *arr wiring that a rebuild
# from zero gets wrong silently: without a root folder Sonarr/Radarr accept
# searches and then have nowhere to import.
#
# These already exist, so they are imported rather than created (import blocks;
# `tofu plan` previews it, `apply` adopts them into state). Verify with
# `tofu plan` afterwards: it must report no changes, otherwise the declared
# values differ from the live ones.

import {
  to = radarr_root_folder.movies
  id = "1"
}

resource "radarr_root_folder" "movies" {
  path = "/movies"
}

import {
  to = sonarr_root_folder.tv
  id = "1"
}

resource "sonarr_root_folder" "tv" {
  path = "/tv"
}
