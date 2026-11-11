#!/usr/bin/env bash
# shellcheck disable=SC2034
# Check if DSM is accessible from the internet (warn if it is)
#
# Checks, all in parallel:
#   - DSM http and https ports (from synow3.sc, then DSM.json)  -> WARNING
#   - Ports 80 and 443 (from synow3.sc http and https sections)  -> NOTICE
#   - Extra ports from toolbox.conf check_internet_access_extra_ports -> NOTICE
#     e.g. check_internet_access_extra_ports="5000 8080"

scriptver="1.0.2-toolbox"

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

[ "$dsm" -ge 7 ] && vardir=var || vardir=etc
toolbox_conf=/var/packages/Syno_Toolbox/"${vardir}"/toolbox.conf

if [ "${1:-}" = check ]; then
    enabled=$(/usr/syno/bin/synogetkeyvalue "$toolbox_conf" \
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
checker="https://nas-exposure-check.007daver.workers.dev/check-port"

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

get_sc_port(){
    # Get a port from a synow3.sc section. $1 = section name (http or https)
    # Silently fails if the file or section is missing (e.g. SRM)
    local port
    [[ -f $sc ]] || return 1
    port=$(/usr/syno/bin/get_section_key_value "$sc" "$1" dst.ports 2>/dev/null)
    port=${port%%/*}  # Remove /tcp from 443/tcp -> 443
    if [[ $port =~ ^[0-9]+$ ]]; then
        echo "$port"; return 0
    fi
    return 1
}

# Port list. ports[] and kinds[] are parallel arrays.
# kinds: dsm_https, dsm_http, https, http, extra
ports=()
kinds=()

add_port(){
    # $1 = port, $2 = kind. Skips duplicates (first one added keeps its kind)
    local p="$1" k="$2" e
    [[ $p =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 0
    for e in "${ports[@]}"; do
        [[ "$e" == "$p" ]] && return 0
    done
    ports+=("$p")
    kinds+=("$k")
}

no_ports=0
if https_port=$(get_https_port); then
    add_port "$https_port" dsm_https
else
    echo "Could not determine DSM HTTPS port" >&2
    no_ports=$((no_ports +1))
fi
if http_port=$(get_http_port); then
    add_port "$http_port" dsm_http
else
    echo "Could not determine DSM HTTP port" >&2
    no_ports=$((no_ports +1))
fi
if [ "$no_ports" = 2 ]; then exit 1; fi

# Ports 80 and 443 (not on SRM, which has no http/https sections)
if [[ "$os_name" != "SRM" ]]; then
    if p=$(get_sc_port https); then add_port "$p" https; fi
    if p=$(get_sc_port http); then add_port "$p" http; fi
fi

# Extra ports from toolbox.conf (space or comma separated)
extra=$(/usr/syno/bin/synogetkeyvalue "$toolbox_conf" \
    check_internet_access_extra_ports 2>/dev/null | tr -d '"')
extra=${extra//,/ }
for p in $extra; do
    add_port "$p" extra
done

tmp_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp_dir"' EXIT

# Check all ports in parallel. The worker knows the Synology's Internet IP
# address from the curl request.
for i in "${!ports[@]}"; do
    curl -k -s --max-time 10 "${checker}?port=${ports[$i]}" \
        > "$tmp_dir/$i" 2>/dev/null &
done
wait

# Show results in the order the ports were added
no_checker=0
for i in "${!ports[@]}"; do
    port="${ports[$i]}"
    kind="${kinds[$i]}"
    response=$(cat "$tmp_dir/$i" 2>/dev/null)

    #response='{"ip":"1.2.3.4","port":5000,"reachable":true}'   # debug ################################
    #response='{"ip":"1.2.3.4","port":5000,"reachable":false}'  # debug ################################
    #response=""                                                # debug ################################

    if [ -n "$response" ] && echo "$response" | jq -e . >/dev/null 2>&1; then
        ip=$(echo "$response" | jq -r '.ip')
        reachable=$(echo "$response" | jq -r '.reachable')

        case "$kind" in
            dsm_https) label="HTTPS $os_name Port $port" ;;
            dsm_http)  label="HTTP $os_name Port $port" ;;
            https)     label="HTTPS Port $port" ;;
            http)      label="HTTP Port $port" ;;
            *)         label="Port $port" ;;
        esac

        if [[ "$reachable" == "true" ]]; then
            case "$kind" in
                dsm_https|dsm_http)
                    echo "WARNING: IP $ip $label is accessible from the Internet"
                    ;;
                *)
                    echo "NOTICE: IP $ip $label is accessible from the Internet. Check that the $os_name login is not exposed through it"
                    ;;
            esac
        else
            echo "IP $ip $label is not accessible from the Internet"
        fi
    else
        no_checker=$((no_checker +1))
    fi
done

if [ "$no_checker" -gt 0 ]; then
    # Only show this once, however many ports failed
    echo "Could not reach the checker service"
fi

