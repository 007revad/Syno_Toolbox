#!/usr/bin/env bash
# shellcheck disable=SC2034
#--------------------------------------------------------------------------
# Backup Synology system configuration and copy backup to another NAS
#         Must be run as root or scheduled to run as root
#
# Works on DMS 7 and DSM 6
#
# Author: 007revad
# Date/Version: 2026-09-26 v1.1.8
#
# Github: https://github.com/007revad/Synology_Config_Backup
# Script verified at https://www.shellcheck.net/
#--------------------------------------------------------------------------

scriptver="v1.1.8-toolbox"
# v1.1.8-toolbox: added "toolbox" remote copy method - transfers via a
# peer NAS's own Syno_Toolbox receive_backup endpoint (HTTPS + shared
# secret), no DSM account/SSH key/File Station 2FA restriction needed.

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

# Check Target_DIR volume is still correct - and fix if share has moved to another volume
if [[ -n "$Target_DIR" ]]; then
    "$PKG_ROOT/target/bin/check_share_volume.sh" --key=config_backup_target_dir --path="${bakpath:?}"
    Target_DIR="$(/usr/syno/bin/synogetkeyvalue $TOOLBOX_CONF config_backup_target_dir)"
fi

# config_backup_remote_method: "ssh" (default, requires SSH key setup for remote user),
#                               "filestation" (uses File Station API, no SSH key needed),
#                               or "toolbox" (pushes to a peer NAS's own Syno_Toolbox
#                               receive_backup endpoint - no DSM account/SSH key needed,
#                               works with 2FA-protected DSM accounts unlike filestation)
Remote_Method="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_method)"
[[ -z $Remote_Method ]] && Remote_Method="ssh"

Remote_Backup="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_backup)"
Remote_DIR="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_dir)"
Remote_IP="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_ip)"
Remote_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_port)"
Remote_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_user)"
Local_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_local_user)"

# Only needed when config_backup_remote_method="filestation"
Remote_FS_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_fs_user)"
Remote_FS_Pass="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_fs_pass)"
Remote_HTTPS_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_https_port)"
[[ -z $Remote_HTTPS_Port ]] && Remote_HTTPS_Port="5001"

# Only needed when config_backup_remote_method="toolbox" - remote_toolbox_port and
# remote_ip are set by main.js's discovery dropdown, not typed by hand.
Remote_Toolbox_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote_toolbox_port)"
[[ -z $Remote_Toolbox_Port ]] && Remote_Toolbox_Port="5001"

# Single shared secret used for every "toolbox"-method remote (both
# slots) - set once via Syno_Toolbox's Backup Transfer Settings modal
# and matched on every NAS involved, same simplicity as Syno_iperf3's
# approach rather than a secret per remote pair.
Shared_Secret="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_shared_secret)"

# config_backup_remote2_method: "ssh" (default, requires SSH key setup for remote2 user),
#                                "filestation" (uses File Station API, no SSH key needed),
#                                or "toolbox" (see config_backup_remote_method above)
Remote2_Method="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_method)"
[[ -z $Remote2_Method ]] && Remote2_Method="ssh"

Remote2_Backup="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_backup)"
Remote2_DIR="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_dir)"
Remote2_IP="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_ip)"
Remote2_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_port)"
Remote2_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_user)"
Local2_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_local_user2)"

# Only needed when config_backup_remote2_method="filestation"
Remote2_FS_User="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_fs_user)"
Remote2_FS_Pass="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_fs_pass)"
Remote2_HTTPS_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_https_port)"
[[ -z $Remote2_HTTPS_Port ]] && Remote2_HTTPS_Port="5001"

# Only needed when config_backup_remote2_method="toolbox"
Remote2_Toolbox_Port="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" config_backup_remote2_toolbox_port)"
[[ -z $Remote2_Toolbox_Port ]] && Remote2_Toolbox_Port="5001"

majorversion=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
minorversion=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION minorversion)
buildnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber)

# Set backup filename
# Append date and time to backup file
#File_Name="$( hostname )_$( date +%F_%H%M ).dss"
File_Name="$( hostname )_$( date +%F_%H%M )_${majorversion}.${majorversion}-${buildnumber}.dss"


#--------------------------------------------------------------------------
# Upload a file to a remote DSM via the File Station API instead of scp/SSH.
#
# Reference: Synology File Station Official API Guide
#   SYNO.API.Auth (login/logout) and SYNO.FileStation.Upload (method=upload)
#
# Uses -k (skip TLS cert verification) since most home-lab NAS use
# self-signed certs on the DSM admin port. Remove -k if the remote NAS
# has a trusted certificate.
#
# Args: ip  https_port  account  password  dest_dir  local_file_path  label
fs_backup_upload() {
    local ip="$1" port="$2" account="$3" password="$4"
    local dest_dir="$5" file_path="$6" label="$7"
    local base_url="https://${ip}:${port}/webapi"
    local login_response sid upload_response success

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "Error: curl not found - required for File Station API upload"
        return 1
    fi

    if [[ -z $account || -z $password ]]; then
        echo -e "Error: File Station account/password not configured for ${label}"
        return 1
    fi

    # Step 1: log in, get a session ID
    login_response=$(curl -s -k --max-time 30 "${base_url}/auth.cgi" \
        --data-urlencode "api=SYNO.API.Auth" \
        --data-urlencode "version=3" \
        --data-urlencode "method=login" \
        --data-urlencode "account=${account}" \
        --data-urlencode "passwd=${password}" \
        --data-urlencode "session=FileStation" \
        --data-urlencode "format=sid")

    sid=$(echo "$login_response" | grep -o '"sid":"[^"]*"' | cut -d'"' -f4)

    if [[ -z $sid ]]; then
        echo -e "Error: File Station login failed for ${label} (${ip})\n${login_response}"
        return 1
    fi

    # Step 2: upload the file (multipart/form-data; file part must be last)
    upload_response=$(curl -s -k --max-time 300 "${base_url}/entry.cgi" \
        -F "api=SYNO.FileStation.Upload" \
        -F "version=2" \
        -F "method=upload" \
        -F "path=${dest_dir}" \
        -F "create_parents=true" \
        -F "overwrite=true" \
        -F "_sid=${sid}" \
        -F "file=@${file_path}")

    success=$(echo "$upload_response" | grep -o '"success":[a-z]*' | cut -d':' -f2)

    # Step 3: log out regardless of upload result
    curl -s -k --max-time 15 "${base_url}/auth.cgi" \
        --data-urlencode "api=SYNO.API.Auth" \
        --data-urlencode "version=1" \
        --data-urlencode "method=logout" \
        --data-urlencode "session=FileStation" \
        --data-urlencode "_sid=${sid}" >/dev/null

    if [[ $success != "true" ]]; then
        echo -e "Error: File Station upload failed for ${label} (${ip})\n${upload_response}"
        return 1
    fi

    return 0
}


#--------------------------------------------------------------------------
# Upload a file to a peer NAS running Syno_Toolbox, via that package's own
# receive_backup endpoint (api.cgi) - a plain HTTPS POST of the raw file
# bytes, authenticated by a shared secret (set once in Syno_Toolbox's
# Backup Transfer Settings modal, matched on every NAS involved). No DSM
# account, no SSH key, and unlike Plan B's File Station API this works
# fine even if the peer's DSM account has 2FA enabled - there's no DSM
# login involved at all, only Syno_Toolbox's own package-scoped secret.
#
# Deliberately NOT multipart: api.cgi's receive_backup intercepts the
# raw POST body directly (see its own comments) rather than parsing a
# multipart boundary, since bash's normal request parsing can't safely
# handle binary content anyway. filename/action travel in the query
# string, the secret in a custom header - never in the body itself.
#
# Args: ip  https_port  secret  local_file_path  filename  label
tb_backup_upload() {
    local ip="$1" port="$2" secret="$3"
    local file_path="$4" filename="$5" label="$6"
    local url response success message

    if ! command -v curl >/dev/null 2>&1; then
        echo -e "Error: curl not found - required for Syno_Toolbox backup transfer"
        return 1
    fi

    if [[ -z $secret ]]; then
        echo -e "Error: No shared secret configured - set one in Syno_Toolbox's Backup Transfer Settings on both NAS"
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
        echo -e "Error: Syno_Toolbox transfer to ${label} (${ip}) failed: ${message:-$response}"
        return 1
    fi

    return 0
}


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

if [[ $dsm -ge 7 ]]; then
    nmblookup_cmd="/usr/local/bin/nmblookup"
else
    nmblookup_cmd="/usr/bin/nmblookup"
fi

# Remote backup
if [[ $Remote_Backup == "yes" ]]; then
    # Get remote NAS hostname
    Remote_Host=$("$nmblookup_cmd" -A "$Remote_IP" | sed -n 2p | cut -d ' ' -f1)
    Remote_Host="${Remote_Host:1}"

    if [[ $Remote_Host ]]; then
        echo -e "\nCopying backup to ${Remote_Host}"
    else
        echo -e "\nCopying backup to ${Remote_IP}"
    fi

    if [[ $Remote_Method == "filestation" ]]; then
        if fs_backup_upload "$Remote_IP" "$Remote_HTTPS_Port" "$Remote_FS_User" \
            "$Remote_FS_Pass" "$Remote_DIR" "${Target_DIR}/${File_Name}" \
            "${Remote_Host:-$Remote_IP}"; then
            echo "Upload successful to ${Remote_Host:-$Remote_IP} via File Station API"
        fi
    elif [[ $Remote_Method == "toolbox" ]]; then
        if tb_backup_upload "$Remote_IP" "$Remote_Toolbox_Port" "$Shared_Secret" \
            "${Target_DIR}/${File_Name}" "$File_Name" "${Remote_Host:-$Remote_IP}"; then
            echo "Upload successful to ${Remote_Host:-$Remote_IP} via Syno_Toolbox"
        fi
    else
        # Push backup to other device (safer for other device to pull backup from read only share)
        sudo -u "${Local_User}" scp -P "${Remote_Port}" "${Target_DIR}/${File_Name}" "${Remote_User}@${Remote_IP}:'${Remote_DIR}/'"
    fi
fi

# 2nd remote backup
if [[ $Remote2_Backup == "yes" ]]; then
    if [[ $Remote2_IP != "$Remote_IP" ]]; then
        # Get remote NAS hostname
        Remote2_Host=$("$nmblookup_cmd" -A "$Remote2_IP" | sed -n 2p | cut -d ' ' -f1)
        Remote2_Host="${Remote2_Host:1}"

        if [[ $Remote2_Host ]]; then
            echo -e "\nCopying backup to ${Remote2_Host}"
        else
            echo -e "\nCopying backup to ${Remote2_IP}"
        fi

        if [[ $Remote2_Method == "filestation" ]]; then
            if fs_backup_upload "$Remote2_IP" "$Remote2_HTTPS_Port" "$Remote2_FS_User" \
                "$Remote2_FS_Pass" "$Remote2_DIR" "${Target_DIR}/${File_Name}" \
                "${Remote2_Host:-$Remote2_IP}"; then
                echo "Upload successful to ${Remote2_Host:-$Remote2_IP} via File Station API"
            fi
        elif [[ $Remote2_Method == "toolbox" ]]; then
            if tb_backup_upload "$Remote2_IP" "$Remote2_Toolbox_Port" "$Shared_Secret" \
                "${Target_DIR}/${File_Name}" "$File_Name" "${Remote2_Host:-$Remote2_IP}"; then
                echo "Upload successful to ${Remote2_Host:-$Remote2_IP} via Syno_Toolbox"
            fi
        else
            # Push backup to other device (safer for other device to pull backup from read only share)
            sudo -u "${Local2_User}" scp -P "${Remote2_Port}" "${Target_DIR}/${File_Name}" "${Remote2_User}@${Remote2_IP}:'${Remote2_DIR}/'"
        fi
    else
        echo "Skipping 2nd remote backup as $Remote2_IP the same as Remote backup $Remote_IP"
    fi
fi


#--------------------------------------------------------------------------
# Finished

echo -e "\nSynology configuration backup complete"

exit
