#!/bin/bash
# Checks whether QuickConnect is enabled and, if so, whether DSM access via
# QuickConnect is enabled (Advanced Settings > Applications/Services > DSM).
#
# Verified on Senna (DSM 7) by toggling the checkboxes and diffing:
#   synorelayd.conf  .quickconnect.enabled        = QuickConnect on/off
#   services.conf    id "dsm_portal" .enabled     = "DSM" checkbox
#   synorelayd.conf  .service[] ids dsm_portal*   = derived list, drops the 3
#                                                   dsm_portal* ids when DSM is unticked
#
# Prints a state token on the first line (language independent), then a message.
# Exit codes: 0 = no exposure, 1 = DSM reachable via QuickConnect, 2 = unknown

scriptver="1.0.0-toolbox"

dir=${QC_DIR:-/usr/syno/etc/synorelayd}
relay_conf="$dir/synorelayd.conf"
services_conf="$dir/services.conf"

if [ "${1:-}" = check ]; then
    enabled=$(/usr/syno/bin/synogetkeyvalue "$toolbox_conf" \
        check_quickconnect_enabled 2>/dev/null | tr -d '"')
    if [ "$enabled" != yes ]; then
        echo " "  # Needed to prevent (no output) appearing on status line
        exit 0
    fi
    # enabled: fall through and run the real check below
fi

if [[ ! -f $relay_conf ]]; then
    #echo "unknown"
    echo "QuickConnect config not found"
    exit 2
fi

qc_enabled=$(jq -r '.quickconnect.enabled | tostring' "$relay_conf" 2>/dev/null)

if [[ $qc_enabled == "false" ]]; then
    #echo "qc_disabled"
    echo "QuickConnect is disabled"
    exit 0
elif [[ $qc_enabled != "true" ]]; then
    #echo "unknown"
    echo "Could not read QuickConnect state"
    exit 2
fi

# Primary source: services.conf (the per-service checkboxes).
# Not using jq's // operator because it treats false as missing.
dsm_enabled=""
if [[ -f $services_conf ]]; then
    dsm_enabled=$(jq -r 'map(select(.id == "dsm_portal"))[0].enabled | tostring' \
        "$services_conf" 2>/dev/null)
fi

# Fallback: the derived service list in synorelayd.conf
if [[ $dsm_enabled != "true" && $dsm_enabled != "false" ]]; then
    if jq -e '.service | map(select(.id == "dsm_portal")) | length > 0' \
        "$relay_conf" >/dev/null 2>&1; then
        dsm_enabled="true"
    elif jq -e '.service | type == "array"' "$relay_conf" >/dev/null 2>&1; then
        dsm_enabled="false"
    else
        #echo "unknown"
        echo "QuickConnect is enabled but the DSM access setting could not be read"
        exit 2
    fi
fi

if [[ $dsm_enabled == "true" ]]; then
    #echo "dsm_exposed"
    echo "WARNING: DSM access via QuickConnect is enabled"
    exit 0
fi

#echo "dsm_off"
echo "QuickConnect is enabled. DSM access via QuickConnect is disabled"
exit 0
