#!/usr/bin/env bash
# shellcheck disable=SC2034
# Check if DSM is accessible from the internet (warn if it is)

scriptver="1.0.0-toolbox"

dsm="$(synogetkeyvalue /etc.defaults/VERSION majorversion)"
os_name="$(synogetkeyvalue /etc.defaults/VERSION os_name)"

sc=/usr/syno/etc/services.d/synow3.sc
json=/usr/syno/etc/www/DSM.json
conf=/etc/synoinfo.conf

get_https_port(){
    # Get host's https DSM port
    local port section

    if [[ "$os_name" == "SRM" ]]; then
        # Is SRM
        port=$(/usr/syno/bin/synogetkeyvalue "$conf" secure_admin_port 2>/dev/null)
        if [[ $port =~ ^[0-9]+$ ]]; then
            echo "$port"; return 0
        fi
    else
        # Is DSM or DSM Enterprise
        
        # Try section:key:value file (check the typo'd and corrected section names)
        if [[ -f $sc ]]; then
            # Synology misspelt dsm as dms so try both in case they fix it in future
            for section in dms_https dsm_https; do
                port=$(/usr/syno/bin/get_section_key_value "$sc" "$section" dst.ports 2>/dev/null)
                port=${port%%/*}  # Remove /tcp from 5001/tcp -> 5001
                if [[ $port =~ ^[0-9]+$ ]]; then
                    echo "$port"; return 0
                fi
            done
        fi

        # Fallback: DSM.json, "port" inside the "ssl" block only
        if [[ -f $json ]]; then
            port=$(awk '
                /"ssl"[[:space:]]*:/ {in_ssl=1}
                in_ssl && /"port"[[:space:]]*:/ {
                    gsub(/[^0-9]/,"",$0); print; exit
                }' "$json")
            if [[ $port =~ ^[0-9]+$ ]]; then
                echo "$port"; return 0
            fi
        fi
    fi

    return 1
}

if ! https_port=$(get_https_port); then
    echo "Could not determine DSM HTTPS port" >&2
    exit 1
#else
#    echo "DSM HTTPS port: $https_port"
fi

# Check if the Synology's https webui port is reachable from the Internet
# The worker knows the Synology's Internet IP address from the curl request
response=$(curl -k -s --max-time 10 "https://nas-exposure-check.007daver.workers.dev/check-port?port=${https_port}")

if [ -n "$response" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
    ip=$(echo "$response" | jq -r '.ip')
    port=$(echo "$response" | jq -r '.port')
    reachable=$(echo "$response" | jq -r '.reachable')

    if [[ "$reachable" == "true" ]]; then
        echo "IP $ip Port $port is accessible from the Internet"
    else
        echo "IP $ip Port $port is not accessible from the Internet"
    fi
else
    echo "Could not reach the checker service"
fi
