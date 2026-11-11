# shellcheck shell=bash
# Shared by steam-copy-game and steam-shader-sync (gaming.nix). Run as
# root, inside a systemd sandbox that can only write below /home and
# the game libraries (gaming.nix). Every user keeps a Steam library and
# caches of their own; these only make reflink copies (btrfs: instant,
# no extra space) that the receiving user then owns, so Steam always
# sees files it fully owns.
#
# Root only reads the source and builds each copy in a fresh folder
# next to its target. Everything that replaces or removes a file in the
# receiving user's folders runs as that user (as_user), so a folder the
# user swaps for a link between a check and a write can never make root
# delete or overwrite what the user could not.
#
# STEAM_LIBRARY_ROOT (set by gaming.nix): game libraries live in
# $STEAM_LIBRARY_ROOT/<user>. Libraries anywhere else in a user's
# libraryfolders.vdf (a file the user can edit) are ignored.

log() { printf '%s\n' "$*"; }
die() {
  printf 'steam-sharing: %s\n' "$*" >&2
  exit 1
}

steam_running() { pgrep -u "$1" -x steam >/dev/null; }

# steam-config-nix's patcher (steam-config.nix) rewrites config.vdf right
# after Steam exits; writing it at the same time would drop one change.
patcher_busy() {
  case $(systemctl show -P ActiveState "steam-config-patcher@$1.service" 2>/dev/null) in
  active | activating | reloading | deactivating) return 0 ;;
  *) return 1 ;;
  esac
}

# Run a command as user $1, with their groups and no privileges.
as_user() {
  local user=$1
  shift
  setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups --no-new-privs -- "$@"
}

# The user's Steam folder: the first of Steam's own candidates.
steam_root() {
  local home dir
  home=$(getent passwd "$1" | cut -d: -f6)
  for dir in "$home/.steam/root" "$home/.steam/steam" "$home/.local/share/Steam"; do
    if [ -d "$dir" ]; then
      readlink -f -- "$dir"
      return 0
    fi
  done
  return 1
}

# Library folders of a user's Steam, one per line, the Steam folder
# first; of the libraries Steam lists, only the user's own game library.
libraries() {
  local root own
  root=$(steam_root "$1") || return 0
  printf '%s\n' "$root"
  own="${STEAM_LIBRARY_ROOT:?}/$1"
  if [ -f "$root/config/libraryfolders.vdf" ] &&
    grep -oP '^\s*"path"\s+"\K[^"]+' "$root/config/libraryfolders.vdf" | grep -qxF "$own" &&
    [ "$own" != "$root" ]; then
    printf '%s\n' "$own"
  fi
}

# The filesystem a path is on, without the btrfs subvolume: reflinks
# work across subvolumes of one filesystem.
device() { findmnt -no SOURCE -T "$1" | sed 's/\[.*//'; }

# A folder the receiving user may get copies in: a real folder they own.
owned_dir() {
  [ -d "$2" ] && [ ! -L "$2" ] && [ "$(stat -c %U -- "$2")" = "$1" ]
}

# A value from an appmanifest_<appid>.acf.
acf_value() { grep -oP '^\s*"'"$2"'"\s+"\K[^"]+' "$1"; }

# A game's folder name under steamapps/common: one plain name, never a
# path (the manifest is the source user's file).
valid_installdir() {
  [ -n "$1" ] && [ "$1" != . ] && [ "$1" != .. ] && [[ $1 != */* ]]
}

# Copy $2 (a folder) to $3 for user $1: root builds the copy in a fresh
# folder next to $3 and hands it to the user, who replaces $3 with it.
place_copy() {
  local user=$1 src=$2 dest=$3 tmp
  tmp=$(mktemp -d "$(dirname -- "$dest")/.steam-sharing.XXXXXX")
  cp -a --reflink=always -- "$src" "$tmp/copy"
  chown -R --no-dereference "$user:$(id -gn "$user")" "$tmp"
  as_user "$user" rm -rf -- "$dest"
  as_user "$user" mv -T -- "$tmp/copy" "$dest"
  as_user "$user" rmdir -- "$tmp"
}

# Steam's record of a game's shader cache (config.vdf) follows a copy of
# the cache from user $2 to user $1 (_steam-shader-record.py says why).
# Only into a Steam that has run (config.vdf exists) and only while it
# is closed: Steam rewrites config.vdf when it exits. The receiver's
# previous config.vdf stays as config.vdf.steam-sharing.bak.
copy_shader_record() {
  local to=$1 from=$2 appid=$3 src dir dst tmp mode
  src=$(steam_root "$from") && dir=$(steam_root "$to") || return 0
  src="$src/config/config.vdf"
  dir="$dir/config"
  dst="$dir/config.vdf"
  [ -f "$src" ] && [ ! -L "$src" ] && [ -f "$dst" ] && [ ! -L "$dst" ] || return 0
  owned_dir "$to" "$dir" && [ "$(stat -c %U -- "$dst")" = "$to" ] || {
    log "$dir is not $to's: Steam's record of shader cache $appid not copied"
    return 0
  }
  if patcher_busy "$to"; then
    log "steam-config-patcher@$to is writing config.vdf: Steam's record of shader cache $appid not copied"
    return 0
  fi
  mode=$(stat -c %a -- "$dst")
  tmp=$(mktemp "$dir/.steam-sharing.XXXXXX")
  steam-shader-record "$src" "$dst" "$appid" >"$tmp" || {
    rm -f -- "$tmp"
    log "could not copy Steam's record of shader cache $appid to $to"
    return 0
  }
  chown --no-dereference "$to:$(id -gn "$to")" "$tmp"
  chmod "$mode" "$tmp"
  as_user "$to" cp -p -- "$dst" "$dir/config.vdf.steam-sharing.bak"
  as_user "$to" mv -T -- "$tmp" "$dst"
  log "copied Steam's record of shader cache $appid; $to's Steam does not process it again"
}

# A file from root's side ($2) becomes user $1's file $3 (mode 0644),
# unless $3 exists.
place_file() {
  local user=$1 src=$2 dest=$3 tmp
  tmp=$(mktemp "$(dirname -- "$dest")/.steam-sharing.XXXXXX")
  cp -- "$src" "$tmp"
  chown --no-dereference "$user:$(id -gn "$user")" "$tmp"
  chmod 0644 "$tmp"
  as_user "$user" mv -n -T -- "$tmp" "$dest"
  as_user "$user" rm -f -- "$tmp"
}

# steam-copy-game --from <user> --to <user> [--force] <appid>
copy_game() {
  local from="" to="" force=0 appid=""
  while [ $# -gt 0 ]; do
    case $1 in
    --from) from=$2 && shift 2 ;;
    --to) to=$2 && shift 2 ;;
    --force) force=1 && shift ;;
    -h | --help)
      log "usage: steam-copy-game --from <user> --to <user> [--force] <appid>"
      log "Copies a game, its shader cache and its install record from one"
      log "user's Steam library to another's (same btrfs filesystem)."
      return 0
      ;;
    *) appid=$1 && shift ;;
    esac
  done
  [ -n "$from" ] && [ -n "$to" ] && [[ $appid =~ ^[0-9]+$ ]] ||
    die "usage: steam-copy-game --from <user> --to <user> [--force] <appid>"
  [ "$(id -u)" = 0 ] || die "run as root (sudo)"
  steam_running "$to" && die "$to's Steam is running: quit it first"
  patcher_busy "$to" && die "steam-config-patcher@$to is applying Steam settings: try again in a minute"

  local lib src="" manifest installdir
  while IFS= read -r lib; do
    if [ -f "$lib/steamapps/appmanifest_$appid.acf" ]; then
      src=$lib
      break
    fi
  done < <(libraries "$from")
  [ -n "$src" ] || die "$from has no installed game $appid"
  manifest="$src/steamapps/appmanifest_$appid.acf"
  installdir=$(acf_value "$manifest" installdir) ||
    die "$manifest has no installdir"
  valid_installdir "$installdir" ||
    die "$manifest: installdir \"$installdir\" is not a plain folder name"
  [ -d "$src/steamapps/common/$installdir" ] && [ ! -L "$src/steamapps/common/$installdir" ] ||
    die "$src/steamapps/common/$installdir is missing"

  # Where the copy goes: the library that already has the receiver's
  # install record of the game (one record per game, or Steam sees it
  # twice); else the receiver's game library, before the Steam folder
  # in their home. Always on the source's filesystem (reflink).
  local -a records=() added=() home=()
  local first=1
  while IFS= read -r lib; do
    if [ -f "$lib/steamapps/appmanifest_$appid.acf" ]; then
      records+=("$lib")
    elif owned_dir "$to" "$lib/steamapps" && [ "$(device "$lib")" = "$(device "$src")" ]; then
      if [ $first = 1 ]; then home+=("$lib"); else added+=("$lib"); fi
    fi
    first=0
  done < <(libraries "$to")
  local dest=""
  if [ ${#records[@]} -gt 1 ]; then
    die "$to has install records of $appid in several libraries (${records[*]}): remove all but one"
  elif [ ${#records[@]} = 1 ]; then
    dest=${records[0]}
    owned_dir "$to" "$dest/steamapps" && [ "$(device "$dest")" = "$(device "$src")" ] ||
      die "$to's record of $appid is in $dest, not a library $to owns on the filesystem of $src"
  elif [ ${#added[@]} -gt 0 ]; then
    dest=${added[0]}
  elif [ ${#home[@]} -gt 0 ]; then
    dest=${home[0]}
  fi
  [ -n "$dest" ] || die "$to has no Steam library on the same filesystem as $src (has $to run Steam?)"

  local d
  for d in common shadercache; do
    if [ ! -e "$dest/steamapps/$d" ] && [ ! -L "$dest/steamapps/$d" ]; then
      as_user "$to" mkdir -- "$dest/steamapps/$d"
    fi
    owned_dir "$to" "$dest/steamapps/$d" ||
      die "$dest/steamapps/$d is not a folder $to owns (a link?)"
  done

  local game="$dest/steamapps/common/$installdir"
  if [ -e "$game" ] || [ -L "$game" ]; then
    [ $force = 1 ] || die "$game exists: --force replaces it"
  fi
  place_copy "$to" "$src/steamapps/common/$installdir" "$game"
  log "copied $installdir to $game"

  if [ -d "$src/steamapps/shadercache/$appid" ] && [ ! -L "$src/steamapps/shadercache/$appid" ]; then
    place_copy "$to" "$src/steamapps/shadercache/$appid" "$dest/steamapps/shadercache/$appid"
    log "copied shader cache $appid"
    copy_shader_record "$to" "$from" "$appid"
  fi

  local record="$dest/steamapps/appmanifest_$appid.acf"
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    place_file "$to" "$manifest" "$record"
    log "copied install record; $to's Steam shows $installdir as installed"
  fi
}

# steam-shader-sync <user>...: for every game, the biggest shader cache
# any of the users has goes to the others who have the same build of the
# game installed (buildid in its install record) and a smaller cache. A
# cache from another build of the game is never shared: after an update
# it would replace a current cache with an outdated one. Users whose
# Steam runs, or whose Steam settings are being applied, are left out.
sync_shaders() {
  local -A size=() path=() owner=()
  local -a users=()
  local user lib cache appid build key bytes
  for user in "$@"; do
    if steam_running "$user"; then
      log "$user's Steam is running: skipped"
      continue
    fi
    if patcher_busy "$user"; then
      log "steam-config-patcher@$user is running: skipped"
      continue
    fi
    users+=("$user")
    while IFS= read -r lib; do
      [ -d "$lib/steamapps/shadercache" ] && [ ! -L "$lib/steamapps/shadercache" ] || continue
      for cache in "$lib"/steamapps/shadercache/*; do
        [ -d "$cache" ] && [ ! -L "$cache" ] || continue
        appid=$(basename -- "$cache")
        [[ $appid =~ ^[0-9]+$ ]] || continue
        build=$(acf_value "$lib/steamapps/appmanifest_$appid.acf" buildid 2>/dev/null) || continue
        key="$appid:$build"
        bytes=$(du -sb -- "$cache" | cut -f1)
        if [ "$bytes" -gt "${size[$key]:-0}" ]; then
          size[$key]=$bytes
          path[$key]=$cache
          owner[$key]=$user
        fi
      done
    done < <(libraries "$user")
  done

  for key in "${!size[@]}"; do
    appid=${key%%:*}
    build=${key#*:}
    for user in "${users[@]}"; do
      [ "$user" != "${owner[$key]}" ] || continue
      while IFS= read -r lib; do
        [ -f "$lib/steamapps/appmanifest_$appid.acf" ] || continue
        [ "$(acf_value "$lib/steamapps/appmanifest_$appid.acf" buildid 2>/dev/null)" = "$build" ] || break
        owned_dir "$user" "$lib/steamapps" || break
        if [ ! -e "$lib/steamapps/shadercache" ] && [ ! -L "$lib/steamapps/shadercache" ]; then
          as_user "$user" mkdir -- "$lib/steamapps/shadercache"
        fi
        owned_dir "$user" "$lib/steamapps/shadercache" || break
        [ "$(device "$lib")" = "$(device "${path[$key]}")" ] || break
        cache="$lib/steamapps/shadercache/$appid"
        if [ -d "$cache" ] && [ ! -L "$cache" ] &&
          [ "$(du -sb -- "$cache" | cut -f1)" -ge "${size[$key]}" ]; then
          break
        fi
        place_copy "$user" "${path[$key]}" "$cache"
        log "shader cache $appid (build $build): ${owner[$key]}'s copy to $user"
        copy_shader_record "$user" "${owner[$key]}" "$appid"
        break
      done < <(libraries "$user")
    done
  done
}
