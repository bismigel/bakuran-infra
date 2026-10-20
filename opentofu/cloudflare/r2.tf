resource "cloudflare_r2_bucket_lifecycle" "homelab_backups" {
  account_id  = var.account_id
  bucket_name = "homelab-backups"

  rules = [
    {
      id      = "Default Multipart Abort Rule"
      enabled = true
      conditions = { prefix = "" }
      abort_multipart_uploads_transition = {
        condition = { type = "Age", max_age = 604800 }
      }
    },
    {
      id      = "expire-appdata-14d"
      enabled = true
      conditions = { prefix = "appdata/" }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 1209600 }
      }
    },
    {
      id      = "expire-credentials-90d"
      enabled = true
      conditions = { prefix = "credentials/" }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 7776000 }
      }
    },
    {
      id      = "expire-nixstation-90d"
      enabled = true
      conditions = { prefix = "nixstation/" }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 7776000 }
      }
    },
  ]
}
