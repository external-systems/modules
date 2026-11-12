# shellcheck shell=bash disable=SC2034,SC2154
# A fragment: hostSpec.services.odoo (odoo.nix, mkScript) sets prog, instances,
# golden_root and snapshot_root and puts lib.sh first; the built script is
# linted whole again by writeShellApplication.
usage() {
  cat <<'EOF'
Usage: odoo-snapshot list [NAME]
       odoo-snapshot save NAME TAG
       odoo-snapshot restore [--yes] NAME TAG
       odoo-snapshot rm [--yes] NAME TAG

Saves an instance as it is now (database and files) under a tag, and puts
it back later: "the state just before step X". The instance stops for a
few seconds while it is saved or restored. A restore keeps everything as
saved, the admin password included. Snapshots survive odoo-reset;
odoo-purge removes them with their instance. TAG: lowercase letters,
digits, ., _ and -, at most 24. Runs as root (list too).

  --yes    do not ask for confirmation (needed without a terminal)
EOF
}

yes=false
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --yes | -y) yes=true ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option $1" ;;
    *) args+=("$1") ;;
  esac
  shift
done
[ ${#args[@]} -gt 0 ] || { usage >&2; exit 1; }
action=${args[0]}
name=${args[1]:-}
tag=${args[2]:-}

need_root

check_name() {
  [ -n "$name" ] || die "$action needs an instance name"
  configured "$name" || die "no instance named '$name' (odoo-reset --list shows them)"
}
check_tag() {
  [ -n "$tag" ] || die "$action needs a tag"
  [[ "$tag" =~ ^[a-z0-9][a-z0-9._-]{0,23}$ ]] || die "'$tag' is not a tag (lowercase letters, digits, . _ -, at most 24)"
}

case "$action" in
  list)
    if [ -n "$name" ]; then
      check_name
      names=("$name")
    else
      mapfile -t names < <(instance_names)
    fi
    printf '%-16s %-26s %-20s %s\n' NAME TAG SAVED FILES
    for n in "${names[@]}"; do
      dir="$snapshot_root/$n"
      [ -d "$dir" ] || continue
      for archive in "$dir"/*.tar; do
        [ -e "$archive" ] || continue
        t=$(basename "$archive" .tar)
        saved=$(date -r "$archive" '+%Y-%m-%d %H:%M')
        size=$(du -h "$archive" | cut -f1)
        printf '%-16s %-26s %-20s %s\n' "$n" "$t" "$saved" "$size"
      done
    done
    ;;

  save)
    check_name
    check_tag
    unit=$(field "$name" unit)
    snap="$unit@snap-$tag"
    db_exists "$snap" && die "snapshot $tag of $name exists; odoo-snapshot rm $name $tag first"
    mkdir -p "$snapshot_root/$name"
    chmod 700 "$snapshot_root" "$snapshot_root/$name"
    echo "==> $name: stopping $unit"
    systemctl stop "$unit.service"
    copy_db "$unit" "$snap" postgres
    freeze_db "$snap"
    save_data "$(field "$name" dataDir)" "$snapshot_root/$name/$tag.tar"
    start_and_wait "$name"
    echo "==> $name: saved as $tag"
    ;;

  restore)
    check_name
    check_tag
    unit=$(field "$name" unit)
    snap="$unit@snap-$tag"
    archive="$snapshot_root/$name/$tag.tar"
    { db_exists "$snap" && [ -f "$archive" ]; } || die "no snapshot $tag of $name (odoo-snapshot list $name)"
    confirm "This replaces every record and file of $name with snapshot $tag"
    echo "==> $name: stopping $unit"
    systemctl stop "$unit.service"
    drop_db "$unit"
    copy_db "$snap" "$unit" "$unit"
    restore_data "$name" "$archive"
    start_and_wait "$name"
    echo "==> $name: restored $tag at $(field "$name" url)"
    ;;

  rm)
    check_name
    check_tag
    unit=$(field "$name" unit)
    archive="$snapshot_root/$name/$tag.tar"
    { db_exists "$unit@snap-$tag" || [ -f "$archive" ]; } || die "no snapshot $tag of $name"
    confirm "This deletes snapshot $tag of $name"
    drop_db "$unit@snap-$tag"
    rm -f "$archive"
    echo "==> $name: deleted snapshot $tag"
    ;;

  *)
    usage >&2
    die "unknown action $action"
    ;;
esac
