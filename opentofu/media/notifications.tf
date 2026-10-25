# Notifications to the homelab Telegram bot, declared like everything else.
#
# Deliberately *failure* signals only. Sonarr/Radarr can also notify on every
# grab/import/upgrade, which for a TV library is a message per episode; this lab
# already alerts on things that need a human (Alertmanager -> Telegram), so the
# same rule applies here: warn on failure, stay quiet on success.
#
# Telegram, not Discord/e-mail: the bot and the chat already exist (BWS
# `telegram-bot-token`, chat id from RUNBOOK). The token is a TF variable so it
# comes from BWS at apply time and never lands in state as plaintext-readable
# config or on disk.

locals {
  # Shared by both apps.
  arr_notify_common = {
    on_health_issue                = true
    on_health_restored             = true
    on_application_update          = true
    on_download                    = false # fired constantly; the failure paths below cover it
    on_grab                        = false
    on_rename                      = false
    on_upgrade                     = false
    on_manual_interaction_required = true
  }
}

resource "radarr_notification" "telegram" {
  name            = "Telegram (homelab)"
  implementation  = "Telegram"
  config_contract = "TelegramSettings"

  bot_token = var.telegram_bot_token
  chat_id   = var.telegram_chat_id

  # Radarr has no on_import_complete; on_download covers import failures via
  # on_manual_interaction_required + health issues.
  on_health_issue                = local.arr_notify_common.on_health_issue
  on_health_restored             = local.arr_notify_common.on_health_restored
  on_application_update          = local.arr_notify_common.on_application_update
  on_download                    = local.arr_notify_common.on_download
  on_grab                        = local.arr_notify_common.on_grab
  on_rename                      = local.arr_notify_common.on_rename
  on_upgrade                     = local.arr_notify_common.on_upgrade
  on_manual_interaction_required = local.arr_notify_common.on_manual_interaction_required
  on_movie_delete                = false
}

resource "sonarr_notification" "telegram" {
  name            = "Telegram (homelab)"
  implementation  = "Telegram"
  config_contract = "TelegramSettings"

  bot_token = var.telegram_bot_token
  chat_id   = var.telegram_chat_id

  on_health_issue                = local.arr_notify_common.on_health_issue
  on_health_restored             = local.arr_notify_common.on_health_restored
  on_application_update          = local.arr_notify_common.on_application_update
  on_download                    = local.arr_notify_common.on_download
  on_grab                        = local.arr_notify_common.on_grab
  on_rename                      = local.arr_notify_common.on_rename
  on_upgrade                     = local.arr_notify_common.on_upgrade
  on_manual_interaction_required = local.arr_notify_common.on_manual_interaction_required
  on_import_complete             = false
}
