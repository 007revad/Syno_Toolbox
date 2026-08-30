#!/usr/bin/env bash
# shellcheck disable=SC2034
# Restore missing entries in DSM 7 UPS "Permitted DiskStation Devices" (ups_acl)
#
# The DSM UPS UI only manages/displays 5 entries in ups_acl. Any extra entries
# added manually survive until the next time UPS settings are saved in
# Control Panel > Hardware & Power > UPS, at which point the UI overwrites
# synoups.conf and silently drops anything beyond its own 5.
#
# This script re-adds any required client IP(s) missing from ups_acl and
# restarts the ups-usb service so the change takes effect.
#
# Exit 0 = OK, all required clients already present, nothing to do
# Exit 1 = ACL was missing an entry and has been restored (Task Scheduler sends email)
# Exit 2 = failed to read/write synoups.conf or restart the service
# Exit 3 = UPS not configured, or this NAS is a UPS client (mode=slave), not the server
# Exit 4 = only supported on DSM 7 (synoups.conf doesn't exist on DSM 6)

scriptver="1.0.0-toolbox"

CONF="/usr/syno/etc/ups/synoups.conf"

# --- Configure the client IP(s) that must always be present in ups_acl ---
# Add more IPs here (space separated) if you have other "extra" clients
# beyond the 5 the DSM UI manages.
REQUIRED_CLIENTS=("192.168.20.12")

DSM_VER="$(synogetkeyvalue /etc.defaults/VERSION majorversion)"
if [[ "$DSM_VER" -lt "7" ]]; then
    echo "This script only applies to DSM 7 (synoups.conf). DSM version: $DSM_VER"
    exit 4
fi

if [[ ! -f "$CONF" ]]; then
    echo "UPS not configured! $CONF not found."
    exit 3
fi

UPS_MODE="$(synogetkeyvalue "$CONF" ups_mode)"
if [[ -z "$UPS_MODE" ]]; then
    echo "UPS not configured!"
    exit 3
elif [[ "$UPS_MODE" == "slave" ]]; then
    echo "This NAS is a UPS client (slave), not the server. ups_acl doesn't apply here."
    exit 3
fi

CURRENT_ACL="$(synogetkeyvalue "$CONF" ups_acl)"
if [[ -z "$CURRENT_ACL" ]]; then
    echo "Failed to read ups_acl from $CONF!"
    exit 2
fi

# Split on '|' into an array for exact-match checking
# (avoids substring false-positives, e.g. .12 matching .120)
IFS='|' read -ra acl_ips <<< "$CURRENT_ACL"

missing=()
for client in "${REQUIRED_CLIENTS[@]}"; do
    found=0
    for ip in "${acl_ips[@]}"; do
        [[ "$ip" == "$client" ]] && found=1 && break
    done
    [[ "$found" -eq 0 ]] && missing+=("$client")
done

if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "UPS ACL OK: all required clients present."
    exit 0
fi

# Backup before modifying
cp -p "$CONF" "${CONF}.bak_$(date +%Y%m%d_%H%M%S)"

NEW_ACL="$CURRENT_ACL"
for client in "${missing[@]}"; do
    echo "Restoring missing UPS ACL entry: $client"
    NEW_ACL="${NEW_ACL}${client}|"
done

if ! synosetkeyvalue "$CONF" ups_acl "$NEW_ACL"; then
    echo "Failed to write updated ups_acl to $CONF!"
    exit 2
fi

if ! synosystemctl restart ups-usb; then
    echo "ups_acl updated but failed to restart ups-usb service!"
    exit 2
fi

echo "UPS ACL restored (added: ${missing[*]}) and ups-usb service restarted."
exit 1
