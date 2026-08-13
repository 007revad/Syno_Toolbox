#!/usr/bin/env bash
#--------------------------------------------------------------------
# Show current /var/log size and largest logs if total size > 150 MB
#--------------------------------------------------------------------

scriptver="v1.0.0-toolbox"
#script=Synology_Cleanup_Coredumps
#repo="007revad/Synology_Cleanup_Coredumps"
scriptname=var_log_size

# Check script is running on a Synology NAS
if ! /usr/bin/uname -a | grep -i synology >/dev/null; then
    echo "This script is NOT running on a Synology NAS!"
    echo "Copy the script to a folder on the Synology and run it from there."
    exit 1
fi

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "This script must be run as sudo or root!"
    exit 1
fi

get_var_log_quota(){ 
    local fs quota
    fs=$(df -h /var/log | awk 'NR==2 {print $1}')
    if [[ "$fs" == "/dev/system-root" ]]; then
        quota=$(df -h /var/log | awk 'NR==2 {print $2}')
        echo "$quota"
    fi
}

var_log_size="$(du -sh /var/log | awk '{print $1}')"

total_num=${var_log_size%?}
num_unit="${var_log_size: -1}B"

quota_size="$(get_var_log_quota)"

if 
    echo "/var/log size limit is 200 MB"
fi
echo "/var/log current size is $total_num $num_unit"

if [[ "$total_num" -ge "150" ]] && [[ "$num_unit" == "MB" ]]; then
    du -h /var/log | grep 'M' | head -n -1
fi
