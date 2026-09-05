#!/usr/bin/env bash
# shellcheck disable=SC2034
#--------------------------------------------------------------------------
# Backup Synology system configuration and copy backup to another NAS
#         Must be run as root or scheduled to run as root
#
# Works on DMS 7 and DSM 6
#
# Author: 007revad
# Date/Version: 2024-10-24 v1.1.6
#
# Github: https://github.com/007revad/Synology_Config_Backup
# Script verified at https://www.shellcheck.net/
#--------------------------------------------------------------------------

scriptver="v1.1.6-toolbox"

PKG_NAME="Syno_Toolbox"
PKG_ROOT="/var/packages/${PKG_NAME}"

dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="${PKG_ROOT}/var"
else
    VAR_DIR="${PKG_ROOT}/etc"
fi
TOOLBOX_CONF="${VAR_DIR}/toolbox.conf"


# Set where to save the exported configuration file
Target_DIR="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_target_dir)"

# Requires SSH key is setup for remote user
Remote_Backup="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_backup)"
Remote_DIR="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_dir)"
Remote_IP="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_ip)"
Remote_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_port)"
Remote_DIR="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_dir)"
Remote_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_user)"
Local_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_local_user)"

# Requires SSH key is setup for remote2 user
Remote2_Backup="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_backup)"
Remote2_DIR="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_dir)"
Remote2_IP="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_ip)"
Remote2_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_port)"
Remote2_DIR="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_dir)"
Remote2_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_user)"
Local2_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_local_user2)"


# Get volume $Target_DIR is currently located on
backupshare=$(echo -n "$Target_DIR" | cut -d"/" -f3)
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

# Set backup filename

# Append date and time to backup file
File_Name="$( hostname )_$( date +%F_%H%M ).dss"


#--------------------------------------------------------------------------
# Check that script is running as root

if [[ $( whoami ) != "root" ]]; then
	echo -e "Error: This script must be run as sudo or root!"
	# Abort script because it isn't being run by root
	exit 255
fi


#--------------------------------------------------------------------------
# Export Synology configuration to a Synology directory

echo -e "Starting backup of Synology configuration on $( hostname )\n"

if [[ ! -d "$Target_DIR" ]]; then
	echo -e "\nBackup path does not exist:\n${Target_DIR}"
	exit 255
fi

cd "${Target_DIR}" || exit 255
if [[ -f "${Target_DIR}/${File_Name}" ]]; then
	echo -e "Error: Backup file already exists: \n${Target_DIR}/${File_Name}"
	exit 255
else
    /usr/syno/bin/synoconfbkp export --filepath="${Target_DIR}/${File_Name}" >/dev/null
    chown admin:administrators "${Target_DIR}/${File_Name}"
    #chmod 770 "${Target_DIR}/${File_Name}"
fi

# Check exported file created
if [[ ! -f "${Target_DIR}/${File_Name}" ]]; then
	echo -e "Error: Backup file not created: \n${Target_DIR}/${File_Name}"
	exit 255
else
	#echo "Synology configuration exported to $File_Name on $( hostname )"
	#echo "Exported Synology configuration on $( hostname )"
	echo "Export successful on $( hostname )"
fi


#--------------------------------------------------------------------------
# Copy backup to remote NAS

# Remote backup
if [[ $Remote_Backup == "yes" ]]; then
    # Get remote NAS hostname
    Remote_Host=$(/usr/local/bin/nmblookup -A "$Remote_IP" | sed -n 2p | cut -d ' ' -f1)
    Remote_Host="${Remote_Host:1}"

    if [[ $Remote_Host ]]; then
        echo -e "\nCopying backup to ${Remote_Host}"
    else
        echo -e "\nCopying backup to ${Remote_IP}"
    fi
    # Push backup to other device (safer for other device to pull backup from read only share)
    sudo -u "${Local_User}" scp -P "${Remote_Port}" "${Target_DIR}/${File_Name}" "${Remote_User}@${Remote_IP}:'${Remote_DIR}/'"
fi

# 2nd remote backup
if [[ $Remote2_Backup == "yes" ]]; then
    # Get remote NAS hostname
    Remote2_Host=$(/usr/local/bin/nmblookup -A "$Remote2_IP" | sed -n 2p | cut -d ' ' -f1)
    Remote2_Host="${Remote2_Host:1}"

    if [[ $Remote2_Host ]]; then
        echo -e "\nCopying backup to ${Remote2_Host}"
    else
        echo -e "\nCopying backup to ${Remote2_IP}"
    fi
    # Push backup to other device (safer for other device to pull backup from read only share)
    sudo -u "${Local2_User}" scp -P "${Remote2_Port}" "${Target_DIR}/${File_Name}" "${Remote2_User}@${Remote2_IP}:'${Remote2_DIR}/'"
fi


#--------------------------------------------------------------------------
# Finished

echo -e "\nSynology configuration backup complete"

exit
