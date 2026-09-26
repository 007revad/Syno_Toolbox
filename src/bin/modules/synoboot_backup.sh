#!/usr/bin/env bash
# shellcheck disable=SC2034
#------------------------------------------------------------------------------
# Back up synoboot after each DSM update
# so you can recover from a corrupt USBDOM or EEPROM.
#
# Github: https://github.com/007revad/Synoboot_backup
# Script verified at https://www.shellcheck.net/
#
# To run in a shell (replace /volume1/scripts/ with path to script):
# sudo -s /volume1/scripts/synoboot_backup.sh
#------------------------------------------------------------------------------

PKG_NAME="Syno_Toolbox"
PKG_ROOT="/var/packages/${PKG_NAME}"

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

# Set bakpath to suit the location to backup to
bakpath="$(/usr/syno/bin/synogetkeyvalue $TOOLBOX_CONF synoboot_backup_path)"

# Check backpath volume is still correct - and fix if share has moved to another volume
if [[ -n "$bakpath" ]]; then
    "$PKG_ROOT/target/bin/check_share_volume.sh" --key=synoboot_backup_path --path="${bakpath:?}"
    bakpath="$(/usr/syno/bin/synogetkeyvalue $TOOLBOX_CONF synoboot_backup_path)"
fi

#------------------------------------------------------------------------------
# Push a copy of a backup file to the configured remote NAS, via that NAS's
# own Syno_Toolbox receive_backup endpoint (see synology_config_backup.sh
# for the full rationale/API details - tb_backup_upload here is the same
# function, unchanged). Only the shared secret is a global setting shared
# by all three backup tools - the remote destinations are NOT (reversed
# 2026-09: each of DSM Configuration Backup, Backup Synoboot Image and
# Backup MTD Image has its own separate pair, so this reads its own
# synoboot_backup_remote_* keys rather than config_backup_remote_*).
#------------------------------------------------------------------------------

Remote_Backup="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" synoboot_backup_remote_backup)"
Remote_IP="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" synoboot_backup_remote_ip)"
Remote_Toolbox_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" synoboot_backup_remote_toolbox_port)"
[[ -z $Remote_Toolbox_Port ]] && Remote_Toolbox_Port="5001"

Remote2_Backup="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" synoboot_backup_remote2_backup)"
Remote2_IP="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" synoboot_backup_remote2_ip)"
Remote2_Toolbox_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" synoboot_backup_remote2_toolbox_port)"
[[ -z $Remote2_Toolbox_Port ]] && Remote2_Toolbox_Port="5001"

# The one global setting shared by all three backup tools.
Shared_Secret="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_shared_secret)"

if [[ $dsm -ge 7 ]]; then
    nmblookup_cmd="/usr/local/bin/nmblookup"
else
    nmblookup_cmd="/usr/bin/nmblookup"
fi

# Resolve remote hostnames and the same-target skip decision once up
# front, same guard Dave added to synology_config_backup.sh - avoids
# repeating the nmblookup/duplicate-check once per file below.
if [[ $Remote_Backup == "yes" ]]; then
    Remote_Host=$("$nmblookup_cmd" -A "$Remote_IP" | sed -n 2p | cut -d ' ' -f1)
    Remote_Host="${Remote_Host:1}"
fi
Remote2_Skip=no
if [[ $Remote2_Backup == "yes" ]]; then
    if [[ $Remote2_IP == "$Remote_IP" ]]; then
        Remote2_Skip=yes
        echo -e "Skipping 2nd remote backup as $Remote2_IP is the same as Remote backup $Remote_IP" |& tee -a "$TOOLBOX_LOG"
    else
        Remote2_Host=$("$nmblookup_cmd" -A "$Remote2_IP" | sed -n 2p | cut -d ' ' -f1)
        Remote2_Host="${Remote2_Host:1}"
    fi
fi

# Args: ip  https_port  secret  local_file_path  filename  label
# (unchanged from synology_config_backup.sh - see that file's own
# comments for the full protocol rationale)
tb_backup_upload() {
    local ip="$1" port="$2" secret="$3"
    local file_path="$4" filename="$5" label="$6"
    local url response success message

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${Error}Error:${Off} curl not found - required for Syno_Toolbox backup transfer" |& tee -a "$TOOLBOX_LOG"
        return 1
    fi

    if [[ -z $secret ]]; then
        echo -e "${Error}Error:${Off} No shared secret configured - set one in Syno_Toolbox's Backup Transfer Settings on both NAS" |& tee -a "$TOOLBOX_LOG"
        return 1
    fi

    url="https://${ip}:${port}/webman/3rdparty/Syno_Toolbox/api.cgi?action=receive_backup&filename=${filename}"

    response=$(curl -s -k --max-time 300 -X POST \
        -H "X-Toolbox-Secret: ${secret}" \
        --data-binary "@${file_path}" \
        "$url")

    success=$(echo "$response" | grep -o '"success":[a-z]*' | cut -d':' -f2)

    if [[ $success != "true" ]]; then
        message=$(echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        echo -e "${Error}Error:${Off} Syno_Toolbox transfer to ${label} (${ip}) failed: ${message:-$response}" |& tee -a "$TOOLBOX_LOG"
        return 1
    fi

    return 0
}

# Args: file_path  filename  label (for log messages, e.g. "synoboot1")
push_remote_copies() {
    local file_path="$1" filename="$2" label="$3"

    if [[ $Remote_Backup == "yes" ]]; then
        if tb_backup_upload "$Remote_IP" "$Remote_Toolbox_Port" "$Shared_Secret" \
            "$file_path" "$filename" "${Remote_Host:-$Remote_IP}"; then
            echo -e "Upload successful to ${Remote_Host:-$Remote_IP} via Syno_Toolbox (${label})" |& tee -a "$TOOLBOX_LOG"
        fi
    fi

    if [[ $Remote2_Backup == "yes" && $Remote2_Skip == "no" ]]; then
        if tb_backup_upload "$Remote2_IP" "$Remote2_Toolbox_Port" "$Shared_Secret" \
            "$file_path" "$filename" "${Remote2_Host:-$Remote2_IP}"; then
            echo -e "Upload successful to ${Remote2_Host:-$Remote2_IP} via Syno_Toolbox (${label})" |& tee -a "$TOOLBOX_LOG"
        fi
    fi
}

scriptver="v1.0.4-toolbox"
script=Synoboot_backup
#repo="007revad/Synoboot_backup"
#scriptname=synoboot_backup

# Shell Colors
##Black='\e[0;30m'   # ${Black}
##Red='\e[0;31m'     # ${Red}
##Green='\e[0;32m'   # ${Green}
##Yellow='\e[0;33m'   # ${Yellow}
##Blue='\e[0;34m'    # ${Blue}
##Purple='\e[0;35m'  # ${Purple}
#Cyan='\e[0;36m'     # ${Cyan}
##White='\e[0;37m'   # ${White}
#Error='\e[41m'      # ${Error}
#Off='\e[0m'         # ${Off}

Cyan=""
Error=""
Off=""

# Show script version
#echo -e "$script $scriptver\ngithub.com/$repo\n"
#echo "$script $scriptver"

#ding(){ 
#    printf \\a
#}

# Check script is running as root
if [[ $(whoami) != "root" ]]; then
    #ding
    echo -e "${Error}Error:${Off} This script must be run as sudo or root!" |& tee -a "$TOOLBOX_LOG"
    exit 1
fi

# Check script is running on a Synology NAS
if ! uname -a | grep -i synology >/dev/null; then
    #ding
    echo -e "${Error}Error:${Off} This script is NOT running on a Synology NAS!" |& tee -a "$TOOLBOX_LOG"
    echo -e "Copy the script to a folder on the Synology and run it from there." >> "$TOOLBOX_LOG"
    exit 1  # Not a Synology NAS
fi


# Get NAS model
model=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf upnpmodelname 2>/dev/null)
# Fallback for systems where upnpmodelname is unavailable
if [[ -z "$model" && -f /proc/sys/kernel/syno_hw_version ]]; then
    model=$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null || echo "")
    # Check for dodgy characters after model number
    if [[ ${model,,} =~ 'pv10-j'$ ]]; then  # GitHub issue #10
        model=${model%??????}+              # replace last 6 chars with +
    elif [[ ${model} =~ '-j'$ ]]; then      # GitHub issue #2
        model=${model%??}                   # remove last 2 chars
    fi
fi
if [[ -z "$model" ]]; then
    model="Unknown_model"
fi

# Get serial number
serial=$(cat /proc/sys/kernel/syno_serial)

# Get DSM full version
productversion=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION productversion)
buildphase=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildphase)
buildnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber)
smallfixnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION smallfixnumber)
#majorversion=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)

# Show DSM full version and model
if [[ $buildphase == GM ]]; then buildphase=""; fi
if [[ $smallfixnumber -gt "0" ]]; then smallfix="-U$smallfixnumber"; fi
echo -e "$model DSM $productversion-$buildnumber$smallfix $buildphase" >> "$TOOLBOX_LOG"

echo -e "Backup path: ${bakpath}" >> "$TOOLBOX_LOG"


# Check NAS has /dev/synoboot
if [[ ! -e /dev/synoboot ]]; then
    #ding
    echo -e "${Error}Error:${Off} /dev/synoboot not found!" >> "$TOOLBOX_LOG"
    echo -e "Unsupported Synology model: $model  Use Backup MTD Image instead." |& tee -a "$TOOLBOX_LOG"
    exit
fi

# Check backup folder exists
if [[ ! -d $bakpath ]]; then
    #ding
    echo -e "${Error}Error:${Off} Backup path not found: ${bakpath}" |& tee -a "$TOOLBOX_LOG"
    exit 1
fi

# Base filename prefix shared by every partition backup and the full image
baseprefix="${model}_${serial}_${productversion}-${buildnumber}${smallfix}"

if [[ "$check" == "yes" ]]; then
    for n in _synoboot _synoboot1 _synoboot2; do
        file_name="${baseprefix}${n}.img"
        if [[ -f "${bakpath}/$file_name" ]]; then
            echo -e "$file_name already backed up" |& tee -a "$TOOLBOX_LOG"
        else
            echo -e "$file_name not backed up" |& tee -a "$TOOLBOX_LOG"
        fi
    done
    exit
fi

# Set synoboot backup image name
imgname="${model}_${serial}_${productversion}-${buildnumber}${smallfix}_synoboot"

# Backup USB DOM synoboot disk
if [[ ! -f ${bakpath}/${imgname}.img ]]; then
    echo -e "Backing up ${Cyan}${imgname}.img${Off}" |& tee -a "$TOOLBOX_LOG"
    dd if=/dev/synoboot of="${bakpath:?}/${imgname:?}".img
    push_remote_copies "${bakpath}/${imgname}.img" "${imgname}.img" "synoboot"
else
    echo -e "synoboot backup already exists: ${imgname}.img" |& tee -a "$TOOLBOX_LOG"
fi


# Set synoboot1 backup image name
imgname="${model}_${serial}_${productversion}-${buildnumber}${smallfix}_synoboot1"

# Backup USB DOM synoboot1 partition
if [[ ! -f ${bakpath}/${imgname}.img ]]; then
    echo -e "Backing up ${Cyan}${imgname}.img${Off}" |& tee -a "$TOOLBOX_LOG"
    dd if=/dev/synoboot1 of="${bakpath:?}/${imgname:?}".img
    push_remote_copies "${bakpath}/${imgname}.img" "${imgname}.img" "synoboot1"
else
    echo -e "synoboot1 backup already exists: ${imgname}.img" |& tee -a "$TOOLBOX_LOG"
fi


# Set synoboot2 backup image name
imgname="${model}_${serial}_${productversion}-${buildnumber}${smallfix}_synoboot2"

# Backup USB DOM synoboot2 partition
if [[ ! -f ${bakpath}/${imgname}.img ]]; then
    echo -e "Backing up ${Cyan}${imgname}.img${Off}" |& tee -a "$TOOLBOX_LOG"
    dd if=/dev/synoboot2 of="${bakpath:?}/${imgname:?}".img
    push_remote_copies "${bakpath}/${imgname}.img" "${imgname}.img" "synoboot2"
else
    echo -e "synoboot2 backup already exists: ${imgname}.img" |& tee -a "$TOOLBOX_LOG"
fi

#echo -e "\nFinished\n"

exit

