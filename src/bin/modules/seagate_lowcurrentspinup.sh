#!/usr/bin/env bash
# shellcheck disable=SC2034
#------------------------------------------------------------------------------
# Some Synology NAS and Expansion Units do not have enough power to spin-up
# multiple Seagate's 20TB and larger drives during boot-up.
#
# This script uses Seagate's openSeaChest to set your 16TB and larger Seagate
# Exos and Ironwolf Pro HDDs to stagger their spin-up and enables lowCurrentSpinup.
#
# Power-Up in Standby (PUIS):
# PUIS ensures that drives remain in standby mode during system startup and only spin up when accessed.
#
# Low Current Spin-Up:
# This feature reduces the power draw during spin-up by starting the drives more gradually.
#
# Github: https://github.com/007revad/Seagate_lowCurrentSpinup
# Script verified at https://www.shellcheck.net/
#
# Run in a shell with sudo (replace /volume1/scripts/ with path to script):
# sudo -s /volume1/scripts/seagate_lowcurrentspinup.sh
#
# To disable PUIS and lowCurrentSpinup
# sudo -s /volume1/scripts/seagate_lowcurrentspinup.sh disable
#
# https://github.com/Seagate/openSeaChest
# https://www.perplexity.ai/search/my-synology-1821-wont-start-up-DCEWq2y5TvO4WoUsFli_sw
#------------------------------------------------------------------------------

BIN_DIR="/var/packages/Syno_Toolbox/target/bin"

# Get NAS model
model=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf upnpmodelname 2>/dev/null)
# Fallback for systems where upnpmodelname is unavailable
if [[ -z "$nas_model" && -f /proc/sys/kernel/syno_hw_version ]]; then
    model=$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null || echo "")
    # Check for dodgy characters after model number
    if [[ ${nas_model,,} =~ 'pv10-j'$ ]]; then  # GitHub issue #10
        model=${nas_model%??????}+              # replace last 6 chars with +
    elif [[ ${nas_model} =~ '-j'$ ]]; then      # GitHub issue #2
        model=${nas_model%??}                   # remove last 2 chars
    fi
fi
if [[ -z "$model" ]]; then
    model="Unknown_model"
fi

# Check supported arches
arch="$(uname -m)"
supported_arches=("x86_64" "aarch64" "arm7l" "i686")
if [[ ! ${supported_arches[*]} =~ $arch ]]; then
    echo -e "$model not supported"
    exit 
fi

scriptver="v1.0.3-toolbox"
script=Seagate_lowCurrentSpinup
repo="007revad/Seagate_lowCurrentSpinup"
scriptname=seagate_lowcurrentspinup

# Show script version
#echo "$script $scriptver"

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "Error: This script must be run as sudo or root!"
    exit 1
fi

if [[ $1 == "disable" ]]; then
    disable="yes"
elif [[ $1 == "check" ]]; then
    check="yes"
fi


# shellcheck disable=SC2317  # Don't warn about unreachable commands in this function
# shellcheck disable=SC2329  # Don't warn about This function is never invoked.
pause(){ 
    # When debugging insert pause command where needed
    read -s -r -n 1 -p "Press any key to continue..."
    read -r -t 0.1 -s -e --  # Silently consume all input
    stty echo echok  # Ensure read didn't disable echoing user input
    echo -e "\n"
}

is_usb(){ 
    # $1 is /dev/sda or /sys/block/sda etc
    if realpath /sys/block/"$(basename "$1")" | grep -q usb; then
        return 0
    else
        return 1
    fi
}

is_seagate(){ 
    # Check if drive is Seagate Exos or Ironwolf Pro 16TB to 58TB
    DEVICE=$(smartctl -A -i /dev/"$1" | awk -F ' ' '/Device Model/{print $3}')
    if [[ -z $DEVICE ]]; then
        DEVICE=$(smartctl -A -i /dev/"$1" | awk -F ' ' '/Product/{print $2}')
    fi
#    if echo "$DEVICE" | grep -qE '^ATA.*ST(1[68]|[2-5][02468])[0]{3,}N[T|E|M|G]'; then  # All Seagate Exos and Ironwolf Pro 16TB to 58TB
    if echo "$DEVICE" | grep -qE '^ATA.*ST[1-4][0-9][0]{3,}'; then  # debug with smaller Seagate Ironwolf drives
        return 0
    else
        return 1
    fi
}

# Add drives to drives array to skip installing openSeaChest if no Seagate drives
for d in /sys/block/*; do
    # $d is /sys/block/sata1 etc
    case "$(basename -- "${d}")" in
        sd*|hd*)
            if [[ $d =~ [hs]d[a-z][a-z]?$ ]]; then
                if ! realpath /sys/block/"$(basename "$d")" | grep -q usb; then
                    if is_seagate "$(basename -- "${d}")"; then
                        drives+=("$(basename -- "${d}")")
                    fi
                fi
            fi
        ;;
        sata*|sas*)
            if [[ $d =~ (sas|sata)[0-9][0-9]?[0-9]?$ ]]; then
                if is_seagate "$(basename -- "${d}")"; then
                    drives+=("$(basename -- "${d}")")
                fi
            fi
        ;;
    esac
done

if [[ ${#drives[@]} -lt 1 ]]; then
    echo -e "No Seagate Exos or Ironwolf Pro 16TB to 38TB HDDs found"
    exit
fi


set_puis(){ 
    # Set Power Up In Standby
    #--------------------------------------------------------------------------
    # --puisFeature [ info | spinup | enable | disable ]  (SATA Only)
    #         Use this option to enable or disable the power up in standby (PUIS) feature on SATA drives.
    #         Arguments:
    #             info    - display information about the PUIS support on the device
    #             spinup  - issue the PUIS spinup set features command to spin up the device to active/idle state.
    #             enable  - enable the PUIS feature using setfeatures command
    #             disable - disable the PUIS feature using setfeatures command
    #         Note: Not all products support this feature.
    #--------------------------------------------------------------------------
    # Check if PUIS is supported
    if ! "${BIN_DIR}"/openSeaChest_PowerControl -d "$sg" --puisFeature info | grep -q 'PUIS is supported'; then
        "${BIN_DIR}"/openSeaChest_PowerControl -d "$sg" --puisFeature info | tail +9
    else
        if [[ $disable == "yes" ]]; then
            # Disable PUIS
            "${BIN_DIR}"/openSeaChest_PowerControl -d "$sg" --puisFeature disable | tail +9 | head -n -1
        else
            # Enable PUIS
            "${BIN_DIR}"/openSeaChest_PowerControl -d "$sg" --puisFeature enable | tail +9 | head -n -1
        fi
    fi
}

set_lcs(){ 
    # Set lowCurrentSpinup
    #--------------------------------------------------------------------------
    # --lowCurrentSpinup [ low | ultra | disable ]  (SATA Only) (Seagate Only)
    #         Use this option to set the state of the low current spinup feature on Seagate SATA drives.
    #         When this setting is enabled for low or ultra low mode,
    #         the drive will take longer to spinup and become ready.
    #         Note: This feature is not available on every drive.
    #         Note: Some products will support low, but not the ultra low current spinup mode.
    #--------------------------------------------------------------------------
    if [[ $disable == "yes" ]]; then
        "${BIN_DIR}"/openSeaChest_Configure -d "$sg" --lowCurrentSpinup disable | tail +11
    else
        "${BIN_DIR}"/openSeaChest_Configure -d "$sg" --lowCurrentSpinup low | tail +11
    fi
}

check_puis(){ 
    # Check Power Up In Standby (PUIS) status
    #--------------------------------------------------------------------------
    # --puisFeature info  (SATA Only)
    #         No settings are changed. This just queries and prints one of:
    #             "PUIS is not supported on this device."
    #             "PUIS is supported"                 (supported but disabled)
    #             "PUIS is supported and enabled"
    #--------------------------------------------------------------------------
    local puis_info
    header=$("${BIN_DIR}"/openSeaChest_PowerControl -d "$sg" --puisFeature info | grep '/dev/sg')
    puis_info=$("${BIN_DIR}"/openSeaChest_PowerControl -d "$sg" --puisFeature info)

    echo -e "\n$header"
    if echo "$puis_info" | grep -q 'PUIS is not supported'; then
        echo "PUIS: Not supported"
    elif echo "$puis_info" | grep -q 'PUIS is supported and enabled'; then
        echo "PUIS: Enabled"
    else
        echo "PUIS: Disabled"
    fi
}

check_lcs(){ 
    # Check lowCurrentSpinup status
    #--------------------------------------------------------------------------
    # openSeaChest_Configure has no "--lowCurrentSpinup info" option
    # (only low | ultra | disable are accepted), so the current state has
    # to be read from the --deviceInfo (-i) output instead, which includes
    # a "Low Current Spinup:" line for Seagate SATA drives only.
    #--------------------------------------------------------------------------
    local lcs_line
    lcs_line=$("${BIN_DIR}"/openSeaChest_Configure -d "$sg" -i | grep 'Low Current Spinup:')

    if [[ -z $lcs_line ]]; then
        echo "Low Current Spinup: Not supported (not a Seagate SATA drive, or feature unavailable)"
    else
        # Trim leading tab/whitespace, e.g. "	Low Current Spinup: Enabled"
        echo "${lcs_line#"${lcs_line%%[![:space:]]*}"}"
    fi
}


# Process SATA Seagate HDDs larger than 16TB
IFS=$'\n' read -r -d '' -a array < <("${BIN_DIR}"/openSeaChest_PowerControl --scan |\
    # Only Seagate SATA drives support PUIS
    # https://grep.js.org/  Online grep tester
    #grep -E '^ATA.*ST[2-4][0,9][0]{3,}')  # All Seagate 20TB and larger drives
    #grep -E '^ATA.*ST[1-4][0-9][0]{3,}N[T|E|M|G]')  # All Seagate Exos and Ironwolf Pro drives 10TB and larger
#    grep -E '^ATA.*ST(1[68]|[2-5][02468])[0]{3,}N[T|E|M|G]')  # All Seagate Exos and Ironwolf Pro 16TB to 58TB
    grep -E '^ATA.*ST[1-4][0-9][0]{3,}')  # debug with smaller Seagate Ironwolf drives
IFS=

if [[ "${#array[@]}" -gt "0" ]]; then
    if [[ $check == "yes" ]]; then
        for drive in "${array[@]}"; do
            #echo "$drive" | awk '{print $3, $4}'  # debug
            sg=$(echo "$drive" | awk '{print $2}')
            check_puis
            check_lcs
        done

    else
        #if [[ $disable == "yes" ]]; then
        #    echo -e "Disabling 'Enable Power-Up in Standby' and 'Low Current Spin-up'"
        #else
        #    echo -e "Enabling 'Enable Power-Up in Standby' and 'Low Current Spin-up'"
        #fi
        for drive in "${array[@]}"; do
            #echo "$drive" | awk '{print $3, $4}'  # debug
            sg=$(echo "$drive" | awk '{print $2}')
#            "${BIN_DIR}"/openSeaChest_PowerControl -d "$sg" --puisFeature enable

            # PUIS info
#            "${BIN_DIR}"/openSeaChest_PowerControl -d "$sg" --puisFeature info | tail +9
            #echo

            set_puis
            set_lcs

        done
    fi
else
    echo -e "No Seagate Exos or Ironwolf Pro 16TB to 38TB HDDs found"
fi
