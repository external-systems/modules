# shellcheck shell=bash disable=SC2034,SC2154
# A fragment: hostSpec.services.odoo (odoo.nix, mkScript) sets prog, instances,
# golden_root and snapshot_root and puts lib.sh first; the built script is
# linted whole again by writeShellApplication.
usage() {
  cat <<'EOF'
Usage: odoo-reset --list
       odoo-reset [--yes] [--clean] NAME...
       odoo-reset [--yes] [--clean] --all

Resets Odoo instances to how they were when first created: every record,
file and setting made since is gone, demo data and apps are back as the
instance is configured, and the provisioned admin password applies.

A reset restores the instance's reset copy (made automatically when its
database was first created): seconds. Without a valid copy (none yet, or
the package, addons, demo data, apps or language changed since), or with
--clean, the database is created from scratch (minutes) and a new copy
is made. Snapshots (odoo-snapshot) are kept. Runs as root.

  --list   show the configured instances
  --all    reset every configured instance
  --clean  ignore the reset copy and create the database from scratch
  --yes    do not ask for confirmation (needed without a terminal)
EOF
}

list() {
  if [ "$(jq length "$instances")" -eq 0 ]; then
    echo "No Odoo instances configured."
    return
  fi
  printf '%-16s %-40s %-9s %-10s %-11s %s\n' NAME URL DATA STATE RESET-COPY EXPOSED
  jq -r '.[] | [.name, .url, (if .demoData then "demo" else "no-demo" end), .unit,
      ([if .lan then "lan" else empty end, (.publicUrl // empty)] | if length == 0 then "local only" else join(" ") end)] | @tsv' "$instances" |
    while IFS=$'\t' read -r name url data unit exposed; do
      state=$(systemctl is-active "$unit.service" || true)
      copy=none
      if [ -f "$golden_root/$name/key" ]; then
        if [ "$(cat "$golden_root/$name/key")" = "$(field "$name" goldenKey)" ]; then copy=ready; else copy=stale; fi
      fi
      printf '%-16s %-40s %-9s %-10s %-11s %s\n' "$name" "$url" "$data" "$state" "$copy" "$exposed"
    done
}

all=false
yes=false
clean=false
selected=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) list; exit 0 ;;
    --all) all=true ;;
    --clean) clean=true ;;
    --yes | -y) yes=true ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option $1" ;;
    *) selected+=("$1") ;;
  esac
  shift
done

if $all; then
  [ ${#selected[@]} -eq 0 ] || die "--all takes no names"
  mapfile -t selected < <(instance_names)
  if [ ${#selected[@]} -eq 0 ]; then
    echo "No Odoo instances configured."
    exit 0
  fi
fi
if [ ${#selected[@]} -eq 0 ]; then
  usage >&2
  exit 1
fi
for name in "${selected[@]}"; do
  configured "$name" || die "no instance named '$name' (odoo-reset --list shows them)"
done
need_root
confirm "This deletes every record and file of: ${selected[*]}"

for name in "${selected[@]}"; do
  unit=$(field "$name" unit)
  state=$(field "$name" stateDir)
  url=$(field "$name" url)
  $clean && drop_golden "$name"

  echo "==> $name: stopping $unit"
  systemctl stop "$unit.service"
  drop_db "$unit"
  if golden_valid "$name"; then
    echo "==> $name: restoring the reset copy"
    copy_db "$unit@golden" "$unit" "$unit"
    restore_data "$name" "$golden_root/$name/data.tar"
    echo "==> $name: starting"
  else
    echo "==> $name: no valid reset copy; creating the database from scratch (minutes)"
    drop_golden "$name"
    sql -c "CREATE DATABASE \"$unit\" OWNER \"$unit\""
    if [ -d "$state" ]; then
      find "$state" -mindepth 1 -delete
    fi
  fi
  start_and_wait "$name"
  echo "==> $name: fresh at $url"
done
