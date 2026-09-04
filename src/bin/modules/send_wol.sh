#!/usr/bin/env bash
#----------------------------------------------------------
# Send WOL Magic packet to specified MAC address
#----------------------------------------------------------
# SynoTools module: Sends WOL magic packet via synonet,
# targeting only ethX interfaces that report a link speed.
# Run as root via SynoTools suid helper
#----------------------------------------------------------

scriptver="v1.0.0-toolbox"
scriptname=send_wol

# Check script is running on a Synology NAS
if ! uname -a | grep -i synology >/dev/null; then
    echo "This script is NOT running on a Synology NAS!"
    echo "Copy the script to a folder on the Synology and run it from there."
    exit 1
fi

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "This script must be run as sudo or root!"
    exit 1
fi

MAC_RAW="$1"

usage() {
    echo "Usage: $0 xx:xx:xx:xx:xx:xx  (or xx-xx-xx-xx-xx-xx)" >&2
    exit 1
}

[ -n "$MAC_RAW" ] || usage

# Reject mixed separators (e.g. 00:11:32:da-9a-6d)
if echo "$MAC_RAW" | grep -q ':' && echo "$MAC_RAW" | grep -q '-'; then
    echo "Error: invalid MAC address format: $MAC_RAW" >&2
    exit 1
fi

# Normalize dashes to colons
MAC=$(echo "$MAC_RAW" | tr '-' ':')

echo "$MAC" | grep -qE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' || {
    echo "Error: invalid MAC address format: $MAC_RAW" >&2
    exit 1
}

eth_to_lan(){ 
    local num eth
    eth="$1"
    num="${eth#eth}"
    lan="LAN $((num +1))"
}

send_wake() {
    iface="$1"
    synonet --wake "$MAC" "$iface"
    return $?
}

readarray -t ethports <<< "$(ls /sys/class/net/ | grep '^eth')"

if [ "${#ethports[@]}" -eq 0 ]; then
    echo "Error: no ethX interfaces found" >&2
    exit 1
fi

overall_rc=1
sent_any=0

for p in "${ethports[@]}"; do
    eth_to_lan "$p"
    speed="$(ethtool "$p" | grep 'Speed:' | sed 's/^[[:space:]]*Speed:[[:space:]]*//')"
    if [[ "${speed,,}" =~ "unknown" ]]; then
        continue
    fi
    sent_any=1
    send_wake "$p" && overall_rc=0
done

if [ "$sent_any" -eq 0 ]; then
    echo "Error: no connected interfaces to send on" >&2
    exit 1
fi

if [ "$overall_rc" -eq 0 ]; then
    echo "Sent WOL to $MAC_RAW"
else
    echo "Failed to send WOL to $MAC_RAW" >&2
fi

exit $overall_rc

