"""Register the shared Steam libraries with the running user's Steam.

Run as the user, from steam-library-register@<user>.service (gaming.nix).
Each argument is a library root; the user's library is <root>/users/<user>.

What Steam writes when a library is added and made the default (Storage
settings, observed with Steam 2026-11):

- config/libraryfolders.vdf, and an identical copy in steamapps/: one
  numbered entry per library (path, label, contentid, ...).
- <library>/libraryfolder.vdf: the same contentid and label.
- userdata/<account>/config/localconfig.vdf: LastInstallFolderIndex, the
  number of the default library, per Steam account.

Steam holds these files in memory and rewrites them when it exits, so they
are written only while Steam is closed: the script waits for it to exit,
and for steam-config-patcher@<user> (steam-config-nix), which edits
localconfig.vdf after Steam exits too. A user without a Steam install, or
whose Steam has not written libraryfolders.vdf yet, is skipped.
"""

import argparse
import os
import pwd
import random
import re
import subprocess
import sys
import time
from pathlib import Path

import psutil
import vdf

POLL_SECONDS = 2
INDEX_KEY = "LastInstallFolderIndex"
INDEX_LINE = re.compile(r'^\t"' + INDEX_KEY + r'"\t\t"[^"]*"$', re.MULTILINE)


def log(message):
    print(message, flush=True)


def find_steam_dir():
    home = Path.home()
    for candidate in (
        home / ".steam" / "root",
        home / ".steam" / "steam",
        home / ".local" / "share" / "Steam",
    ):
        if candidate.is_dir():
            return candidate.resolve()
    return None


def steam_running():
    uid = os.getuid()
    for proc in psutil.process_iter(["name"]):
        try:
            if proc.info["name"] == "steam" and proc.uids().real == uid:
                return True
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return False


def patcher_running(user):
    unit = f"steam-config-patcher@{user}.service"
    result = subprocess.run(
        ["systemctl", "is-active", "--quiet", unit], check=False
    )
    return result.returncode == 0


def wait_until_idle(user):
    announced = False
    while steam_running() or patcher_running(user):
        if not announced:
            log("Steam (or its config patcher) is running: waiting")
            announced = True
        time.sleep(POLL_SECONDS)
    if announced:
        # Steam writes its files on the way out.
        time.sleep(POLL_SECONDS)


def dumps(data, depth=0):
    """VDF text the way Steam writes it: tabs, two between key and value."""
    indent = "\t" * depth
    out = []
    for key, value in data.items():
        if isinstance(value, dict):
            out.append(f'{indent}"{key}"\n{indent}{{\n')
            out.append(dumps(value, depth + 1))
            out.append(f"{indent}}}\n")
        else:
            out.append(f'{indent}"{key}"\t\t"{value}"\n')
    return "".join(out)


def write_atomic(path, text):
    tmp = path.with_name(path.name + ".steam-library-register")
    tmp.write_text(text, encoding="utf-8")
    if path.exists():
        os.chmod(tmp, path.stat().st_mode & 0o7777)
    os.replace(tmp, path)


def library_contentid(library):
    marker = library / "libraryfolder.vdf"
    if marker.is_file():
        data = vdf.loads(marker.read_text(encoding="utf-8"))
        contentid = data.get("libraryfolder", {}).get("contentid")
        if contentid:
            return contentid
    contentid = str(random.getrandbits(63))
    entry = {"contentid": contentid, "label": ""}
    write_atomic(marker, dumps({"libraryfolder": entry}))
    return contentid


def register(steam_dir, libraries):
    """Add missing libraries; return each library's index in Steam."""
    config = steam_dir / "config" / "libraryfolders.vdf"
    data = vdf.loads(config.read_text(encoding="utf-8"))
    folders = data.setdefault("libraryfolders", {})
    known = {
        os.path.realpath(entry.get("path", "")): index
        for index, entry in folders.items()
        if isinstance(entry, dict)
    }
    indexes = {}
    changed = False
    for library in libraries:
        index = known.get(os.path.realpath(library))
        if index is None:
            numbers = [int(k) for k in folders if k.isdigit()]
            index = str(max(numbers, default=-1) + 1)
            folders[index] = {
                "path": str(library),
                "label": "",
                "contentid": library_contentid(library),
                "totalsize": "0",
                "update_clean_bytes_tally": "0",
                "time_last_update_verified": "0",
                "apps": {},
            }
            changed = True
            log(f"registered {library} as library {index}")
        indexes[library] = index
    if changed:
        text = dumps(data)
        write_atomic(config, text)
        copy = steam_dir / "steamapps" / "libraryfolders.vdf"
        if copy.parent.is_dir():
            write_atomic(copy, text)
    return indexes


def set_default(steam_dir, index):
    userdata = steam_dir / "userdata"
    if not userdata.is_dir():
        return
    line = f'\t"{INDEX_KEY}"\t\t"{index}"'
    for account in sorted(userdata.iterdir()):
        localconfig = account / "config" / "localconfig.vdf"
        if account.name == "0" or not localconfig.is_file():
            continue
        text = localconfig.read_text(encoding="utf-8")
        # A line edit, not a VDF round trip: localconfig.vdf is large and
        # full of escaped JSON that Steam owns.
        if INDEX_LINE.search(text):
            new = INDEX_LINE.sub(lambda _: line, text, count=1)
        else:
            end = text.rstrip().rfind("\n}")
            if end < 0:
                log(f"{localconfig}: no closing brace, left alone")
                continue
            new = text[:end] + "\n" + line + text[end:]
        if new != text:
            write_atomic(localconfig, new)
            log(f"default library {index} for Steam account {account.name}")


def main():
    parser = argparse.ArgumentParser(prog="steam-library-register")
    parser.add_argument("--make-default", action="store_true")
    parser.add_argument("roots", nargs="+", type=Path)
    args = parser.parse_args()

    user = pwd.getpwuid(os.getuid()).pw_name
    steam_dir = find_steam_dir()
    if steam_dir is None:
        log(f"no Steam install for {user} yet: nothing to register")
        return 0

    libraries = []
    for root in args.roots:
        library = root / "users" / user
        if library.is_dir():
            libraries.append(library)
        else:
            log(f"{library} missing (disk not mounted?): skipped")
    if not libraries:
        return 0

    wait_until_idle(user)

    if not (steam_dir / "config" / "libraryfolders.vdf").is_file():
        log("Steam has not written libraryfolders.vdf yet: skipped")
        return 0

    indexes = register(steam_dir, libraries)
    if args.make_default:
        set_default(steam_dir, indexes[libraries[0]])
    return 0


if __name__ == "__main__":
    sys.exit(main())
