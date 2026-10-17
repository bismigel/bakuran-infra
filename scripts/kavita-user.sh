#!/usr/bin/env bash
# kavita-user.sh — list, lock, unlock, or register Kavita users.
#
#   ./scripts/kavita-user.sh list
#   ./scripts/kavita-user.sh lock   <username>
#   ./scripts/kavita-user.sh unlock <username>
#   ./scripts/kavita-user.sh register <username>   # delegates to kavita-add-user.sh
#
# Kavita has no API to change roles, so lock/unlock edits AspNetUserRoles in the
# SQLite DB: removing the "Login" role makes the account exist but login is
# refused with "Your account is disabled" (the same state seen for a bad invite).
# Unlock re-adds it. The pod is restarted after a DB change; already-issued JWTs
# stay valid until they expire, so this blocks new logins, not active sessions.
#
# Requires: kubectl (or KUBECTL="k3s kubectl"), sqlite3, tar. On nix-station:
#   nix shell nixpkgs#sqlite -c ./scripts/kavita-user.sh list
set -euo pipefail
NS="${NS:-books}"; DEPLOY="${DEPLOY:-kavita}"; K="${KUBECTL:-kubectl}"
SQLITE="${SQLITE:-sqlite3}"

action="${1:?usage: kavita-user.sh <list|lock|unlock|register> [username]}"
user="${2:-}"

if [ "$action" = "register" ]; then
  [ -n "$user" ] || { echo "usage: kavita-user.sh register <username>" >&2; exit 1; }
  exec "$(dirname "${BASH_SOURCE[0]}")/kavita-add-user.sh" "$user"
fi

POD="$($K -n "$NS" get pods -l "app=$DEPLOY" -o name | head -1)"; POD="${POD#pod/}"
[ -n "$POD" ] || { echo "no $DEPLOY pod in $NS" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fetch_db() {
  # WAL/SHM may be absent (checkpointed on restart); tar only what exists.
  $K -n "$NS" exec "$POD" -- sh -c '
    cd /config || exit 1
    set -- kavita.db
    [ -f kavita.db-wal ] && set -- "$@" kavita.db-wal
    [ -f kavita.db-shm ] && set -- "$@" kavita.db-shm
    tar cf - "$@"' | tar xf - -C "$TMP"
}

if [ "$action" = "list" ]; then
  fetch_db
  "$SQLITE" -header -column "$TMP/kavita.db" \
    "select u.UserName as user, group_concat(r.Name, ' ') as roles
       from AspNetUsers u
       left join AspNetUserRoles ur on ur.UserId = u.Id
       left join AspNetRoles r on r.Id = ur.RoleId
      group by u.Id order by u.UserName;"
  exit 0
fi

case "$action" in lock|unlock) ;; *) echo "unknown action: $action" >&2; exit 1;; esac
[ -n "$user" ] || { echo "usage: kavita-user.sh $action <username>" >&2; exit 1; }
[[ "$user" =~ ^[A-Za-z0-9._@-]+$ ]] || { echo "invalid username" >&2; exit 1; }
esc="${user//\'/\'\'}"

fetch_db
if ! "$SQLITE" "$TMP/kavita.db" "select 1 from AspNetUsers where UserName='$esc';" | grep -q 1; then
  echo "no such user: $user" >&2; exit 1
fi

if [ "$action" = "lock" ]; then
  "$SQLITE" "$TMP/kavita.db" "delete from AspNetUserRoles
    where UserId=(select Id from AspNetUsers where UserName='$esc' limit 1)
      and RoleId=(select Id from AspNetRoles where Name='Login' limit 1);"
  echo ">> locked $user (Login role removed)"
else
  "$SQLITE" "$TMP/kavita.db" "insert into AspNetUserRoles (UserId, RoleId)
    select u.Id, r.Id from AspNetUsers u, AspNetRoles r
     where u.UserName='$esc' and r.Name='Login'
       and not exists (select 1 from AspNetUserRoles ur where ur.UserId=u.Id and ur.RoleId=r.Id);"
  echo ">> unlocked $user (Login role added)"
fi
"$SQLITE" "$TMP/kavita.db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
rm -f "$TMP/kavita.db-wal" "$TMP/kavita.db-shm"

$K -n "$NS" cp "$TMP/kavita.db" "$POD:/config/kavita.db"
$K -n "$NS" exec "$POD" -- sh -c 'rm -f /config/kavita.db-wal /config/kavita.db-shm; chown 1000:1000 /config/kavita.db 2>/dev/null || true'
$K -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1 || true
echo ">> Kavita restarting"
