#!/usr/bin/env bash
#--------------------------------------------------------------------
# Show current LAN ports' WOL status
#--------------------------------------------------------------------

scriptver="v1.0.0-toolbox"
scriptname=wol_status

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
    wol="$(ethtool "$p" | grep -i Wake-on: | grep -v Supports | cut -d" " -f2)"
    wolsupport="$(ethtool "$p" | grep -i 'Supports Wake-on:' | cut -d" " -f3)"
    #speed="$(ethtool "$p" | grep 'Speed:' | sed 's/^[[:space:]]*Speed:[[:space:]]*//')"
    #if [[ ! "${speed,,}" =~ "unknown" ]]; then  # Skip disconnected ports
        if [[ -z "${wolsupport}" ]]; then
            echo "$lan WOL support unknown (driver doesn't report it)"
        elif [[ ! "${wolsupport,,}" =~ "g" ]]; then
            echo "$lan WOL not supported"
        elif [[ "${wol,,}" =~ "g" ]]; then
            echo "$lan WOL MagicPacket enabled"
        else
            echo "$lan WOL MagicPacket not enabled"
        fi
    #fi
done


# https://evilshit.wordpress.com/2014/03/23/how-to-enable-and-use-wake-on-lan/

# Wake-on-LAN options
# 
# p = Wake on PHY activity
# u = Wake on unicast messages
# m = Wake on multicast messages
# b = Wake on broadcast messages
# a = Wake on ARP
# g = Wake on MagicPacket™
# s = Enable SecureOn™ password for MagicPacket™
# f = Wake on filter(s)
# d = Disable (wake on nothing). This option clears all previous options.


# Synology's Built-in Ethernet ports:
#
# Supports Wake-on: pumbg
#         Wake-on: g
# 
# 
# Synology's 10GbE PCIe card:
# 
# Supports Wake-on: bg
#         Wake-on: g

