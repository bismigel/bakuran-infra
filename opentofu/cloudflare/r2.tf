resource "cloudflare_r2_bucket_lifecycle" "homelab_backups" {
  account_id  = var.account_id
  bucket_name = "homelab-backups"

  rules = [
    {
      id         = "Default Multipart Abort Rule"
      enabled    = true
      conditions = { prefix = "" }
      abort_multipart_uploads_transition = {
        condition = { type = "Age", max_age = 604800 }
      }
    },
    {
      id         = "expire-appdata-14d"
      enabled    = true
      conditions = { prefix = "appdata/" }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 1209600 }
      }
    },
    {
      id         = "expire-credentials-90d"
      enabled    = true
      conditions = { prefix = "credentials/" }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 7776000 }
      }
    },
    {
      id         = "expire-nixstation-90d"
      enabled    = true
      conditions = { prefix = "nixstation/" }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 7776000 }
      }
    },
  ]
}

# Artifact Server's blobs live in their own bucket, not under a prefix of `homelab-backups`. Two reasons: the backup
# bucket's lifecycle expires prefixes by age (appdata 14d, credentials 90d), and a bucket whose rules are written for
# disposable copies is the wrong place for artifacts someone linked to; and a compromised application credential should
# not be able to read the backups. Separate bucket, separate token, no shared deletion rules.
resource "cloudflare_r2_bucket" "artifact_server" {
  account_id = var.account_id
  name       = "artifact-server"
}

# Same default abort rule as `homelab_backups` above: an upload that dies mid-multipart leaves its parts billed and
# invisible, and nothing in the application ever resumes one. Seven days is long enough for a large artifact over a slow
# link, short enough that abandoned parts stop costing storage. Deliberately no `delete_objects_transition` - artifacts
# are not expirable by age.
resource "cloudflare_r2_bucket_lifecycle" "artifact_server" {
  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.artifact_server.name

  rules = [
    {
      id         = "Default Multipart Abort Rule"
      enabled    = true
      conditions = { prefix = "" }
      abort_multipart_uploads_transition = {
        condition = { type = "Age", max_age = 604800 }
      }
    },
  ]
}
