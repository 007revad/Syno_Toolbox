#!/usr/bin/env bash
#----------------------------------------------------------
# Enable or disable Synology reset button
# https://github.com/007revad/Synology_toggle_reset_button
#----------------------------------------------------------

version="1.0.1"

# Check that script is running as root
if [[ $( whoami ) != "root" ]]; then
	echo -e "\nERROR: This script must be run as root or sudo!\n"
	exit 1
fi

if [[ -n $1 ]]; then
    case "${1,,}" in
        disable|-disable|--disable)
            mode="disable"
            ;;
        enable|-enable|--enable)
            mode="enable"
            ;;
        check|-check|--check)
            mode="check"
            ;;
        *)
            echo -e "Invalid option '$1'\n"
            ;;
    esac
fi

if [[ $mode == "enable" ]]; then
    synosetkeyvalue /etc/synoinfo.conf reset_button_disable no
elif [[ $mode == "disable" ]]; then
    synosetkeyvalue /etc/synoinfo.conf reset_button_disable yes
fi

# Show reset_button_disable state
setting=$(synogetkeyvalue /etc/synoinfo.conf reset_button_disable)

if [[ $setting == "yes" ]]; then
    echo -e "Reset Button is disabled\n"
elif [[ $setting == "no" ]]; then
    echo -e "Reset Button is enabled\n"
elif [[ -z $setting ]]; then
    echo -e "Reset Button is enabled (default)\n"
fi

