#!/usr/bin/env bash
# shellcheck disable=SC2034
# Check if DSM is accessible from the internet (warn if it is)

scriptver="1.0.1-toolbox"

dsm="$(synogetkeyvalue /etc.defaults/VERSION majorversion)"
os_name="$(synogetkeyvalue /etc.defaults/VERSION os_name)"
if [[ -z "$os_name" ]]; then
    # DSM 7, DSM Enterprise and SRM have os_name
    # DSM 6 never had os_name at all in either file
    # DSMUC has no package center
    os_name="DSM"
elif [[ "$os_name" == "DSM Enterprise" ]]; then
    # Just use DSM
    os_name="DSM"
fi

if [ "${1:-}" = check ]; then
    [ "$dsm" -ge 7 ] && vardir=var || vardir=etc
    enabled=$(/usr/syno/bin/synogetkeyvalue \
        /var/packages/Syno_Toolbox/"${vardir}"/toolbox.conf \
        check_internet_access_enabled 2>/dev/null | tr -d '"')
    if [ "$enabled" != yes ]; then
        echo " "  # Needed to prevent (no output) appearing on status line
        exit 0
    fi
    # enabled: fall through and run the real check below
fi

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

get_http_port(){
    # Get host's http DSM port
    local port section

    if [[ "$os_name" == "SRM" ]]; then
        # Is SRM
        port=$(/usr/syno/bin/synogetkeyvalue "$conf" admin_port 2>/dev/null)
        if [[ $port =~ ^[0-9]+$ ]]; then
            echo "$port"; return 0
        fi
    else
        # Is DSM or DSM Enterprise
        
        # Try section:key:value file (check the typo'd and corrected section names)
        if [[ -f $sc ]]; then
            # Synology misspelt dsm as dms so try both in case they fix it in future
            for section in dms dsm; do
                port=$(/usr/syno/bin/get_section_key_value "$sc" "$section" dst.ports 2>/dev/null)
                port=${port%%/*}  # Remove /tcp from 5000/tcp -> 5000
                if [[ $port =~ ^[0-9]+$ ]]; then
                    echo "$port"; return 0
                fi
            done
        fi

        # Fallback: DSM.json
        if [[ -f $json ]]; then
            port=$(awk '/"port"[[:space:]]*:/ {gsub(/[^0-9]/,"",$0); print; exit}' "$json")
            if [[ $port =~ ^[0-9]+$ ]]; then
                echo "$port"; return 0
            fi
        fi
    fi

    return 1
}

no_ports=0
if ! https_port=$(get_https_port); then
    echo "Could not determine DSM HTTPS port" >&2
    no_ports=$((no_ports +1))
    #exit 1
#else
#    echo "DSM HTTPS port: $https_port"
fi
if ! http_port=$(get_http_port); then
    echo "Could not determine DSM HTTP port" >&2
    no_ports=$((no_ports +1))
    #exit 1
#else
#    echo "DSM HTTPS port: $https_port"
fi
if [ "$no_ports" = 2 ]; then exit 1; fi

if [ -n "$https_port" ]; then
    # Check if the Synology's https webui port is reachable from the Internet
    # The worker knows the Synology's Internet IP address from the curl request
    response=$(curl -k -s --max-time 10 "https://nas-exposure-check.007daver.workers.dev/check-port?port=${https_port}")

    #response='{"ip":"1.2.3.4","port":5001,"reachable":true}'   # debug ################################
    #response='{"ip":"1.2.3.4","port":5001,"reachable":false}'  # debug ################################
    #response=""                                                # debug ################################

    if [ -n "$response" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
        ip=$(echo "$response" | jq -r '.ip')
        port=$(echo "$response" | jq -r '.port')
        reachable=$(echo "$response" | jq -r '.reachable')

        if [[ "$reachable" == "true" ]]; then
            echo "WARNING: IP $ip HTTPS $os_name Port $port is accessible from the Internet"
        else
            echo "IP $ip HTTPS $os_name Port $port is not accessible from the Internet"
        fi
    else
        echo "Could not reach the checker service"
        no_checker=1
        #exit 1
        #exit 0
    fi
fi

if [ -n "$http_port" ]; then
    # Check if the Synology's http webui port is reachable from the Internet
    # The worker knows the Synology's Internet IP address from the curl request
    response=$(curl -k -s --max-time 10 "https://nas-exposure-check.007daver.workers.dev/check-port?port=${http_port}")

    #response='{"ip":"1.2.3.4","port":5000,"reachable":true}'   # debug ################################
    #response='{"ip":"1.2.3.4","port":5000,"reachable":false}'  # debug ################################
    #response=""                                                # debug ################################

    if [ -n "$response" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
        ip=$(echo "$response" | jq -r '.ip')
        port=$(echo "$response" | jq -r '.port')
        reachable=$(echo "$response" | jq -r '.reachable')

        if [[ "$reachable" == "true" ]]; then
            echo "WARNING: IP $ip HTTP $os_name Port $port is accessible from the Internet"
        else
            echo "IP $ip HTTP $os_name Port $port is not accessible from the Internet"
        fi
    else
        if [ -z "$no_checker" ]; then  # Don't show "Could not reach the checker service" a 2nd time
            echo "Could not reach the checker service"
        fi        
        #exit 1
    fi
fi

