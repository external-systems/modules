# Gaming

How the gaming modules share Steam between the users of one machine, and
keep the disk deduplicated without getting in a game's way.

## Steam libraries per user

Steam assumes it owns every file in its library (it chmods files, sets
their times, deletes and rebuilds folders), so a library several users
write breaks. With `hostSpec.system.gaming.steamSharing.enable`, each
user keeps a library of their own and sharing happens below Steam:

| Piece | What it does |
|---|---|
| `<libraryRoot>/<user>` | Each user's game library (default `/srv/steam/users/<user>`, mode 0700), made by tmpfiles. Add it once in Steam: Settings > Storage. |
| `steam-copy-game --from <user> --to <user> [--force] <appid>` | Run with sudo, with the receiver's Steam closed. Copies the game, its shader cache and its install record as reflinks: instant, no extra space, owned by the receiver. |
| `steam-shader-sync` (boot, then every 15 minutes) | For each game, the biggest shader cache of one build of the game goes to the other users who have that same build installed. Users whose Steam runs are skipped. |
| `_steam-shader-record.py` | Copies Steam's own record of a cache (`config.vdf`) with it, so the receiver's Steam does not replay every pipeline again. The receiver's previous file stays as `config.vdf.steam-sharing.bak`. |

### Safety

Both tools run as root, so they are built to stay inside the game
folders:

- **Sandbox.** They run in a systemd sandbox (`ProtectSystem=strict`)
  that can only write below `/home` and the parent of `libraryRoot`, with
  only the capabilities to read users' files, hand files over and drop to
  a user. `steam-copy-game` starts itself as a transient unit, so its
  output and exit code stay yours.
- **The user does the replacing.** Root reads the source and builds each
  copy in a fresh folder; removing or replacing anything in the
  receiver's folders runs as the receiver. A folder swapped for a link at
  the last moment can't make root delete or overwrite something.
- **Only known libraries.** A library in a user's `libraryfolders.vdf`
  other than their Steam folder and `<libraryRoot>/<user>` is ignored,
  and a game's `installdir` must be a plain folder name, never a path.
- **One writer of `config.vdf`.** A user whose `steam-config-patcher@`
  (steam-config.nix) is running is skipped.

## Deduplication with bees

`hostSpec.system.gaming.dedup` (on with steamSharing when `/` is btrfs)
turns on `hostSpec.system.btrfsDedup` for the root filesystem, so games,
Proton prefixes and caches each user downloaded on their own are stored
once. bees works on the whole filesystem and runs in every boot entry.

| Setting | Why |
|---|---|
| Idle CPU priority, `--loadavg-target` | Backs off while the machine is busy. |
| Frozen while a game runs (`dedup.pauseWhilePlaying`) | Steam starts every game under `reaper SteamLaunch AppId=…`; while one runs, `systemctl freeze` pauses bees in place, and the last game's exit thaws it. The idle I/O class alone does nothing on NVMe disks (the `none` scheduler ignores it). |
| `MemoryHigh` (`memoryHighMB`, default 3 GiB) | bees reads the whole filesystem through the page cache; the ceiling makes it reclaim its own cache instead of pushing games into swap. |
| Monthly scrub (`services.btrfs.autoScrub`) | Deduplicated data is stored once, so a bad block hits every copy; the scrub finds it while the game can be verified or downloaded again. |

## Compression

btrfs compression set as a mount option applies to the whole filesystem:
the first subvolume mounted decides it, whatever the others say. Use
`compress=zstd:1` (or `:3`) the same on every subvolume, never
`compress-force` for games (most game data is already compressed), and
set a different algorithm or level per folder with
`btrfs property set <path> compression zstd:3`; new files inherit it.
