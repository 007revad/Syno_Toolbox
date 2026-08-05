#!/usr/bin/env bash
# shellcheck disable=SC2034
#------------------------------------------------------------
# Cleanup memory core dumps from crashed processes
#
# Optionally set the age in days before deleting a core dump
#   -a #, --age #   where # is number of days
#------------------------------------------------------------

scriptver="v1.2.4-toolbox"
script=Synology_Cleanup_Coredumps
repo="007revad/Synology_Cleanup_Coredumps"
scriptname=syno_cleanup_coredumps

echo -e "Synology_cleanup_coredumps $scriptver by github.com/007revad\n"

#ding(){ 
#    printf \\a
#}

# Check script is running on a Synology NAS
if ! /usr/bin/uname -a | grep -i synology >/dev/null; then
    #ding
    echo "This script is NOT running on a Synology NAS!"
    echo "Copy the script to a folder on the Synology"
    echo "and run it from there."
    exit 1
fi

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    #ding
    echo -e "${Error}Error:${Off} This script must be run as sudo or root!"
    exit 1
fi

# Check for age option
if [[ $1 ]]; then
    if [[ $1 == "-a" ]] || [[ "$1" == "--age" ]]; then
        if [[ $2 =~ [0-9]+ ]]; then
            age=$2
        else
            echo "age argument is invalid: $2"
            exit 1
        fi
    else
        echo "Invalid option: $1"
        exit 1
    fi
fi

clean_path(){
    local path=$1
    local label=$2   # for messages, e.g. volume name or "/var/crash"

    if [[ $age =~ [0-9]+ ]]; then
        echo -e "Deleting core dumps older than $age days on ${label}"
    else
        echo -e "Deleting all core dumps on ${label}"
    fi

    find "$path" -maxdepth 1 -mmin +$((60*24*age)) \( -name "@*.core" -o -name "@*.core.gz" \) -type f -printf '%s\n' 2>/dev/null \
    | awk '{count++; sum+=$1} END {printf "%d %.0f\n", count, sum}' \
    | {
        read -r count sum
        if [[ $count -gt 0 ]]; then
            if find "$path" -maxdepth 1 -mmin +$((60*24*age)) \( -name "@*.core" -o -name "@*.core.gz" \) -type f -delete; then
                total_mb=$(echo "$sum" | awk '{ megabytes = $1 / 1024 / 1024; printf "%.2f", megabytes }')
                printf "Deleted %d files (total %.2f MB)\n\n" "$count" "$total_mb"
            else
                echo ""
            fi
        else
            echo -e "No files to delete.\n"
        fi
    }
}

shopt -s nullglob

# Check all /volume# volumes for @*.core.* files
for volume in /volume*; do
    if [[ $volume =~ /volume[0-9]{1,2}$ ]] && [[ $volume != /volume0 ]]; then
        new=""
        # Check volume is not missing
        if synostgvolume --get-device-path "$volume" >/dev/null 2>&1; then
            clean_path "$volume" "$volume"
        fi
        #echo ""

        # Inform of recent volume core dumps (those newer than $age)
        for coredumps in "$volume"/@*.core*; do
            # Check volume is not missing
            if synostgvolume --get-device-path "$volume" >/dev/null 2>&1; then
                if [[ $age =~ [0-9]+ ]]; then
                    if [[ -f "$coredumps" ]] && [[ $new != yes ]]; then
                        echo -e "Recent volume core dumps less than $age days old:" && new=yes
                    fi
                    echo "$coredumps"
                fi
            fi
        done 2>/dev/null
        if [[ $new == yes ]]; then echo ""; fi
    fi
done

# Check /var/crash for @*.core.* files
clean_path /var/crash "/var/crash"

# Inform of recent /var/crash core dumps (those newer than $age)
for var_coredumps in /var/crash/@*.core*; do
    if [[ $age =~ [0-9]+ ]]; then
        if [[ -f "$var_coredumps" ]] && [[ $new != yes ]]; then
            echo -e "Recent /var/crash core dumps less than $age days old:" && new=yes
        fi
        echo "$var_coredumps"
    fi
done 2>/dev/null

shopt -u nullglob

# Email if new core dumps found (if scheduled task set to email on errors)
if [[ $new == yes ]]; then
    exit 1
fi


