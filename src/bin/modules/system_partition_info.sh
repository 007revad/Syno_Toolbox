#!/usr/bin/env bash
#--------------------------------------------------------------------
# Show current system partitions size
#--------------------------------------------------------------------

scriptver="v1.0.0-toolbox"
scriptname=system_partition_info

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

#df -h / | awk '{s=index($0,$2); e=index($0,$5)+length($5)-1; print substr($0,s,e-s+1)}'

df_result="$(df -h / | tail -n +2)"
size="$(echo -n "$df_result" | awk '{print $2}')"
used="$(echo -n "$df_result" | awk '{print $3}')"
avail="$(echo -n "$df_result" | awk '{print $4}')"
percent="$(echo -n "$df_result" | awk '{print $5}')"

#echo "Size: $size  Used: $used  Avail: $avail  Used%: $percent"
echo "Size: $size  Used: $used $percent  Available: $avail"
