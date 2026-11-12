# shellcheck shell=bash disable=SC2034,SC2154
# A fragment: hostSpec.services.odoo (odoo.nix, mkScript) sets prog, instances,
# golden_root and snapshot_root and puts lib.sh first; the built script is
# linted whole again by writeShellApplication.
usage() {
  cat <<'EOF'
Usage: odoo-purge
       odoo-purge [--yes] NAME...

Without names: lists what removed Odoo instances left behind (a database
or role odoo-NAME, its reset copy and snapshots, or state under
/var/lib/private/odoo-NAME, /var/lib/odoo-golden/NAME or
/var/lib/odoo-snapshots/NAME, for a NAME no longer configured). With
names: deletes all of it. A configured instance is refused: odoo-reset
empties those. Runs as root.

  --yes    do not ask for confirmation (needed without a terminal)
EOF
}

leftovers() {
  {
    # odoo-NAME, odoo-NAME@golden, odoo-NAME@snap-TAG.
    sql -c "SELECT datname FROM pg_database WHERE datname LIKE 'odoo-%'" | sed -E 's/@.*$//'
    sql -c "SELECT rolname FROM pg_roles WHERE rolname LIKE 'odoo-%'"
    for dir in /var/lib/private/odoo-*; do
      if [ -e "$dir" ]; then basename "$dir"; fi
    done
    for dir in "$golden_root"/* "$snapshot_root"/*; do
      if [ -e "$dir" ]; then echo "odoo-$(basename "$dir")"; fi
    done
  } | sed -n 's/^odoo-//p' | sort -u | while read -r name; do
    configured "$name" || echo "$name"
  done
}

yes=false
selected=()
while [ $# -gt 0 ]; do
  case "$1" in
    --yes | -y) yes=true ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option $1" ;;
    *) selected+=("$1") ;;
  esac
  shift
done

need_root
sql -c "SELECT 1" >/dev/null || die "PostgreSQL is not reachable"

if [ ${#selected[@]} -eq 0 ]; then
  found=$(leftovers)
  if [ -z "$found" ]; then
    echo "Nothing left behind by removed Odoo instances."
  else
    echo "Left behind by removed instances (odoo-purge NAME deletes it):"
    echo "$found"
  fi
  exit 0
fi

for name in "${selected[@]}"; do
  [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || die "'$name' is not an instance name"
  if configured "$name"; then
    die "'$name' is still configured; remove it from hostSpec.services.odoo.instances and deploy first, or use odoo-reset"
  fi
done

confirm "This deletes the database, reset copy, snapshots, role and state of: ${selected[*]}"

for name in "${selected[@]}"; do
  unit="odoo-$name"
  echo "==> $name: dropping its databases and role $unit"
  sql -c "SELECT datname FROM pg_database WHERE datname = '$unit' OR datname LIKE '$unit@%'" |
    while read -r db; do drop_db "$db"; done
  sql -c "DROP ROLE IF EXISTS \"$unit\""
  echo "==> $name: deleting its state, reset copy and snapshots"
  rm -rf "/var/lib/private/$unit" "/var/lib/$unit" "${golden_root:?}/$name" "${snapshot_root:?}/$name"
done
