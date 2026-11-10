# shellcheck shell=bash
# Shared by steam-copy-game and steam-shader-sync (gaming.nix). Run as
# root. Every user keeps a Steam library and caches of their own; these
# only make reflink copies (btrfs: instant, no extra space) that the
# receiving user then owns, so Steam always sees files it fully owns.
#
# A copy is built in a fresh folder next to its target, handed to the
# receiving user, then moved into place: cp -a never follows a symlink
# it copies, chown never dereferences, and the target folders must be
# real folders owned by the receiving user.

log() { printf '%s\n' "$*"; }
die() {
  printf 'steam-sharing: %s\n' "$*" >&2
  exit 1
}

steam_running() { pgrep -u "$1" -x steam >/dev/null; }

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

# Library folders of a user's Steam, one per line, the Steam folder first.
libraries() {
  local root
  root=$(steam_root "$1") || return 0
  printf '%s\n' "$root"
  if [ -f "$root/config/libraryfolders.vdf" ]; then
    grep -oP '^\s*"path"\s+"\K[^"]+' "$root/config/libraryfolders.vdf" | grep -vxF "$root" || true
  fi
}

# The filesystem a path is on, without the btrfs subvolume: reflinks
# work across subvolumes of one filesystem.
device() { findmnt -no SOURCE -T "$1" | sed 's/\[.*//'; }

# A folder the receiving user may get copies in: a real folder they own.
owned_dir() {
  [ -d "$2" ] && [ ! -L "$2" ] && [ "$(stat -c %U -- "$2")" = "$1" ]
}

# Copy $2 (a folder) to $3 for user $1: build it in a fresh folder next to
# $3, hand it to the user, then move it into place, replacing $3.
place_copy() {
  local user=$1 src=$2 dest=$3 group tmp
  group=$(id -gn "$user")
  tmp=$(mktemp -d "$(dirname -- "$dest")/.steam-sharing.XXXXXX")
  cp -a --reflink=always -- "$src" "$tmp/copy"
  chown -R --no-dereference "$user:$group" "$tmp/copy"
  rm -rf -- "$dest"
  mv -T -- "$tmp/copy" "$dest"
  rmdir -- "$tmp"
}

# Steam's record of a game's shader cache (config.vdf) follows a copy of
# the cache from user $2 to user $1 (_steam-shader-record.py says why).
# Only into a Steam that has run (config.vdf exists) and only while it
# is closed: Steam rewrites config.vdf when it exits.
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
  mode=$(stat -c %a -- "$dst")
  tmp=$(mktemp "$dir/.steam-sharing.XXXXXX")
  steam-shader-record "$src" "$dst" "$appid" >"$tmp" || {
    rm -f -- "$tmp"
    log "could not copy Steam's record of shader cache $appid to $to"
    return 0
  }
  chown --no-dereference "$to:$(id -gn "$to")" "$tmp"
  chmod "$mode" "$tmp"
  mv -T -- "$tmp" "$dst"
  log "copied Steam's record of shader cache $appid; $to's Steam does not process it again"
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

  local lib src="" manifest installdir
  while IFS= read -r lib; do
    if [ -f "$lib/steamapps/appmanifest_$appid.acf" ]; then
      src=$lib
      break
    fi
  done < <(libraries "$from")
  [ -n "$src" ] || die "$from has no installed game $appid"
  manifest="$src/steamapps/appmanifest_$appid.acf"
  installdir=$(grep -oP '^\s*"installdir"\s+"\K[^"]+' "$manifest") ||
    die "$manifest has no installdir"
  [ -d "$src/steamapps/common/$installdir" ] ||
    die "$src/steamapps/common/$installdir is missing"

  # Where the copy goes: the library that already has the receiver's
  # install record of the game (one record per game, or Steam sees it
  # twice); else a game library the receiver added, before the Steam
  # folder in their home. Always on the source's filesystem (reflink).
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
    if [ ! -e "$dest/steamapps/$d" ]; then
      install -d -o "$to" -g "$(id -gn "$to")" -- "$dest/steamapps/$d"
    fi
    owned_dir "$to" "$dest/steamapps/$d" ||
      die "$dest/steamapps/$d is not a folder $to owns (a link from the old shared library?)"
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
    local tmp
    tmp=$(mktemp "$dest/steamapps/.steam-sharing.XXXXXX")
    cp -- "$manifest" "$tmp"
    chown --no-dereference "$to:$(id -gn "$to")" "$tmp"
    chmod 0644 "$tmp"
    mv -T -- "$tmp" "$record"
    log "copied install record; $to's Steam shows $installdir as installed"
  fi
}

# steam-shader-sync <user>...: for every game, the biggest shader cache
# any of the users has goes to the others who have the game installed
# and a smaller cache. Users whose Steam runs are left out entirely.
sync_shaders() {
  local -A size=() path=() owner=()
  local -a users=()
  local user lib cache appid bytes
  for user in "$@"; do
    if steam_running "$user"; then
      log "$user's Steam is running: skipped"
      continue
    fi
    users+=("$user")
    while IFS= read -r lib; do
      [ -d "$lib/steamapps/shadercache" ] && [ ! -L "$lib/steamapps/shadercache" ] || continue
      for cache in "$lib"/steamapps/shadercache/*; do
        [ -d "$cache" ] && [ ! -L "$cache" ] || continue
        appid=$(basename -- "$cache")
        [[ $appid =~ ^[0-9]+$ ]] || continue
        bytes=$(du -sb -- "$cache" | cut -f1)
        if [ "$bytes" -gt "${size[$appid]:-0}" ]; then
          size[$appid]=$bytes
          path[$appid]=$cache
          owner[$appid]=$user
        fi
      done
    done < <(libraries "$user")
  done

  for appid in "${!size[@]}"; do
    for user in "${users[@]}"; do
      [ "$user" != "${owner[$appid]}" ] || continue
      while IFS= read -r lib; do
        [ -f "$lib/steamapps/appmanifest_$appid.acf" ] || continue
        owned_dir "$user" "$lib/steamapps" || break
        if [ ! -e "$lib/steamapps/shadercache" ] && [ ! -L "$lib/steamapps/shadercache" ]; then
          install -d -o "$user" -g "$(id -gn "$user")" -- "$lib/steamapps/shadercache"
        fi
        owned_dir "$user" "$lib/steamapps/shadercache" || break
        [ "$(device "$lib")" = "$(device "${path[$appid]}")" ] || break
        cache="$lib/steamapps/shadercache/$appid"
        if [ -d "$cache" ] && [ ! -L "$cache" ] &&
          [ "$(du -sb -- "$cache" | cut -f1)" -ge "${size[$appid]}" ]; then
          break
        fi
        place_copy "$user" "${path[$appid]}" "$cache"
        log "shader cache $appid: ${owner[$appid]}'s copy to $user"
        copy_shader_record "$user" "${owner[$appid]}" "$appid"
        break
      done < <(libraries "$user")
    done
  done
}
