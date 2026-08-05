#!/usr/bin/env bash
# shellcheck disable=SC2034
#------------------------------------------------------------------------------
# Make DSM show TiB, GiB, MiB and KiB instead of TB, GB, MB and KB
#
# https://www.synology-forum.de/threads/why-kb-instead-of-kb.141695/post-1279464
# https://www.reddit.com/r/synology/comments/1u1oqbx/how_to_make_dsm_show_tib_instead_of_tb/
#
# Github: https://github.com/007revad/Synology_fix_size_units
# Script verified at https://www.shellcheck.net/
#
# To run in a shell (replace /volume1/scripts/ with path to script):
# sudo /volume1/scripts/syno_fix_size_units.sh
#------------------------------------------------------------------------------

scriptver="v1.0.1-toolbox"
script=Synology_fix_size_units
repo="007revad/Synology_fix_size_units"
scriptname=syno_fix_size_units

# Check BASH variable is bash
if [ ! "$(basename "$BASH")" = bash ]; then
    echo "This is a bash script. Do not run it with $(basename "$BASH")"
    #printf \\a
    exit 1
fi

#echo -e "bash version: $(bash --version | head -1 | cut -d' ' -f4)\n"  # debug

# Shell Colors
#Black='\e[0;30m'   # ${Black}
Red='\e[0;31m'      # ${Red}
#Green='\e[0;32m'    # ${Green}
#Yellow='\e[0;33m'   # ${Yellow}
#Blue='\e[0;34m'    # ${Blue}
#Purple='\e[0;35m'  # ${Purple}
Cyan='\e[0;36m'     # ${Cyan}
#White='\e[0;37m'   # ${White}
Error='\e[41m'      # ${Error}
Off='\e[0m'         # ${Off}


usage(){ 
    cat <<EOF
$script $scriptver - by 007revad

Usage: $(basename "$0") [options]

Options:
  -c, --check check    Check the currently set size units
  -d, --disable        Restore settings
  -h, --help           Show this help message
  -v, --version        Show the script version

EOF
    exit 0
}

scriptversion(){ 
    cat <<EOF
$script $scriptver - by 007revad

See https://github.com/$repo

EOF
    exit 0
}


# Save options used
args=("$@")


# Check for flags with getopt
if options="$(getopt -o abcdefghijklmnopqrstuvwxyz0123456789 -l \
    check,disable,help,version,log,debug -- "$@")"; then
    eval set -- "$options"
    while true; do
        case "${1,,}" in
            -h|--help)          # Show usage options
                usage
                ;;
            -v|--version)       # Show script version
                scriptversion
                ;;
            -l|--log)           # Log
                log=yes
                ;;
            --debug)            # Show and log debug info
                debug=yes
                ;;
            -d|--disable)       # Restore defaults
                restore=yes
                ;;
            -c|--check)         # Show current size units
                check=yes
                break
                ;;
            --)
                shift
                break
                ;;
            *)                  # Show usage options
                echo -e "Invalid option '$1'"
                usage "$1"
                ;;
        esac
        shift
    done
else
    usage
fi


if [[ $debug == "yes" ]]; then
    set -x
    export PS4='`[[ $? == 0 ]] || echo "\e[1;31;40m($?)\e[m\n "`:.$LINENO:'
fi


# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "${Error}Error:${Off} This script must be run as root or sudo!"
    exit 1
fi

# Show script version
#echo -e "$script $scriptver\ngithub.com/$repo\n"
#echo "$script $scriptver"

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
if [[ -z "$nas_model" ]]; then
    model="Unknown_model"
fi

# Get DSM full version
productversion=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION productversion)
buildphase=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildphase)
buildnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber)
smallfixnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION smallfixnumber)

# Show DSM full version and model
if [[ $buildphase == GM ]]; then buildphase=""; fi
if [[ $smallfixnumber -gt "0" ]]; then smallfix="-$smallfixnumber"; fi
#echo -e "$model DSM $productversion-$buildnumber$smallfix $buildphase\n"

if [[ $check == "yes" ]]; then
    gui_lang="$(synogetkeyvalue /etc/synoinfo.conf maillang)"
    for s in /usr/syno/synoman/webman/texts/"$gui_lang"/strings; do
        lang="$(echo "$s" | cut -d"/" -f7 | cut -d"/" -f1)"
        echo "[${lang^^}]"
        grep -E '^size_.b' "$s"
        echo ""
    done
    exit
fi

if [[ $restore = "yes" ]]; then
    # Edit strings files:
    for strings in /usr/syno/synoman/webman/texts/*/strings; do sed -i 's/\"KiB\"/\"KB\"/g' "$strings"; done
    for strings in /usr/syno/synoman/webman/texts/*/strings; do sed -i 's/\"MiB\"/\"MB\"/g' "$strings"; done
    for strings in /usr/syno/synoman/webman/texts/*/strings; do sed -i 's/\"GiB\"/\"GB\"/g' "$strings"; done
    for strings in /usr/syno/synoman/webman/texts/*/strings; do sed -i 's/\"TiB\"/\"TB\"/g' "$strings"; done

    # German
    sed -i 's/\"KiB\"/\"kB\"/g' /usr/syno/synoman/webman/texts/ger/strings

    # Czech
    sed -i 's/\"KiB\"/\"kB\"/g' /usr/syno/synoman/webman/texts/csy/strings

    # French
    sed -i 's/\"Kio\"/\"Ko\"/g' /usr/syno/synoman/webman/texts/fre/strings
    sed -i 's/\"Mio\"/\"Mo\"/g' /usr/syno/synoman/webman/texts/fre/strings
    sed -i 's/\"Gio\"/\"Go\"/g' /usr/syno/synoman/webman/texts/fre/strings
    sed -i 's/\"Tio\"/\"To\"/g' /usr/syno/synoman/webman/texts/fre/strings

    # Russian
    # KB
    sed -i 's/\"КиБ\"/\"КБ\"/g' /usr/syno/synoman/webman/texts/rus/strings
    # MB
    sed -i 's/\"МиБ\"/\"МБ\"/g' /usr/syno/synoman/webman/texts/rus/strings
    # GB
    sed -i 's/\"ГиБ\"/\"ГБ\"/g' /usr/syno/synoman/webman/texts/rus/strings
    # TB
    sed -i 's/\"ТиБ\"/\"ТБ\"/g' /usr/syno/synoman/webman/texts/rus/strings
else
    # Edit strings files:
    for strings in /usr/syno/synoman/webman/texts/*/strings; do sed -i 's/\"KB\"/\"KiB\"/g' "$strings"; done
    for strings in /usr/syno/synoman/webman/texts/*/strings; do sed -i 's/\"MB\"/\"MiB\"/g' "$strings"; done
    for strings in /usr/syno/synoman/webman/texts/*/strings; do sed -i 's/\"GB\"/\"GiB\"/g' "$strings"; done
    for strings in /usr/syno/synoman/webman/texts/*/strings; do sed -i 's/\"TB\"/\"TiB\"/g' "$strings"; done

    # German
    sed -i 's/\"kB\"/\"KiB\"/g' /usr/syno/synoman/webman/texts/ger/strings

    # Czech
    sed -i 's/\"kB\"/\"KiB\"/g' /usr/syno/synoman/webman/texts/csy/strings

    # French
    sed -i 's/\"Ko\"/\"Kio\"/g' /usr/syno/synoman/webman/texts/fre/strings
    sed -i 's/\"Mo\"/\"Mio\"/g' /usr/syno/synoman/webman/texts/fre/strings
    sed -i 's/\"Go\"/\"Gio\"/g' /usr/syno/synoman/webman/texts/fre/strings
    sed -i 's/\"To\"/\"Tio\"/g' /usr/syno/synoman/webman/texts/fre/strings

    # Russian
    # KB
    sed -i 's/\"КБ\"/\"КиБ\"/g' /usr/syno/synoman/webman/texts/rus/strings
    # MB
    sed -i 's/\"МБ\"/\"МиБ\"/g' /usr/syno/synoman/webman/texts/rus/strings
    # GB
    sed -i 's/\"ГБ\"/\"ГиБ\"/g' /usr/syno/synoman/webman/texts/rus/strings
    # TB
    sed -i 's/\"ТБ\"/\"ТиБ\"/g' /usr/syno/synoman/webman/texts/rus/strings
fi


# Show the changes:
for s in /usr/syno/synoman/webman/texts/*/strings; do
    lang="$(echo "$s" | cut -d"/" -f7 | cut -d"/" -f1)"
    echo "[${lang^^}]"
    grep -E '^size_.b' "$s"
    echo ""
done

# Refresh browser window
echo -e "You will need to hard refresh the DSM browser tab or window to see the changes"

