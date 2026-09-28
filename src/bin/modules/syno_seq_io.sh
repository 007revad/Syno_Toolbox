#!/usr/bin/env bash
# shellcheck disable=SC2076,SC2207,SC2034
#------------------------------------------------------------------------------
# Github: https://github.com/007revad/Synology_enable_sequential_IO
# Script verified at https://www.shellcheck.net/
#
# Synology sets the skip_seq_thresh_kb to 1024
# Setting skip_seq_thresh_kb to 0 enables sequential I/O like DSM 6 had.
#
# To run in a shell (replace /volume1/scripts/ with path to script):
# sudo -i /volume1/scripts/syno_seq_io.sh
#
# You can run this script with a parameter to specify the skip_seq_thresh_kb
# For example the following would set the cache you select back to default
# sudo -i /volume1/scripts/syno_seq_io.sh 1024
#
# If no parameter the script defaults to 0
#------------------------------------------------------------------------------

# v2.0.3
# Added --volumes option to make it possible to schedule script to run at boot-up.
#  - You can specify multiple comma separated volumes.
# Added --kb option to replace setting kb via first parameter.
# Bug fix for "Not persistent across reboots" issue #2
# Bug fix for when no caches are found.
# Bug fix for when multiple caches are found.


scriptver="v2.0.4-toolbox"
script=Synology_enable_sequential_IO
repo="007revad/Synology_enable_sequential_IO"
#scriptname=syno_seq_io

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "$script $scriptver - by 007revad"
    echo -e "Error: This script must be run as sudo or root!"
    exit 1
fi

# Check is script is running from Syno_Toolbox
if [[ $0 == /var/packages/Syno_Toolbox/target/bin/modules/syno_seq_io.sh ]]; then
    is_toolbox=yes
else
    is_toolbox=""
fi

# Set conf file
if [[ -d /var/packages/Syno_Toolbox/var ]]; then
    # DSM 7
    default_kb="1024"
    CONF_FILE=/var/packages/Syno_Toolbox/var/toolbox.conf
else
    # DSM 6
    default_kb="0"
    CONF_FILE=/var/packages/Syno_Toolbox/etc/toolbox.conf
fi

version(){ 
    echo -e "$script $scriptver - by 007revad"
    echo -e "See https://github.com/$repo \n"
}

# Save options used
args=("$@")

usage(){ 
    cat <<EOF
$script $scriptver - by 007revad

Usage: $(basename "$0") [options]

Options:
      --volumes=VOLUME  Volume or volumes to enable sequential I/O for
                          Use when scheduling the script
                          Examples:
                          --volumes=volume_1
                          --volumes=volume_1,volume_3,volume_4
      --kb=KB           Set a specific sequential I/O kb value
                          Use to disable sequential I/O
                          --kb=1024
  -c, --check           Check current value
  -e, --email           Disable colored text in output scheduler emails
  -h, --help            Show this help message
  -v, --version         Show the script version

EOF
    exit 0
}

# Check for flags with getopt
if options="$(getopt -o abcdefghijklmnopqrstuvwxyz0123456789 -l \
    volumes:,kb:,check,email,help,version -- "${args[@]}")"; then
    eval set -- "$options"
    while true; do
        case "${1,,}" in
            -h|--help)          # Show usage options
                usage
                ;;
            -v|--version)       # Show script version
                version
                exit
                ;;
            --volumes)          # Volumes to process
                if [[ -n "$2" ]]; then
                    IFS=',' read -r -a cachevols <<< "$2"
                    scheduled="yes"
                    shift
                fi
                ;;
            --kb)               # kb value to set
                if [[ $2 =~ ^[0-9]+$ ]]; then
                    kb="$2"
                    shift
                fi
                ;;
            -c|--check)         # Show current kb setting
                check=yes
                #break
                ;;
            -e|--email)         # Disable colour text in task scheduler emails
                color=no
                ;;
            --)
                shift
                break
                ;;
            *)                  # Show usage options
                echo -e "Invalid option '$1'\n"
                usage "$1"
                ;;
        esac
        shift
    done
else
    echo
    usage
fi

if [[ -z "$kb" ]]; then
    kb="0"
fi

# Show script version
#version

# Show options used
#if [[ ${#args[@]} -gt "0" ]]; then
#    echo "Using options: ${args[*]}"
#fi

if [[ $is_toolbox == "yes" ]]; then
    color="no"
fi

# Shell Colors
if [[ $color != "no" ]]; then
    #Black='\e[0;30m'   # ${Black}
    Red='\e[0;31m'      # ${Red}
    Green='\e[0;32m'    # ${Green}
    #Yellow='\e[0;33m'  # ${Yellow}
    #Blue='\e[0;34m'    # ${Blue}
    #Purple='\e[0;35m'  # ${Purple}
    Cyan='\e[0;36m'     # ${Cyan}
    #White='\e[0;37m'   # ${White}
    #Error='\e[41m'      # ${Error}
    Off='\e[0m'         # ${Off}
#else
#    echo ""  # For task scheduler email readability
fi


# Get list of volumes with caches
cachelist=("$(sysctl dev | grep skip_seq_thresh_kb)")
IFS=$'\n' caches=($(sort <<<"${cachelist[*]}")); unset IFS


if [[ ${#caches[@]} -lt "1" ]]; then
    if [[ $check == "yes" ]]; then
        echo "No SSD caches found" && exit
    else
        echo "No SSD caches found!" && exit 1
    fi
fi


# Get caches' current setting 
for c in "${caches[@]}"; do
    volume="$(echo "$c" | cut -d"+" -f2 | cut -d"." -f1)"
    kbs="$(echo "$c" | cut -d"=" -f2 | awk '{print $1}')"
    volumes+=("${volume}|$kbs")
    volumes_check+=("${volume/_}")

    sysctl_dev="$(echo "$c" | cut -d"." -f2 | awk '{print $1}')"
    sysctl_devs+=("$sysctl_dev")
done


# --check: report each cache's current (live) setting and exit.
# Must happen before the interactive "Select cache volume" prompt below,
# otherwise read -rp waits forever on stdin when run from api.cgi.
if [[ $check == "yes" ]]; then
    for info in "${volumes[@]}"; do
        chk_vol="${info%%|*}"
        chk_kb="${info#*|}"
        if [[ "$chk_kb" == "0" ]]; then
            #echo -e "Sequential I/O for $chk_vol cache is ${Green}Enabled${Off} in /proc/sys/dev"
            echo -e "Sequential I/O for ${chk_vol/_} cache is set to DSM 6 default 0 (unlimited)"
        elif [[ "$chk_kb" == "1024" ]]; then
            #echo -e "Sequential I/O for $chk_vol cache is ${Red}Disabled${Off} in /proc/sys/dev"
            echo -e "Sequential I/O for ${chk_vol/_} cache is set to DSM 7 default 1024"
        elif [[ -z "$chk_kb" ]]; then
            #echo -e "Sequential I/O for ${chk_vol/_} cache is ${Red}not set${Off} in /proc/sys/dev"
            echo -e "Sequential I/O for ${chk_vol/_} cache is not set"
        else
            #echo -e "Sequential I/O for $chk_vol cache is set to ${Cyan}$chk_kb${Off} in /proc/sys/dev"
            echo -e "Sequential I/O for ${chk_vol/_} cache is set to $chk_kb"
        fi
    done

    # Report any set volume that has no SSD cache
    set_vols="$(/usr/syno/bin/synogetkeyvalue "$CONF_FILE" seq_io_volumes)"
    IFS=',' read -r -a cachevols <<< "$set_vols"
    echo_done=""
    for c in "${cachevols[@]}"; do
        [[ -z "$c" ]] && continue
        if [[ ! "$c" =~ "${volumes_check[*]}" ]]; then
            #[[ -z "$echo_done" ]] && echo ""
            echo "No SSD cache found for $c"
            echo_done="yes"
        fi
    done
    exit
fi

# Show cache volumes and current setting
if [[ $scheduled != "yes" ]]; then
    if [[ ${#volumes[@]} -gt 0 ]]; then
        echo -e "Setting a cache's skip_seq_thresh_kb to 0 enables sequential I/O\n"
        #echo "Volumes with a cache: "
        echo "----------------------"
        echo "   Cache_Vol  Setting"
        echo "----------------------"
        for ((i=1; i<=${#volumes[@]}; i++)); do
            info="${volumes[i-1]}"
            before_pipe="${info%%|*}"
            after_pipe="${info#*|}"
            printf "%-3s %-9s %s\n" "$i)" "$before_pipe" "$after_pipe"
        done
        echo "----------------------"
    else
        if [[ $check == "yes" ]]; then
            echo "No SSD caches found" && exit
        else
            echo "No SSD caches found!" && exit 1
        fi
    fi
#else
#    echo ""
fi


# Select volume's cache to edit if not scheduled
if [[ $scheduled != "yes" && $is_toolbox != "yes" ]]; then

    # Parse selected element of array
    read -rp "Select cache volume to edit: " choice
    #IFS="|" read -r cachevol setting <<< "${volumes[choice-1]}"

    # Check valid choice entered
    if [[ $choice =~ ^[0-9]+$ ]] &&  [[ $choice != "0" ]] &&\
        [[ ! $choice -gt "${#volumes[@]}" ]]; then
        IFS="|" read -r cachevol setting <<< "${volumes[choice-1]}"
    else
        echo "Invalid choice! $choice"
        exit
    fi
    echo -e "\nYou selected $cachevol to set to $kb\n"

    cachevols=("$cachevol")
fi


matched_vols=()
for v in "${sysctl_devs[@]}"; do
    # Volume name from the device, e.g. volume_4 from ...cache_1+volume_4
    vname="${v##*+}"
    for c in "${cachevols[@]}"; do
        # Accept volume4 (Syno_Toolbox UI) or volume_4 (script/DSM name)
        if [[ "${vname//_/}" == "${c//_/}" ]]; then
            cachevol="$vname"
            matched_vols+=("$vname")

            # Get cache's key name
            cacheval="$(sysctl dev | grep skip_seq_thresh_kb | grep -F "+${cachevol}.")"
            key="$(echo "$cacheval" | cut -d"=" -f1 | cut -d" " -f1)"

            # Set new cache kb value
            val="$(synosetkeyvalue /etc/sysctl.conf "$key")"
            if [[ $val != "$kb" ]]; then
                synosetkeyvalue /etc/sysctl.conf "$key" "$kb"
            fi

            if echo "$v" | grep "$cachevol" >/dev/null; then
                echo "$kb" > "/proc/sys/dev/${v}/skip_seq_thresh_kb"
            fi

            # Check we set key value
            chk_kb="$(synogetkeyvalue /etc/sysctl.conf "$key")"
            if [[ "$chk_kb" == "0" ]]; then
                #echo -e "Sequential I/O for ${cachevol/_} cache is ${Green}Enabled${Off} in /etc/sysctl.conf"
                echo -e "Sequential I/O for ${cachevol/_} cache is set to DSM 6 default 0 (unlimited) in /etc/sysctl.conf"
            elif [[ "$chk_kb" == "1024" ]]; then
                #echo -e "Sequential I/O for ${cachevol/_} cache is ${Red}Disabled${Off} in /etc/sysctl.conf"
                echo -e "Sequential I/O for ${cachevol/_} cache is set to DSM 7 default 1024 in /etc/sysctl.conf"
            elif [[ -z "$chk_kb" ]]; then
                #echo -e "Sequential I/O for ${cachevol/_} cache is ${Red}not set${Off} in /etc/sysctl.conf"
                echo -e "Sequential I/O for ${cachevol/_} cache is not set in /etc/sysctl.conf"
            else
                #echo -e "Sequential I/O for ${cachevol/_} cache is set to ${Cyan}$chk_kb${Off} in /etc/sysctl.conf"
                echo -e "Sequential I/O for ${cachevol/_} cache is set to $chk_kb in /etc/sysctl.conf"
            fi

            # Check we set proc/sys/dev
            val="$(cat /proc/sys/dev/"${v}"/skip_seq_thresh_kb)"
            if [[ "$val" == "0" ]]; then
                #echo -e "Sequential I/O for ${cachevol/_} cache is ${Green}Enabled${Off} in /proc/sys/dev\n"
                echo -e "Sequential I/O for ${cachevol/_} cache is set to DSM 6 default 0 (unlimited) in /proc/sys/dev\n"
            elif [[ "$val" == "1024" ]]; then
                #echo -e "Sequential I/O for ${cachevol/_} cache is ${Red}Disabled${Off} in /proc/sys/dev\n"
                echo -e "Sequential I/O for ${cachevol/_} cache is set to DSM 7 default 1024 in /proc/sys/dev\n"
            elif [[ -z "$val" ]]; then
                #echo -e "Sequential I/O for ${cachevol/_} cache is ${Red}not set${Off} in /proc/sys/dev\n"
                echo -e "Sequential I/O for ${cachevol/_} cache is not set in /proc/sys/dev\n"
            else
                #echo -e "Sequential I/O for ${cachevol/_} cache is set to ${Cyan}$val${Off} in /proc/sys/dev\n"
                echo -e "Sequential I/O for ${cachevol/_} cache is set to $val in /proc/sys/dev\n"
            fi
        fi
    done
done

# Syno_Toolbox only: any cache that is NOT in the selected volumes goes back to the 
# DSM 7 default (1024) or DSM 6 default (0), so unticking a volume in the UI reverts it.
if [[ $is_toolbox == "yes" ]]; then
    for v in "${sysctl_devs[@]}"; do
        vname="${v##*+}"
        selected=""
        for c in "${cachevols[@]}"; do
            [[ "${vname//_/}" == "${c//_/}" ]] && selected=yes
        done
        [[ $selected == "yes" ]] && continue

        cacheval="$(sysctl dev | grep skip_seq_thresh_kb | grep -F "+${vname}.")"
        key="$(echo "$cacheval" | cut -d"=" -f1 | cut -d" " -f1)"
        conf_kb="$(synogetkeyvalue /etc/sysctl.conf "$key")"
        proc_kb="$(cat /proc/sys/dev/"${v}"/skip_seq_thresh_kb)"

        if [[ "$proc_kb" != "$default_kb" || ( -n "$conf_kb" && "$conf_kb" != "$default_kb" ) ]]; then
            synosetkeyvalue /etc/sysctl.conf "$key" "$default_kb"
            echo "$default_kb" > "/proc/sys/dev/${v}/skip_seq_thresh_kb"
            if [[ "$default_kb" == "1024" ]]; then
                echo "Sequential I/O for ${vname/_} cache is set to DSM 7 default 1024"
            else
                echo "Sequential I/O for ${vname/_} cache is set to DSM 6 default 0"
            fi
        fi
    done
fi

# Report any requested volume that has no SSD cache
for c in "${cachevols[@]}"; do
    found=""
    for m in "${matched_vols[@]}"; do
        [[ "${m//_/}" == "${c//_/}" ]] && found=yes
    done
    [[ $found == "yes" ]] || echo "No SSD cache found for $c"
done


if [[ $scheduled != "yes" && $is_toolbox != "yes" ]]; then
    echo "You need to run this script after each reboot,"
    echo -e "or schedule a triggered task to run it as root at boot.\n"
fi


exit

