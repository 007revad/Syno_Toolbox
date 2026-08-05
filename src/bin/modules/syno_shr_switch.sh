#!/usr/bin/env bash
# shellcheck disable=SC2034
#------------------------------------------------------------------------------
# Switch between SHR and RAID Group for models that have SHR & SHR-2 disabled
# Enable RAID-F1 on non-business models that don't have RAID-F1 enabled
#
# Github: https://github.com/007revad/Synology_SHR_switch
# Script verified at https://www.shellcheck.net/
#
# To run in a shell (replace /volume1/scripts/ with path to script):
# sudo /volume1/scripts/syno_shr_switch.sh
#------------------------------------------------------------------------------

scriptver="v2.0.13-toolbox"
script=Synology_SHR_switch
repo="007revad/Synology_SHR_switch"
scriptname=syno_shr_switch

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

Red=""
Cyan=""
Error=""
Off=""


usage(){ 
    cat <<EOF
$script $scriptver - by 007revad

Usage: $(basename "$0") [options]

Options:
  -c, --check      Check the currently set RAID type
  -h, --help       Show this help message
  -v, --version    Show the script version

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
    check,help,version,log,debug -- "$@")"; then
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
            -d|--debug)         # Show and log debug info
                debug=yes
                ;;
            -c|--check)         # Show current raid type
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

synoinfo="/etc.defaults/synoinfo.conf"


#----------------------------------------------------------
# Check currently enabled RAID type

# Enable SHR
# support_syno_hybrid_raid="yes"
# supportraidgroup="no"
#
# Enable RAID Group
# support_syno_hybrid_raid="no"
# supportraidgroup="yes"

# Set short variables
sshr=support_syno_hybrid_raid
srg=supportraidgroup
srf1=support_diffraid

# Check current setting
#echo ""
checkcurrent(){ 
    settingshr="$(/usr/syno/bin/synogetkeyvalue $synoinfo ${sshr})"
    settingraidgrp="$(/usr/syno/bin/synogetkeyvalue $synoinfo ${srg})"
    if [[ $settingshr == "yes" ]] && [[ $settingraidgrp != "yes" ]]; then
        echo -e "${Cyan}SHR${Off} ${1}enabled" >&2
        enabled="shr"
    elif [[ $settingshr != "yes" ]] && [[ $settingraidgrp == "yes" ]]; then
        echo -e "${Cyan}RAID Groups${Off} ${1}enabled" >&2
        enabled="raidgrp"
    fi

    settingraidf1="$(/usr/syno/bin/synogetkeyvalue $synoinfo ${srf1})"
    if [[ $settingraidf1 == "yes" ]]; then
        echo -e "${Cyan}RAID-F1${Off} ${1}enabled" >&2
        enabledf1="raidf1"
    else
        echo -e "${Cyan}RAID-F1${Off} ${1}disabled" >&2
    fi
}

#checkcurrent "is currently "
checkcurrent "is "
if [[ $check == "yes" ]]; then
    exit
fi


#--------------------------------------------------------------------
# Select RAID type

PS3="Select the RAID type to enable: "
if [[ $enabled == "shr" ]]; then
    #options=("RAID Groups" "Quit")
    if [[ $enabledf1 == "raidf1" ]]; then
        options=("RAID Groups" "Restore" "Quit")
    else
        options=("RAID Groups" "RAID-F1" "Restore" "Quit")
    fi
elif [[ $enabled == "raidgrp" ]]; then
    #options=("SHR" "Quit")
    if [[ $enabledf1 == "raidf1" ]]; then
        options=("SHR" "Restore" "Quit")
    else
        options=("SHR" "RAID-F1" "Restore" "Quit")
    fi
else
    #options=("SHR" "RAID Groups" "Restore" "Quit")
    if [[ $enabledf1 == "raidf1" ]]; then
        options=("SHR" "RAID Groups" "Quit")    
    else
        options=("SHR" "RAID Groups" "RAID-F1" "Quit")
    fi
fi
select raid in "${options[@]}"; do
    case "$raid" in
        SHR)
            shr="yes"
            echo -e "You selected ${Cyan}SHR${Off}"
            if [[ $enabled == "shr" ]]; then
                echo -e "${Cyan}SHR${Off} is already enabled"
            else
                break
            fi
            ;;
        "RAID Group")
            raidgrp="yes"
            echo -e "You selected ${Cyan}RAID Group${Off}"
            if [[ $enabled == "raidgrp" ]]; then
                echo -e "${Cyan}RAID Groups${Off} is already enabled"
            else
                break
            fi
            break
            ;;
        "RAID-F1")
            raidf1="yes"
            echo -e "You selected ${Cyan}RAID-F1${Off}"
            if [[ $enabledf1 == "raidf1" ]]; then
                echo -e "${Cyan}RAID-F1${Off} is already enabled"
            else
                break
            fi
            break
            ;;
        Restore)
            restore="yes"
            echo -e "You selected ${Cyan}Restore${Off}"
            break
            ;;
        Quit)
            echo -e "You selected ${Cyan}Quit${Off}"
            exit
            ;;
        *)
            echo -e "${Red}Invalid answer!${Off} Try again."
            ;;
    esac
done


#----------------------------------------------------------
# Restore from backup synoinfo.conf

if [[ $restore == "yes" ]]; then
    if [[ -f ${synoinfo}.bak ]]; then
        # Restore from backup
        #if cp -p "$synoinfo".bak "$synoinfo" ; then
        #    echo -e "\nSuccessfully restored from backup.\n"
        #    checkcurrent "is now "
        #    exit
        #else
        #    echo -e "\n${Error}Error:${Off} Restore from backup failed!"
        #    exit 1
        #fi

        # Get default key values from backup
        defaultsrg=$(/usr/syno/bin/synogetkeyvalue "$synoinfo".bak "$srg")
        defaultsshr=$(/usr/syno/bin/synogetkeyvalue "$synoinfo".bak "$sshr")
        defaultsrf1=$(/usr/syno/bin/synogetkeyvalue "$synoinfo".bak "$srf1")

        # Set key values to defaults
        if [[ $defaultsrg ]]; then
            #echo -e "\nset support_raid_group $defaultsrg"    # debug

            /usr/syno/bin/synosetkeyvalue "$synoinfo" "$srg" "$defaultsrg"
        else
            #echo -e "\nset support_raid_group no"             # debug

            /usr/syno/bin/synosetkeyvalue "$synoinfo" "$srg" "no"
        fi
        if [[ $defaultsshr ]]; then
            #echo "set support_syno_hybrid_raid $defaultsshr"  # debug

            /usr/syno/bin/synosetkeyvalue "$synoinfo" "$sshr" "$defaultsshr"
        else
            #echo "set support_syno_hybrid_raid no"            # debug

            /usr/syno/bin/synosetkeyvalue "$synoinfo" "$sshr" "no"
        fi

        echo
        if [[ $defaultsrf1 ]]; then
            #echo -e "\nset support_raid_group $defaultsrf1"    # debug

            /usr/syno/bin/synosetkeyvalue "$synoinfo" "$srf1" "$defaultsrf1"
        else
            #echo -e "\nset support_diffraid no"                # debug

            /usr/syno/bin/synosetkeyvalue "$synoinfo" "$srf1" "no"
        fi
        checkcurrent "is "
    else
        echo -e "${Error}Error:${Off} Backup synoinfo.conf not found!"
        exit 1
    fi
    exit
fi


#----------------------------------------------------------
# Backup synoinfo.conf

if [[ ! -f ${synoinfo}.bak ]]; then
    if cp -p "$synoinfo" "$synoinfo".bak ; then
        echo -e "synoinfo.conf backed up"
    else
        echo -e "${Error}Error:${Off} synoinfo.conf backup failed!"
        exit 1
    fi
else
    echo -e "synoinfo.conf already backed up"
fi


#----------------------------------------------------------
# Edit synoinfo.conf

# Enable RAID Group
if [[ $raidgrp == "yes" ]]; then
    /usr/syno/bin/synosetkeyvalue "$synoinfo" "$srg" yes
    /usr/syno/bin/synosetkeyvalue "$synoinfo" "$sshr" no

    # Check if we enabled RAID Group
    settingshr="$(/usr/syno/bin/synogetkeyvalue $synoinfo ${sshr})"
    settingraidgrp="$(/usr/syno/bin/synogetkeyvalue $synoinfo ${srg})"
    if [[ $settingshr != "yes" ]] && [[ $settingraidgrp == "yes" ]]; then
        echo -e "${Cyan}RAID Group${Off} has been enabled"
    else
        echo -e "${Error}Error:${Off} Failed to enable RAID Group!"
    fi
fi

# Enable SHR
if [[ $shr == "yes" ]]; then
    /usr/syno/bin/synosetkeyvalue "$synoinfo" "$srg" no
    /usr/syno/bin/synosetkeyvalue "$synoinfo" "$sshr" yes

    # Check if we enabled SHR
    settingshr="$(/usr/syno/bin/synogetkeyvalue $synoinfo ${sshr})"
    settingraidgrp="$(/usr/syno/bin/synogetkeyvalue $synoinfo ${srg})"
    if [[ $settingshr == "yes" ]] && [[ $settingraidgrp != "yes" ]]; then
        echo -e "${Cyan}SHR${Off} has been enabled"
    else
        echo -e "${Error}Error:${Off} Failed to enable SHR!"
    fi
fi

# Enable RAID-F1
if [[ $raidf1 == "yes" ]]; then
    /usr/syno/bin/synosetkeyvalue "$synoinfo" "$srf1" yes

    # Check if we enabled RAID-F1
    settingraidf1="$(/usr/syno/bin/synogetkeyvalue $synoinfo ${srf1})"
    if [[ $settingraidf1 == "yes" ]]; then
        echo -e "${Cyan}RAID-F1${Off} has been enabled"
    else
        echo -e "${Error}Error:${Off} Failed to enable RAID-F1!"
    fi
fi

exit

