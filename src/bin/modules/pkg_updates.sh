#!/bin/bash
#------------------------------------------------------------------------------
# Original script by Adama on synology-forum.de
# https://www.synology-forum.de/threads/download-station-neue-version-4-1-1-5008.141032/post-1271430
# Edited by 007revad (DaveR)
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
PKG_UPDATES_HTML="${VAR_DIR}/pkg_updates.html"

#EXCLUSION='AvrLogger|Changepanelsize|DskMsg'
EXCLUSION=$(/usr/syno/bin/synogetkeyvalue $TOOLBOX_CONF pkg_updates_exclude)

#------------------------------------------------------------------------------

#set -euo pipefail
set -eEuo pipefail
trap 'echo >&2 "Error: exited with status $? at line $LINENO: $BASH_COMMAND"' ERR
IFS=$'\n'

CURL_OPTS="-fsSL"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/113.0"
HOST=$(hostname -s)
OS_NAME=$(synogetkeyvalue /etc.defaults/VERSION os_name)  # DSM, DSMUC,"DSM Enterprise", BSM etc
if [[ "$OS_NAME" == "DSM Enterprise" ]]; then
    ENTERPRISE=yes
else
    ENTERPRISE=no
fi

ARCH="$(uname -a | awk '{print $NF}' | cut -d"_" -f2)"
MAJOR=$(synogetkeyvalue /etc.defaults/VERSION majorversion)
MINOR=$(synogetkeyvalue /etc.defaults/VERSION minorversion)
BUILD=$(synogetkeyvalue /etc.defaults/VERSION buildnumber)
MICRO=$(synogetkeyvalue /etc.defaults/VERSION micro)
NANO=$(synogetkeyvalue /etc.defaults/VERSION nano)
UNIQUE=$(synogetkeyvalue /etc.defaults/synoinfo.conf unique)
UNIQUE_ENC=$(echo "$UNIQUE" | sed 's/+/%2B/g')
LANGUAGE=$(synogetkeyvalue /etc/synoinfo.conf maillang)
[[ "$LANGUAGE" == "def" || -z "$LANGUAGE" ]] && LANGUAGE="enu"
TIMEZONE=$(synogetkeyvalue /etc/synoinfo.conf timezone)
UPDATE_CHANNEL=$(synogetkeyvalue /etc/synoinfo.conf package_update_channel)
GROUP_ID=0

# Get installed packages list (skip system hidden packages)
if [[ -n "$EXCLUSION" ]]; then
    mapfile -t PACKAGES_TMP < <( synopkg list --name | grep -E -v "$EXCLUSION" | sort )
else
    mapfile -t PACKAGES_TMP < <( synopkg list --name | sort )
fi
for p in "${PACKAGES_TMP[@]}"; do
    # Skip hidden system packages like SupportService, SynoAnalytics and SynoOnlinePack_v2
    install_type=$(synogetkeyvalue "/var/packages/${p}/INFO" install_type)
    if [[ $install_type != "system_hidden" ]]; then
        PACKAGES+=("$p")
    fi
done

# Email header
MESSAGE='<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Package versions</title>
<style>body {font-family: Verdana, Arial, sans-serif; font-size: 13px; color: #333} table {text-align: left; border-collapse: collapse; table-layout: auto; width: 100%;} thead {color: white;background-color: navy;} th,td {padding: 0.3em 0.8em;} th {border: 2px solid black;} tbody td {border: 1px solid gray;} tbody tr:nth-child(even) td {background-color: #f3f3f3;} tfoot td {border: 1px solid black;} .upd {font-weight: bold;}</style></head>
<body><style>.no-wrap {white-space: nowrap;} .notes {overflow-wrap: break-word; word-break: break-word;}</style><table>
<thead><tr><th>Package</th><th>Installed</th><th>Available</th><th class="notes">Release Notes</th></tr></thead>
<tbody>'

# Synology packages
declare -A SYNOLOGY_ROW
while IFS=$'\t' read -r pkg row; do
    SYNOLOGY_ROW["$pkg"]="$row"
done < <(curl -sL "https://pkgupdate7.synology.com/packagecenter/v3/getList?package_update_channel=${UPDATE_CHANNEL}&unique=${UNIQUE_ENC}&build=${BUILD}&major=${MAJOR}&language=${LANGUAGE}&micro=${MICRO}&arch=${ARCH}&minor=${MINOR}&timezone=${TIMEZONE}&group_id=${GROUP_ID}&nano=${NANO}" | jq -r '.packages[] | "\(.package)\t\(tostring)"')

# SynoCommunity packages
declare -A SYNOCOMMUNITY_ROW
while IFS=$'\t' read -r pkg row; do
    SYNOCOMMUNITY_ROW["$pkg"]="$row"
done < <(curl -sL "https://packages.synocommunity.com/?package_update_channel=${UPDATE_CHANNEL}&unique=${UNIQUE_ENC}&build=${BUILD}&major=${MAJOR}&language=${LANGUAGE}&micro=${MICRO}&arch=${ARCH}&minor=${MINOR}&timezone=${TIMEZONE}&group_id=${GROUP_ID}&nano=${NANO}" | jq -r '.packages[] | "\(.package)\t\(tostring)"')

# spkrepo.007revad packages
declare -A SPKREPO_ROW
while IFS=$'\t' read -r pkg row; do
    SPKREPO_ROW["$pkg"]="$row"
done < <(curl -s "https://spkrepo.007daver.workers.dev/?package_update_channel=${UPDATE_CHANNEL}&unique=${UNIQUE_ENC}&build=${BUILD}&major=${MAJOR}&language=${LANGUAGE}&micro=${MICRO}&arch=${ARCH}&minor=${MINOR}&timezone=${TIMEZONE}&group_id=${GROUP_ID}&nano=${NANO}" | jq -r '.packages[] | "\(.package)\t\(tostring)"')

count=0
for PACKAGE in "${PACKAGES[@]}"; do
    INSTALLED=$(synopkg version "$PACKAGE")
    PACKAGE_NAME="$(synogetkeyvalue "/var/packages/${PACKAGE}/INFO" displayname)"
    [[ -z "$PACKAGE_NAME" ]] && PACKAGE_NAME="$PACKAGE"

    VERSION=""
    LINK=""
    CHANGELOG=""
    ROW=""
    if [[ -n "${SYNOLOGY_ROW[$PACKAGE]+x}" ]]; then
        ROW="${SYNOLOGY_ROW[$PACKAGE]}"
    elif [[ -n "${SYNOCOMMUNITY_ROW[$PACKAGE]+x}" ]]; then
        ROW="${SYNOCOMMUNITY_ROW[$PACKAGE]}"
    elif [[ -n "${SPKREPO_ROW[$PACKAGE]+x}" ]]; then
        ROW="${SPKREPO_ROW[$PACKAGE]}"
    fi

    if [[ -n "${ROW:-}" ]]; then
        VERSION=$(jq -r '.version' <<< "$ROW")
        if [[ "$(printf '%s\n' "$VERSION" "$INSTALLED" | sort -V | head -n1)" != "$VERSION" ]]; then
            LINK=$(jq -r '.link' <<< "$ROW")
            CHANGELOG=$(jq -r '.changelog' <<< "$ROW")
            MESSAGE+='<tr><td class="no-wrap">'"$PACKAGE_NAME"'</td><td class="no-wrap">'"$INSTALLED"'</td><td class="no-wrap"><a href="'"$LINK"'">'"$VERSION"'</a></td><td class="notes">'"$CHANGELOG"'</td></tr>'
            count=$((count +1))
        fi
    fi
done

# Email footer
MESSAGE+='</tbody></table></body></html>'

if [[ ! "$count" -ge 1 ]]; then
    MESSAGE='<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Package versions</title>
<style>body {font-family: Verdana, Arial, sans-serif; font-size: 13px; color: #333} table {text-align: left; border-collapse: collapse; table-layout: auto; width: 100%;} thead {color: white;background-color: navy;} th,td {padding: 0.3em 0.8em;} th {border: 2px solid black;} tbody td {border: 1px solid gray;} tbody tr:nth-child(even) td {background-color: #f3f3f3;} tfoot td {border: 1px solid black;} .upd {font-weight: bold;}</style></head>
<body><style>.no-wrap {white-space: nowrap;} .notes {overflow-wrap: break-word; word-break: break-word;}</style>
No package updatess found.
</body></html>'
fi

#echo "$MESSAGE" > /volume1/github/Repositories/_packages/Syno_Toolbox/src/bin/modules/pkg_updates.html
echo "$MESSAGE" > "$PKG_UPDATES_HTML"
chmod 644 "$PKG_UPDATES_HTML"

