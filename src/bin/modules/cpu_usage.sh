#!/bin/bash

PKG_NAME="Syno_Toolbox"
PKG_ROOT="/var/packages/${PKG_NAME}"
BIN_DIR="${PKG_ROOT}/target/bin"
UI_DIR="${PKG_ROOT}/target/ui"

if [[ "$1" == "check" ]]; then
    check=yes
fi

dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="${PKG_ROOT}/var"
else
    VAR_DIR="${PKG_ROOT}/etc"
fi
TOOLBOX_CONF="${VAR_DIR}/toolbox.conf"
TOOLBOX_LOG="${VAR_DIR}/toolbox.log"
CPU_LOG="${VAR_DIR}/cpu_usage.log"
STATFILE="${VAR_DIR}/cpu_usage_stat"
LOCKFILE="${VAR_DIR}/cpu_usage.lock"

exec 9>"$LOCKFILE"
flock -n 9 || exit 0   # Another run still in progress, skip this tick

if [[ "$1" == "seed" ]]; then
    # First invocation ever after Save - seed one 0.0 point immediately
    # instead of leaving the chart empty for the first two real ticks.
    if [ ! -f "$CPU_LOG" ]; then
        read -r _ u n s i io irq sirq steal _ < /proc/stat
        total=$((u+n+s+i+io+irq+sirq+steal))
        idle=$((i+io))
        echo "$total $idle" > "$STATFILE"
        echo "$(date '+%F %T') 0.0" >> "$CPU_LOG"
        "${BIN_DIR}/generate_cpu_chart.sh" "$(hostname):$CPU_LOG" > "${UI_DIR}/cpu_chart.html"
    fi
    exit 0
fi

read -r _ u n s i io irq sirq steal _ < /proc/stat
total=$((u+n+s+i+io+irq+sirq+steal))
idle=$((i+io))

if [ -f "$STATFILE" ]; then
    read -r prev_total prev_idle < "$STATFILE"
    dt=$((total - prev_total))
    di=$((idle - prev_idle))
    if [ "$dt" -gt 0 ]; then
        cpu_pct=$(awk -v dt="$dt" -v di="$di" 'BEGIN{printf "%.1f", 100*(dt-di)/dt}')
        echo "$(date '+%F %T') $cpu_pct" >> "$CPU_LOG"
    fi
elif [ ! -f "$CPU_LOG" ]; then
    # Safety net: first-ever real tick with no prior seed call (e.g.
    # upgrade from a version without seeding). Not the normal path.
    echo "$(date '+%F %T') 0.0" >> "$CPU_LOG"
fi

echo "$total $idle" > "$STATFILE"

# Prune entries older than 30 hours - runs every tick (not just when a
# new sample was appended above), so the file stays bounded even
# across ticks that skip appending (dt<=0) or repeated manual runs.
# Already covered by the flock held above.
#
# The log's "YYYY-MM-DD HH:MM:SS" timestamp format sorts correctly as
# plain strings (fixed-width, zero-padded, matching date '+%F %T'), so
# this is a single string comparison per line in one awk pass - no
# per-line date subprocess calls, and no reliance on gawk-specific
# date functions (mktime etc.) that may not exist in DSM's awk.
if [ -f "$CPU_LOG" ]; then
    CUTOFF=$(date -d '30 hours ago' '+%Y-%m-%d %H:%M:%S')
    awk -v cutoff="$CUTOFF" '($1" "$2) >= cutoff' "$CPU_LOG" > "${CPU_LOG}.tmp" && mv "${CPU_LOG}.tmp" "$CPU_LOG"
fi

"${BIN_DIR}/generate_cpu_chart.sh" "$(hostname):$CPU_LOG" > "${UI_DIR}/cpu_chart.html"

