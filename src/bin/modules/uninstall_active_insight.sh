#!/usr/bin/env bash
#--------------------------------------------------------------------
# Uninstall Active Insight package if it's installed
#--------------------------------------------------------------------

scriptver="v1.0.0-toolbox"
scriptname=uninstall_active_insight

# Check script is running on a Synology NAS
if ! uname -a | grep -i synology >/dev/null; then
    echo "This script is NOT running on a Synology NAS!"
    echo "Copy the script to a folder on the Synology and run it from there."
    exit 1
fi

dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ "$dsm" -lt "7" ]]; then
    # Only DSM 7 includes Active Insight
    echo "Active Insight is not installed"
    exit
fi

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "This script must be run as sudo or root!"
    exit 1
fi

# Check and show status only
if [[ "$1" == "check" ]]; then
    if /usr/syno/bin/synopkg status ActiveInsight | grep -q 'No such package'; then
        echo "Active Insight is not installed"
    else
        echo "Active Insight is installed"
    fi    
    exit
fi

# Check if Active Insight is installed
if /usr/syno/bin/synopkg status ActiveInsight | grep -q 'No such package'; then
    echo "Active Insight is not installed"
    exit
else
    installed="yes"
fi

# Uninstall Active Insight
if [[ "$installed" == "yes" ]]; then
    /usr/syno/bin/synopkg uninstall ActiveInsight >/dev/null
fi

# Check Active Insight is now uninstalled
if /usr/syno/bin/synopkg status ActiveInsight | grep -q 'No such package'; then
    echo "Active Insight has been uninstalled"
else
    echo "Failed to uninstall Active Insight!"
    exit 1
fi

