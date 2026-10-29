#!/bin/bash
#----------------------------------------------------------
# Syno_Toolbox module: pkg_recent.sh
# Lists successful package installs / upgrades from synopkg.log,
# newest first. Used by the Packages tab's [Recently Installed] and
# [Recently Upgraded] buttons (modules pkg_recent_installed and
# pkg_recent_upgraded, selected by the first argument).
#
# Always prints something and exits 0 - api.cgi's run action treats
# empty output as a failure.
#----------------------------------------------------------

LOG="/var/log/synopkg.log"

if [[ ! -r "$LOG" ]]; then
    echo "Cannot read $LOG"
    exit 0
fi

case "$1" in
    installed)
        out=$(grep -E ' install.*successfully' "$LOG" | grep -v 'result')
        none="No successful package installs found in synopkg.log"
        ;;
    upgraded)
        out=$(grep -E ' upgrade.*from.*successfully' "$LOG")
        none="No successful package upgrades found in synopkg.log"
        ;;
    *)
        echo "Usage: pkg_recent.sh installed|upgraded"
        exit 0
        ;;
esac

if [[ -z "$out" ]]; then
    echo "$none"
else
    # newest first (log is chronological)
    echo "$out" | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'
fi

exit 0
