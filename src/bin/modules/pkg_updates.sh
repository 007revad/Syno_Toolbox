#!/bin/bash
#------------------------------------------------------------------------------
# Original script by Adama on synology-forum.de
# https://www.synology-forum.de/threads/download-station-neue-version-4-1-1-5008.141032/post-1271430
# Edited by 007revad (DaveR)
#------------------------------------------------------------------------------

PKG_NAME="Syno_Toolbox"
PKG_ROOT="/var/packages/${PKG_NAME}"
UI_DIR="${PKG_ROOT}/target/ui"

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
PKG_UPDATES_HTML="${UI_DIR}/pkg_updates.html"

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

# html header
MESSAGE='<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Package versions</title>
<style>body {font-family: Verdana, Arial, sans-serif; font-size: 13px; color: #333} table {text-align: left; border-collapse: collapse; table-layout: auto; width: 100%;} thead {color: white;background-color: navy;} th,td {padding: 0.3em 0.8em;} th {border: 2px solid black;} tbody td {border: 1px solid gray;} tbody tr:nth-child(even) td {background-color: #f3f3f3;} tfoot td {border: 1px solid black;} .upd {font-weight: bold;}</style></head>
<body><style>.no-wrap {white-space: nowrap;} .notes {overflow-wrap: break-word; word-break: break-word;}</style>'


#------------------------------------------------------------------------------
# Check for packages at risk of PHP2Shell (Synology-SA-26:14)
# https://www.synology.com/en-global/security/advisory/Synology_SA_26_14

# Prints the fixed version, "none" if no fix will be provided,
# or nothing if the package isn't affected on this DSM version
php2shell_fixed() {
    case "$1" in
        Calendar)
            if   [[ "$BUILD" -ge 64570 ]]; then echo "3.0.4-21435"  # DSM 7.2 and later
            elif [[ "$BUILD" -ge 41890 ]]; then echo "2.4.8-10948"  # DSM 7.0 to 7.1
            elif [[ "$BUILD" -ge 24922 ]]; then echo "2.4.8-0948"   # DSM 6.2.2 to 6.2.4
            fi ;;
        MailStation)
            if   [[ "$BUILD" -ge 60000 ]]; then echo "30000002.3.19-20333"  # DSM 7.2 and later
            elif [[ "$BUILD" -ge 41805 ]]; then echo "30000002.3.19-10333"  # DSM 7.0 to 7.1
            elif [[ "$BUILD" -ge 24922 ]]; then echo "30000002.3.19-0333"   # DSM 6.2.2 to 6.2.4
            fi ;;
        PHP7.3)      echo "none" ;;  # End of life
        PHP7.4)
            if   [[ "$BUILD" -ge 60096 ]]; then echo "7.4.33-0131"  # DSM 7.2 and later
            elif [[ "$BUILD" -ge 41300 ]]; then echo "7.4.33-0122"  # DSM 7.0 to 7.1
            elif [[ "$BUILD" -ge 22232 ]]; then echo "7.4.33-0010"  # DSM 6.2 to 6.2.4
            fi ;;
        PHP8.0)
            if   [[ "$BUILD" -ge 60096 ]]; then echo "8.0.30-0122"  # DSM 7.2 and later
            elif [[ "$BUILD" -ge 41300 ]]; then echo "8.0.30-0104"  # DSM 7.0 to 7.1
            fi ;;
        PHP8.1) echo "8.1.34-0120" ;;  # DSM 7.2-60096 and later
        PHP8.2)
            if [[ "$ENTERPRISE" == "yes" ]]; then echo "8.2.35-0134"  # DSM Enterprise
            elif   [[ "$BUILD" -ge 60096 ]]; then echo "8.2.35-0171"  # DSM 7.2 and later
            fi ;;
        PHP8.3) echo "8.3.36-0051" ;;  # DSM 7.2-60096 and later
        PHP8.4) echo "8.4.27-0051" ;;  # DSM 7.2-60096 and later
    esac
}

MESSAGE_C+='<table>
<thead style="background-color: #c00000;"><tr><th>Packages at Risk (PHP2Shell)</th><th>Installed</th><th>Fixed in</th></tr></thead>
<tbody>'

risk_count=0
for PACKAGE in Calendar MailStation PHP7.3 PHP7.4 PHP8.0 PHP8.1 PHP8.2 PHP8.3 PHP8.4; do
    [[ -f "/var/packages/${PACKAGE}/INFO" ]] || continue
    INSTALLED=$(synogetkeyvalue "/var/packages/${PACKAGE}/INFO" version)
    PACKAGE_NAME="$(synogetkeyvalue "/var/packages/${PACKAGE}/INFO" displayname)"
    [[ -z "$PACKAGE_NAME" ]] && PACKAGE_NAME="$PACKAGE"

    FIXED="$(php2shell_fixed "$PACKAGE")"
    if [[ -z "$FIXED" ]]; then
        continue
    elif [[ "$FIXED" == "none" ]]; then
        FIXED_SHOW="No fix (end of life)"
    elif [[ "$(printf '%s\n' "$FIXED" "$INSTALLED" | sort -V | head -n1)" != "$FIXED" ]]; then
        FIXED_SHOW="$FIXED"  # Installed is older than fixed
    else
        continue
    fi

    MESSAGE_C+='<tr><td class="no-wrap" style="width:1%">'"$PACKAGE_NAME"'</td><td class="no-wrap" style="width:1%">'"$INSTALLED"'</td><td class="no-wrap" style="width:1%">'"$FIXED_SHOW"'</td></tr>'
    risk_count=$((risk_count +1))
done
MESSAGE_C+='</tbody></table><p>'

if [[ "$risk_count" -gt 0 ]]; then
    MESSAGE+="$MESSAGE_C"
fi


#------------------------------------------------------------------------------
# Check for broken packages

# Broken packages table head
MESSAGE_A+='<table>
<thead><tr><th>Broken Packages</th><th>Version</th><th class="notes">Reason</th></tr></thead>
<tbody>'

count=0
for pkg in /var/packages/*; do
    PKG_ID="$(basename "$pkg")"
    PACKAGE_NAME="$(/usr/syno/bin/synogetkeyvalue "${pkg}/INFO" displayname)"
    PACKAGE_VERSION="$(/usr/syno/bin/synogetkeyvalue "${pkg}/INFO" version)"
    if [[ -f "${pkg}/startFailed" ]]; then
        STATUS_JSON="$(synopkg status "$PKG_ID" 2>/dev/null || true)"
        REASON="$(jq -r '.aspect.error.status_description // .aspect.active.status_description // "unknown reason"' <<< "$STATUS_JSON")"
        echo "$PACKAGE_NAME $PACKAGE_VERSION $REASON"
        MESSAGE_A+='<tr><td class="no-wrap">'"$PACKAGE_NAME"'</td><td class="no-wrap">'"$PACKAGE_VERSION"'</td><td class="notes">'"$REASON"'</td></tr>'
        count=$((count +1))
    fi
done

# Broken packages table close
MESSAGE_A+='</tbody></table><p>'

# If broken packages found
if [[ "$count" -gt 0 ]]; then
    MESSAGE+="$MESSAGE_A"
fi


#------------------------------------------------------------------------------
# Check for packages with updates available

# Packages table
MESSAGE_B+='<table>
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
    # 'synopkg version' takes 0.3 seconds longer than `synogetkeyvalue "/var/packages/${PKG}/INFO" version`
    # For 48 packages (on a DS1812+) that's 14 seconds longer!
    #INSTALLED=$(synopkg version "$PACKAGE")
    INSTALLED=$(synogetkeyvalue "/var/packages/${PACKAGE}/INFO" version)
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
            MESSAGE_B+='<tr><td class="no-wrap">'"$PACKAGE_NAME"'</td><td class="no-wrap">'"$INSTALLED"'</td><td class="no-wrap"><a href="'"$LINK"'">'"$VERSION"'</a></td><td class="notes">'"$CHANGELOG"'</td></tr>'
            count=$((count +1))
        fi
    fi
done

# If packages with updates found
if [[ "$count" -gt 0 ]]; then
    MESSAGE+="$MESSAGE_B"
else
    # No updates found
    MESSAGE+='No package updates found.'
fi


#------------------------------------------------------------------------------

# html footer
MESSAGE+='</tbody></table></body></html>'


echo "$MESSAGE" > "$PKG_UPDATES_HTML"
chmod 644 "$PKG_UPDATES_HTML"

