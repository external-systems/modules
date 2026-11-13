# shellcheck shell=bash
# crash-report and crash-sampler (crash-diagnostics.nix). Both only read:
# the journal, /proc, /sys and the pstore archive.

die() {
  printf 'crash-report: %s\n' "$*" >&2
  exit 1
}

# No matching entries is an answer here, not an error.
j() { journalctl --no-pager -q "$@" || true; }

# logind logs this message id (SD_MESSAGE_SHUTDOWN) when a shutdown or
# reboot is requested; systemd (PID 1) then reaches its shutdown targets.
# A boot with neither ended without one: a crash, reset or power loss.
shutdown_requested() {
  j -b "$1" MESSAGE_ID=98268866d1d54a499c4e98921d93bc40 -o cat -n 1
  j -b "$1" _PID=1 -o cat -g '^Reached target (System )?(Power-Off|Reboot|Halt|Kexec)' -n 1
}

# Kernel log classes worth counting: label|extended regex.
patterns=(
  "panic or oops|Kernel panic|Oops|BUG:|general protection fault|RIP: "
  "lockup or hung task|soft lockup|hard LOCKUP|blocked for more than|rcu_sched self-detected stall|rcu: INFO"
  "hardware error|Machine check|mce: \[|[Hh]ardware [Ee]rror|EDAC .*(CE|UE|error)"
  "out of memory|Out of memory|oom-kill|Killed process"
  "thermal|critical temperature|temperature above threshold|thermal.*shutdown|Package temperature"
  "GPU|amdgpu.*(timeout|GPU reset|hang|page fault)|GPU reset|i915.*(hang|reset)|NVRM: Xid"
  "storage|I/O error|nvme.*(timeout|reset|abort)|ata[0-9].*(failed|error)|blk_update_request"
  "filesystem|BTRFS (error|warning|critical)|EXT4-fs error|XFS.*(error|corrupt)|FILE CORRUPTED|csum failed"
  "power or ACPI|ACPI (Error|BIOS Error)|PM: .*(fail|error)"
  "watchdog|watchdog did not stop|[Ww]atchdog (timeout|expired)|Watchdog detected hard LOCKUP"
)

# report OFFSET: how boot OFFSET (-1 = the previous one) ended.
report() {
  local offset=$1 boots boot next first last next_first marker line label regex count
  boots=$(journalctl --list-boots -o json --no-pager)
  boot=$(jq -c --argjson o "$offset" '.[] | select(.index == $o)' <<<"$boots")
  [ -n "$boot" ] || die "boot $offset is not in the journal"
  next=$((offset + 1))
  first=$(jq -r '.first_entry / 1000000 | floor' <<<"$boot")
  last=$(jq -r '.last_entry / 1000000 | floor' <<<"$boot")
  next_first=$(jq -r --argjson o "$next" '.[] | select(.index == $o) | .first_entry / 1000000 | floor' <<<"$boots")

  printf '== boot %s (%s)\n' "$offset" "$(jq -r .boot_id <<<"$boot")"
  printf 'started   %s\n' "$(date -d "@$first" '+%F %T %Z')"
  printf 'last log  %s\n' "$(date -d "@$last" '+%F %T %Z')"
  if [ -n "$next_first" ]; then
    printf 'next boot %s (%s s later)\n' "$(date -d "@$next_first" '+%F %T %Z')" "$((next_first - last))"
  fi

  marker=$(shutdown_requested "$offset" | head -n 1)
  if [ -n "$marker" ]; then
    printf 'verdict   clean: %s\n' "$marker"
  else
    printf 'verdict   UNCLEAN: the journal stops without a requested shutdown (crash, reset, power loss or a forced reboot)\n'
  fi

  if [ -n "$next_first" ]; then
    # AMD firmware records why the machine last reset; the next boot's
    # kernel prints it (x86/amd: Previous system reset reason ...).
    line=$(j -b "$next" -k -o cat -g 'reset reason' | head -n 1)
    printf 'reset     %s\n' "${line:-not reported (only AMD CPUs report a reset reason)}"
  fi

  printf '\n== kernel messages by class (boot %s)\n' "$offset"
  local klog
  klog=$(j -b "$offset" -k -o short-iso)
  for line in "${patterns[@]}"; do
    label=${line%%|*}
    regex=${line#*|}
    count=$(grep -cE -- "$regex" <<<"$klog" || true)
    [ "$count" -eq 0 ] && continue
    printf '%-20s %5d  last: %s\n' "$label" "$count" "$(grep -E -- "$regex" <<<"$klog" | tail -n 1 | cut -c1-160)"
  done
  count=$(j -b "$offset" -o cat -t systemd-oomd -g 'Killed' | wc -l)
  [ "$count" -gt 0 ] && printf '%-20s %5d\n' "systemd-oomd kills" "$count"

  printf '\n== last samples (crash-sampler)\n'
  j -b "$offset" -t crash-sampler -o short-iso -n 6 || true

  printf '\n== last 30 journal lines\n'
  j -b "$offset" -o short-iso -n 30 | cut -c1-220

  # systemd-pstore moves what the kernel left in pstore (the kernel log
  # tail of a panic, or of every reboot with printk.always_kmsg_dump)
  # into /var/lib/systemd/pstore at the next boot.
  printf '\n== pstore (kernel log tail saved by the firmware)\n'
  local found=
  if [ -n "$next_first" ] && [ -d /var/lib/systemd/pstore ]; then
    while IFS= read -r -d '' f; do
      found=1
      printf -- '-- %s\n' "$f"
      tail -n 60 "$f"
    done < <(find /var/lib/systemd/pstore -type f -newermt "@$((next_first - 60))" -print0)
  fi
  [ -n "$found" ] || printf 'nothing archived for this boot\n'
}

# At boot: write the previous boot's report to the log directory, say
# in the journal whether it ended cleanly, and keep the newest reports.
boot_report() {
  local dir=$1 keep=$2 id file verdict
  journalctl --list-boots -o json --no-pager | jq -e 'any(.[]; .index == -1)' >/dev/null || exit 0
  id=$(journalctl --list-boots -o json --no-pager | jq -r '.[] | select(.index == -1) | .boot_id')
  install -d -m 0750 "$dir"
  file="$dir/$(date '+%Y%m%d-%H%M%S')-$id.txt"
  report -1 >"$file"
  verdict=$(grep -m1 '^verdict' "$file" || true)
  if [[ $verdict == *UNCLEAN* ]]; then
    printf '<4>previous boot ended uncleanly; report: %s; %s\n' "$file" "$(grep -m1 '^reset' "$file" || true)"
  else
    printf 'previous boot ended cleanly; report: %s\n' "$file"
  fi
  find "$dir" -maxdepth 1 -name '*.txt' -printf '%T@ %p\n' | sort -rn | tail -n "+$((keep + 1))" | cut -d' ' -f2- | xargs -r rm -f --
}

# One line of machine health for the journal, so the minutes before a
# crash show load, pressure, memory and temperature.
sample() {
  local load psi="" r avail swap_total swap_free t max=0 max_name="" top
  read -r load _ </proc/loadavg
  for r in cpu memory io; do
    [ -r "/proc/pressure/$r" ] || continue
    psi+=" $r=$(awk '/^some/ { sub("avg10=", "", $2); print $2 }' "/proc/pressure/$r")"
  done
  avail=$(awk '/^MemAvailable/ { printf "%.1fG", $2 / 1048576 }' /proc/meminfo)
  swap_total=$(awk '/^SwapTotal/ { print $2 }' /proc/meminfo)
  swap_free=$(awk '/^SwapFree/ { print $2 }' /proc/meminfo)
  for t in /sys/class/hwmon/hwmon*/temp*_input; do
    [ -r "$t" ] || continue
    r=$(cat "$t" 2>/dev/null) || continue
    if [ "$r" -gt "$max" ]; then
      max=$r
      max_name=$(cat "${t%/*}/name" 2>/dev/null || echo "?")
    fi
  done
  top=$(ps -eo rss=,comm= --sort=-rss | awk 'NR == 1 { printf "%s:%.1fG", $2, $1 / 1048576 }')
  printf 'load=%s psi(some avg10):%s mem_avail=%s swap_used=%.1fG temp_max=%dC(%s) top_rss=%s\n' \
    "$load" "${psi:- n/a}" "$avail" "$(awk -v t="$swap_total" -v f="$swap_free" 'BEGIN { print (t - f) / 1048576 }')" \
    "$((max / 1000))" "${max_name:-none}" "$top"
}

usage() {
  cat <<'EOF'
usage: crash-report [OFFSET]   how boot OFFSET ended (default -1, the previous boot)
       crash-report --list     saved boot reports, newest first
EOF
}
