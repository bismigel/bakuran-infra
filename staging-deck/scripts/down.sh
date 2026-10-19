#!/usr/bin/env bash
set -euo pipefail

: "${DECK_HOST:?set DECK_HOST}"

ssh -o BatchMode=yes "root@$DECK_HOST" 'poweroff'
