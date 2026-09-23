#!/usr/bin/env bash

#NowLong=$( date '+%Y-%m-%d %H:%M')

# Check Btrfs Scrub status and errors
#echo -e "Btrfs Data Scrub Status at ${NowLong}"

btrf_vols=0
for volume in /volume*; do
    if [[ $volume =~ /volume[0-9]{1,2}$ ]] && [[ $volume != /volume0 ]]; then
        # Check if volume is Btrfs
        if mount | grep "$volume type btrfs" >/dev/null; then
            btrf_vols=$((btrf_vols +1))

            echo -e "${volume:1}:"
            #btrfs scrub status ${volume}/
            mapfile -t lines < <(btrfs scrub status "${volume}/")
            for line in "${lines[@]}"; do
                if [[ $line =~ ^(scrub\ status\ for|UUID:)\ [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} ]]; then
                    continue
                fi
                echo "$line"
            done

            #Errors="$(btrfs scrub status ${volume}/ | grep -E -i 'with [0-9]+ errors' | awk '{print $6}')"
            ##Errors=$((Errors +2))   #debug for testing
            #
            #if [[ $Errors -gt 0 ]]; then
            #    # Warn number of errors
            #    if [[ $Errors -eq 1 ]]; then
            #        echo -e "There was $Errors error"
            #    else
            #        echo -e "There were $Errors errors"
            #    fi
            #    # Show Btrfs error types
            #    btrfs scrub status -dR ${volume}/
            #fi            
        fi
    fi
done

if [[ "$btrf_vols" -lt 1 ]]; then
    echo "No btrfs volumes found"
fi

exit


# Check RAID Scrub (resync) status
echo ""
echo -e "RAID Scrub Status at ${NowLong}"
cat /proc/mdstat
echo ""

