#!/usr/bin/env bash
#--------------------------------------------------------------------
# Show LAN ports' MAC address
#--------------------------------------------------------------------

scriptver="v1.0.0-toolbox"
scriptname=network_mac

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

eth_to_lan(){ 
    local num eth
    eth="$1"
    num="${eth#eth}"
    lan="LAN $((num +1))"
}

readarray -t ethports <<< "$(ls /sys/class/net/ | grep '^eth')"

for p in "${ethports[@]}"; do
    eth_to_lan "$p"
    mac="$(ip link show eth0 | grep 'ether' | awk '{print $2}')"
    if [[ "${speed,,}" =~ "unknown" ]]; then
        noconnect=" (not connected)"
    fi
    echo "$lan ${mac}$noconnect"
done


