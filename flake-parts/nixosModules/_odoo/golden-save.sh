# shellcheck shell=bash disable=SC2034,SC2154
# A fragment: hostSpec.services.odoo (odoo.nix, mkScript) sets prog, instances,
# golden_root and snapshot_root and puts lib.sh first; the built script is
# linted whole again by writeShellApplication.
# odoo-golden-save NAME: runs as root in odoo-NAME's pre-start, right
# after its database was created (the init leaves .golden-pending). Saves
# that fresh database and its files as the reset copy, so odoo-reset can
# restore it in seconds instead of creating it again.
yes=false
name=$1
data=$(field "$name" dataDir)
[ -e "$data/.golden-pending" ] || exit 0

unit=$(field "$name" unit)
dir="$golden_root/$name"
echo "pre-start: saving the new database as the reset copy"
mkdir -p "$dir"
chmod 700 "$golden_root" "$dir"
drop_db "$unit@golden"
# The init has stopped: nothing is connected to the database.
copy_db "$unit" "$unit@golden" postgres
freeze_db "$unit@golden"
rm -f "$data/.golden-pending"
# The admin password and base URL are applied again after a restore.
save_data "$data" "$dir/data.tar" --exclude=./.admin-password.sha256 --exclude=./.base-url
field "$name" goldenKey > "$dir/key"
