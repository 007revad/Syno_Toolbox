#!/bin/bash

PKG_NAME="Syno_Toolbox"

dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="/var/packages/${PKG_NAME}/var"
else
    VAR_DIR="/var/packages/${PKG_NAME}/etc"
fi
store="$VAR_DIR/wol_devices.tsv"

scanfile="/tmp/hostnames.$$"

trap 'rm -f "$scanfile"' EXIT

detected=()
while read -r _ name family addr _; do
    case "$name" in
        lo|docker*|veth*|tun*|sit0|ovs-system) continue ;;
    esac

    ip_only="${addr%%/*}"
    case "$ip_only" in
        169.254.*) continue ;;
    esac

    carrier_file="/sys/class/net/$name/carrier"
    if [[ -r "$carrier_file" ]]; then
        carrier="$(cat "$carrier_file" 2>/dev/null)"
        [[ "$carrier" != "1" ]] && continue
    fi

    detected+=("$name")
done < <(ip -4 -o addr show)

if [[ "${#detected[@]}" -eq 0 ]]; then
    echo "No connected network interfaces found!"
    exit 1
fi

localnet=()
arch="$(uname -m)"

echo "arch: $arch"
if [[ ! -f /var/packages/Syno_Toolbox/target/bin/"$arch"/arp-scan ]]; then
    echo "/var/packages/Syno_Toolbox/target/bin/${arch}/arp-scan not found!"
    exit 1
fi

for iface in "${detected[@]}"; do
    output=$(/var/packages/Syno_Toolbox/target/bin/${arch}/arp-scan --interface="$iface" --quiet --plain --retry=3 --timeout=300 --localnet 2>/dev/null)
    rc=$?
    if [[ $rc -eq 0 ]]; then
        readarray -t iface_hosts <<< "$output"
        localnet+=("${iface_hosts[@]}")
    fi
done

if [[ "${#localnet[@]}" -eq 0 ]]; then
    echo "Failed to get list of network IP addresses!"
    exit 1
fi

mapfile -t gateway_ips < <(ip route show default | awk '/via/ {print $3}')

filtered=()
for i in "${localnet[@]}"; do
    ip="${i%%$'\t'*}"
    skip=0
    for gw in "${gateway_ips[@]}"; do
        [[ "$ip" == "$gw" ]] && { skip=1; break; }
    done
    [[ "$skip" -eq 1 ]] && continue
    filtered+=("$i")
done
localnet=("${filtered[@]}")

for i in "${localnet[@]}"; do
    ip="${i%%$'\t'*}"
    mac="${i##*$'\t'}"
    (
        h="$(timeout 2 nmblookup -A "$ip" | grep -v -e Looking -e WORKGROUP -e MAC | awk 'NF{print $1; exit}')"
        echo -e "$mac\t$ip\t$h" >> "$scanfile"
    ) &
done
wait

echo -en "\nCount: "
wc -l "$scanfile"
echo ""

# --- merge this run's results into the persistent store ---
declare -A store_ip store_host store_seen
now="$(date +%s)"
prune_days=90
cutoff=$(( now - prune_days * 86400 ))

declare -A store_ip store_host store_seen

if [[ -f "$store" ]]; then
    while IFS=$'\t' read -r mac ip host seen; do
        [[ -z "$mac" ]] && continue
        [[ -n "$seen" && "$seen" -lt "$cutoff" ]] && continue   # drop stale entries older than $prune_days

        skip=0
        for gw in "${gateway_ips[@]}"; do
            [[ "$ip" == "$gw" ]] && { skip=1; break; }
        done
        [[ "$skip" -eq 1 ]] && continue

        store_ip["$mac"]="$ip"
        store_host["$mac"]="$host"
        store_seen["$mac"]="$seen"
    done < "$store"
fi

while IFS=$'\t' read -r mac ip host; do
    [[ -z "$mac" ]] && continue
    store_ip["$mac"]="$ip"
    store_seen["$mac"]="$now"
    [[ -n "$host" ]] && store_host["$mac"]="$host"
    : "${store_host[$mac]:=-}"   # default to "-" if this MAC has never resolved a hostname
done < "$scanfile"

{
    for mac in "${!store_ip[@]}"; do
        printf '%s\t%s\t%s\t%s\n' "$mac" "${store_ip[$mac]}" "${store_host[$mac]}" "${store_seen[$mac]}"
    done
} | sort -t$'\t' -k3,3 -k2,2V > "$store.tmp" && mv "$store.tmp" "$store"

rm -f "$scanfile"

# --- show the merged result ---
while IFS=$'\t' read -r mac ip host seen; do
    [[ "$host" == "-" ]] && host="(no hostname)"
    printf '%-18s %-15s %s\n' "$mac" "$ip" "$host"
done < "$store"
