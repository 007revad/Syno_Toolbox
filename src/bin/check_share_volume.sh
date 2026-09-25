#!/usr/bin/env bash
# shellcheck disable=SC2034
#------------------------------------------------------------
# Check which volume a shared folder is currently located on
#------------------------------------------------------------

PKG_NAME="Syno_Toolbox"
PKG_ROOT="/var/packages/${PKG_NAME}"

dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="${PKG_ROOT}/var"
else
    VAR_DIR="${PKG_ROOT}/etc"
fi
TOOLBOX_CONF="${VAR_DIR}/toolbox.conf"
TOOLBOX_LOG="${VAR_DIR}/toolbox.log"


# Check for flags with getopt
# DSM getopt version only parses the first -l argument if -o is missing
if options="$(getopt -o abcdefghijklmnopqrstuvwxyz0123456789 \
    -l path:,key:,check -- "$@")"; then
    eval set -- "$options"
    while true; do
        case "${1,,}" in
            --path)
                if [[ "$2" =~ ^/volume.*$ ]]; then
                    bakpath="$2"
                else
                    echo "path argument is invalid: $2" |& tee -a "$TOOLBOX_LOG"
                    exit 1
                fi
                shift
                ;;
            --key)
                key_exists="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" "$2")"
                if [[ -n "$key_exists" ]]; then
                    key="$2"
                else
                    echo "key argument is invalid: $2" |& tee -a "$TOOLBOX_LOG"
                    exit 1
                fi
                shift
                ;;
            --check)
                # Currently unused
                check="yes"
                ;;
            --)
                shift
                break
                ;;
            *)
                echo -e "Invalid option '$1'\n"
                exit 1
                ;;
        esac
        shift
    done
fi

backupshare=$(echo -n "$bakpath" | cut -d"/" -f3)
subfolder="$(echo -n "$bakpath" | cut -d"/" -f4-)"

# Get volume $bakpath is currently located on
buildnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber)
if [[ $buildnumber -gt "64570" ]]; then
    # DSM 7.2.1 and later
    # synoshare --get-real-path is case insensitive
    volshare=$(/usr/syno/sbin/synoshare --get-real-path "$backupshare")
else
    # DSM 7.2 and earlier
    # synoshare --getmap is case insensitive
    volshare=$(/usr/syno/sbin/synoshare --getmap "$backupshare" | grep volume | cut -d"[" -f2 | cut -d"]" -f1)
    # I could also have used:
    # vol=$(/usr/syno/sbin/synoshare --get "$backupshare" | tr '[]' '\n' | sed -n "9p")
fi

if [[ -n "$subfolder" ]]; then
    newpath="${volshare}/$subfolder"
else
    newpath="$volshare"
fi

if [[ "${bakpath:?}" != "${newpath:?}" ]]; then
    if /usr/syno/bin/synosetkeyvalue "$TOOLBOX_CONF" "${key:?}" "${newpath:?}"; then
        echo "Updated $key to $newpath" |& tee -a "$TOOLBOX_LOG"
    else
        echo "Error: Failed to update $key to $newpath" |& tee -a "$TOOLBOX_LOG"
        exit 1
    fi
fi

exit 0

