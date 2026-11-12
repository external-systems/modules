# shellcheck shell=bash disable=SC2034,SC2154
# A fragment: hostSpec.services.odoo (odoo.nix, mkScript) sets prog, instances,
# golden_root and snapshot_root and puts lib.sh first; the built script is
# linted whole again by writeShellApplication.
# Shared by odoo-reset, odoo-snapshot, odoo-purge and odoo-golden-save
# (hostSpec.services.odoo). The wrapper sets, before this file:
#   prog           the command name, for messages
#   instances      JSON list of the configured instances (name, unit,
#                  stateDir, dataDir, httpPort, url, demoData, goldenKey)
#   golden_root    where reset copies live: <golden_root>/<name>/{data.tar,key}
#   snapshot_root  where snapshots live: <snapshot_root>/<name>/<tag>.tar
# Database names: odoo-<name> (the instance), odoo-<name>@golden (its
# reset copy), odoo-<name>@snap-<tag> (snapshots). Instance names cannot
# contain @, so the suffixes never collide with an instance.

die() {
  echo "$prog: $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo $prog ...)"
}

sql() {
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -qtA -d postgres "$@"
}

configured() {
  jq -e --arg n "$1" 'any(.[]; .name == $n)' "$instances" >/dev/null
}

field() {
  jq -r --arg n "$1" --arg f "$2" '.[] | select(.name == $n) | .[$f]' "$instances"
}

instance_names() {
  jq -r '.[].name' "$instances"
}

db_exists() {
  [ "$(sql -c "SELECT count(*) FROM pg_database WHERE datname = '$1'")" = 1 ]
}

# Drops a database, also one frozen as a template.
drop_db() {
  if db_exists "$1"; then
    sql -c "ALTER DATABASE \"$1\" WITH IS_TEMPLATE false ALLOW_CONNECTIONS true" \
      -c "DROP DATABASE \"$1\" WITH (FORCE)"
  fi
}

# A copy nobody connects to and that only serves as a template.
freeze_db() {
  sql -c "ALTER DATABASE \"$1\" WITH IS_TEMPLATE true ALLOW_CONNECTIONS false"
}

# copy_db SOURCE TARGET OWNER: a file-level copy (CREATE DATABASE
# TEMPLATE), seconds even with demo data. SOURCE must have no connections.
copy_db() {
  sql -c "CREATE DATABASE \"$2\" OWNER \"$3\" TEMPLATE \"$1\""
}

# save_data DATADIR ARCHIVE [tar --exclude ...]: the instance's files
# (filestore, markers) without sessions.
save_data() {
  local data=$1 archive=$2
  shift 2
  tar -C "$data" --exclude=./sessions "$@" -cf "$archive.tmp" .
  mv "$archive.tmp" "$archive"
}

# restore_data NAME ARCHIVE: replaces the instance's state with ARCHIVE.
restore_data() {
  local name=$1 archive=$2 state data unit
  state=$(field "$name" stateDir)
  data=$(field "$name" dataDir)
  unit=$(field "$name" unit)
  if [ -d "$state" ]; then
    find "$state" -mindepth 1 -delete
  fi
  mkdir -p "$data"
  tar -C "$data" -xf "$archive"
  chown -R "$unit:$unit" "$state"
}

# Starts the unit and waits until Odoo answers on its port.
start_and_wait() {
  local name=$1 unit port
  unit=$(field "$name" unit)
  port=$(field "$name" httpPort)
  # A deliberate start: clear the crash-loop limit (StartLimitBurst counts
  # every start, so repeated resets would otherwise lock the unit out).
  systemctl reset-failed "$unit.service" 2>/dev/null || true
  systemctl start "$unit.service"
  for _ in $(seq 300); do
    if curl -sf -o /dev/null "http://127.0.0.1:$port/web/login"; then
      return 0
    fi
    sleep 1
  done
  die "$name did not answer on port $port; see journalctl -u $unit"
}

# confirm MESSAGE: asks for "yes" unless $yes is true.
confirm() {
  if ! $yes; then
    [ -t 0 ] || die "not a terminal: pass --yes"
    echo "$1"
    read -r -p "Type yes to continue: " answer
    [ "$answer" = yes ] || die "aborted, nothing changed"
  fi
}

# The reset copy of NAME is usable when it exists and was made from the
# current configuration (package, addons, demo data, apps, language).
golden_valid() {
  local name=$1 dir="$golden_root/$1"
  [ -f "$dir/data.tar" ] && [ -f "$dir/key" ] &&
    [ "$(cat "$dir/key")" = "$(field "$name" goldenKey)" ] &&
    db_exists "$(field "$name" unit)@golden"
}

drop_golden() {
  drop_db "$(field "$1" unit)@golden"
  rm -rf "${golden_root:?}/$1"
}
