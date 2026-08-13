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

dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="${PKG_ROOT}/var"
else
    VAR_DIR="${PKG_ROOT}/etc"
fi
TOOLBOX_CONF="${VAR_DIR}/toolbox.conf"

# Set bakpath to suit the location to backup to
#bakpath=/volume1/backups/synoboot
bakpath="$(/usr/syno/bin/synogetkeyvalue $TOOLBOX_CONF synoboot_backup_path)"

# Get volume $backupshare is currently located on
backupshare=$(echo -n "$bakpath" | cut -d"/" -f3)
buildnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber)
if [[ $buildnumber -gt "64570" ]]; then
    # DSM 7.2.1 and later
    # synoshare --get-real-path is case insensitive
    vol=$(/usr/syno/sbin/synoshare --get-real-path "$backupshare")
else
    # DSM 7.2 and earlier
    # synoshare --getmap is case insensitive
    vol=$(/usr/syno/sbin/synoshare --getmap "$backupshare" | grep volume | cut -d"[" -f2 | cut -d"]" -f1)
    # I could also have used:
    # vol=$(/usr/syno/sbin/synoshare --get "$backupshare" | tr '[]' '\n' | sed -n "9p")
fi
# Set current volume where shared folder is located
#if [[ ! $vol =~ $bakpath ]]; then
#    
#fi

scriptver="v1.0.2-toolbox"
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

# Show script version
#echo -e "$script $scriptver\ngithub.com/$repo\n"
#echo "$script $scriptver"

#ding(){ 
#    printf \\a
#}

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    #ding
    echo -e "\n${Error}Error:${Off} This script must be run as sudo or root!\n"
    exit 1
fi

# Check script is running on a Synology NAS
if ! /usr/bin/uname -a | grep -i synology >/dev/null; then
    #ding
    echo -e "\n${Error}Error:${Off} This script is NOT running on a Synology NAS!"
    echo -e "Copy the script to a folder on the Synology and run it from there.\n"
    exit 1  # Not a Synology NAS
fi

# Check backup folder exists
if [[ ! -d $bakpath ]]; then
    #ding
    echo -e "${Error}Error:${Off} Backup path not found: ${bakpath}\n"
    exit 1
fi


# Get NAS model
model=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf upnpmodelname 2>/dev/null)
# Fallback for systems where upnpmodelname is unavailable
if [[ -z "$nas_model" && -f /proc/sys/kernel/syno_hw_version ]]; then
    model=$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null || echo "")
    # Check for dodgy characters after model number
    if [[ ${nas_model,,} =~ 'pv10-j'$ ]]; then  # GitHub issue #10
        model=${nas_model%??????}+              # replace last 6 chars with +
    elif [[ ${nas_model} =~ '-j'$ ]]; then      # GitHub issue #2
        model=${nas_model%??}                   # remove last 2 chars
    fi
fi
if [[ -z "$nas_model" ]]; then
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
echo -e "$model DSM $productversion-$buildnumber$smallfix $buildphase\n"

echo -e "Backup path: ${bakpath}\n"


# Check NAS has /dev/synoboot
if [[ ! -e /dev/synoboot ]]; then
    #ding
    echo -e "${Error}Error:${Off} /dev/synoboot not found!"
    echo -e "Unsupported Synology model: $model\n"
    exit 1
fi


# Set backup image name
imgname="${model}_${serial}_synoboot_${productversion}-$buildnumber$smallfix"

# Backup USB DOM synoboot disk
if [[ ! -f ${bakpath}/${imgname}.img ]]; then
    echo -e "Backing up ${Cyan}${imgname}.img${Off}"
    dd if=/dev/synoboot of="${bakpath:?}/${imgname:?}".img
else
    echo -e "synoboot backup already exists: \n${imgname}.img"
fi


# Set backup image name
imgname="${model}_${serial}_synoboot1_${productversion}-$buildnumber$smallfix"

# Backup USB DOM synoboot1 partition
if [[ ! -f ${bakpath}/${imgname}.img ]]; then
    echo -e "\nBacking up ${Cyan}${imgname}.img${Off}"
    dd if=/dev/synoboot1 of="${bakpath:?}/${imgname:?}".img
else
    echo -e "\nsynoboot1 backup already exists: \n${imgname}.img"
fi


# Set backup image name
imgname="${model}_${serial}_synoboot2_${productversion}-$buildnumber$smallfix"

# Backup USB DOM synoboot2 partition
if [[ ! -f ${bakpath}/${imgname}.img ]]; then
    echo -e "\nBacking up ${Cyan}${imgname}.img${Off}"
    dd if=/dev/synoboot2 of="${bakpath:?}/${imgname:?}".img
else
    echo -e "\nsynoboot2 backup already exists: \n${imgname}.img"
fi

echo -e "\nFinished\n"

exit

