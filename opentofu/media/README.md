# Media stack: quality-definition size caps (OpenTofu)

Owns **one** thing: `quality_definition` sizes for Radarr and Sonarr.

    recyclarr (bakuran-gitops manifests/media/recyclarr.yaml)
        -> quality_profiles + custom_format scores
    this module
        -> quality_definitions: min/max/preferred MB per minute
    ArgoCD
        -> workload shape

Nothing is co-managed — that is deliberate. recyclarr's `quality_definition`
only accepts TRaSH presets and those are `Max = 1000 (Unlimited)` for every
quality, so sizing cannot live there.

## Why it exists

Stock Radarr ships `maxSize: null` for **every** 2160p class. A 68G
Remux-2160p was accepted and became 21% of the whole library, which filled a
mergerfs branch and broke imports (2026-10-24).

## The numbers (MB per minute, measured, not guessed)

| Class | Cap | Roughly |
| --- | --- | --- |
| 720p | 22 | 1.3 GB/h (stock default, unchanged) |
| 1080p | 35 | 2.1 GB/h — a 1.8 GB/h episode passes |
| Remux-1080p / Bluray-1080p Remux | 60 | 3.6 GB/h |
| 2160p | 250 | 15 GB/h — admits the usual WEB-DLs (125-310 MB/min), blocks remuxes (450-750) |
| Remux-2160p / Bluray-2160p Remux | 400 | 24 GB/h (no profile allows this class anyway) |

Measurements behind them: a 60-min 1080p episode = ~30 MB/min; the 34 GB
2160p WEB-DL replacement for the 68 G remux = ~309 MB/min; the remux itself
= ~620 MB/min.

## Usage

```bash
export TF_VAR_radarr_api_key="$(… BWS radarr-api-key …)"   # never to disk
export TF_VAR_sonarr_api_key="$(… BWS sonarr-api-key …)"
export AWS_ACCESS_KEY_ID=…  AWS_SECRET_ACCESS_KEY=…        # BWS r2-* (state backend)
tofu init && tofu plan && tofu apply
```

State: `homelab-backups/opentofu/media/terraform.tfstate` (R2).

`id` is looked up by **title** from the `*_quality_definitions` data source, so
an *arr upgrade that renumbers ids does not break this. Note Radarr calls the
1080p remux class `Remux-1080p` and Sonarr calls it `Bluray-1080p Remux`.

## Not in here yet

Indexers (Prowlarr), download clients, root folders, notifications. Those are
still `bakuran-infra/scripts/media-stack-setup.sh`; moving them here is the
next step and should be done one resource at a time (see
`opentofu/cloudflare/README.md` for the same discipline).

## Also owned: root folders

`root_folders.tf` imports the existing `/movies` (Radarr) and `/tv` (Sonarr) root
folders so a rebuild from zero cannot end up with an instance that searches but
has nowhere to import. They are **import blocks**, not creates — `tofu plan`
previews the import and `apply` adopts them; a follow-up `plan` must report
**no changes**, otherwise the declared `path` disagrees with the live one.

## Also owned: notifications

`notifications.tf` declares the Telegram notification for both apps
(`implementation = Telegram`, `config_contract = TelegramSettings`), pointing at
the same bot/chat Alertmanager uses. Token comes from BWS `telegram-bot-token`
as `TF_VAR_telegram_bot_token`; chat id defaults to `607008268`.

**Failure signals only** — health issue/restored, application update, manual
interaction required. `on_grab`, `on_download`, `on_upgrade`, `on_rename` and
`on_import_complete` are off: this library produces an episode per hour, and the
lab's rule elsewhere is "warn on what needs a human".

Note the provider requires `on_movie_delete` on Radarr (not present on Sonarr) —
`tofu validate` will tell you if a future provider version adds another required
event flag.
