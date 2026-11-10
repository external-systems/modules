"""Carry Steam's record of a game's shader cache along with a copy of it.

steam-shader-record <from config.vdf> <to config.vdf> <appid>

Prints the receiving user's config/config.vdf with the source user's
record of the game's shader cache, for _steam-sharing.sh to put in place
(as root, while the receiver's Steam is closed).

Each Steam client keeps its own record of the shader caches it has
downloaded and processed, in config.vdf under ShaderCacheManager
(observed with Steam 2026-11):

- CommittedDepotManifests.<appid>: the cache depots Steam downloaded
  into the game's shadercache folder.
- ProcessingQueue: "<appid>;..." the games whose caches Steam still has
  to replay with fossilize_replay (Processing Vulkan shaders).
- App.<appid>.ShaderCacheSize, CompatToolBucketHashes.<tool>: the cache
  size and the compatibility tool buckets those depots came from.

A copied cache without its record makes the receiver's Steam download
the depots again and replay every pipeline in them, hours for a big
game, although the copy already holds the compiled shaders. So the
record follows the cache: the source's depots, size and buckets, and the
game queued for processing only if it was queued for the source.
"""

import sys
from pathlib import Path

import vdf

PATH = ("InstallConfigStore", "Software", "Valve", "Steam")
MANAGER = "ShaderCacheManager"


def child(node, key, create=False):
    """The value of key in node, matched without case as Steam does."""
    for name, value in node.items():
        if name.lower() == key.lower() and isinstance(value, dict):
            return value
    if not create:
        return None
    node[key] = {}
    return node[key]


def manager(config, create=False):
    node = config
    for key in (*PATH, MANAGER):
        node = child(node, key, create)
        if node is None:
            return None
    return node


def load(path):
    if not path.is_file():
        return {}
    with path.open(encoding="utf-8") as file:
        return vdf.load(file)


def queue(record):
    return [a for a in record.get("ProcessingQueue", "").split(";") if a]


def mirror(src, dst, key):
    """dst[key] = src[key], or no dst[key] when src has none."""
    if key in src:
        dst[key] = src[key]
    else:
        dst.pop(key, None)


def main():
    if len(sys.argv) != 4 or not sys.argv[3].isdigit():
        sys.exit(
            "usage: steam-shader-record"
            " <from config.vdf> <to config.vdf> <appid>"
        )
    source, target, appid = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]

    src = manager(load(source)) or {}
    config = load(target)
    dst = manager(config, create=True)

    for key in ("CommittedDepotManifests", "App"):
        mirror(child(src, key) or {}, child(dst, key, create=True), appid)
    buckets = child(dst, "CompatToolBucketHashes", create=True)
    buckets.update(child(src, "CompatToolBucketHashes") or {})

    pending = [a for a in queue(dst) if a != appid]
    if appid in queue(src):
        pending.append(appid)
    dst["ProcessingQueue"] = "".join(f"{a};" for a in pending)

    sys.stdout.write(vdf.dumps(config, pretty=True))


if __name__ == "__main__":
    main()
