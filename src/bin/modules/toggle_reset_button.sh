#!/usr/bin/env bash
# shellcheck disable=SC2034
#----------------------------------------------------------
# Enable or disable Synology reset button
# https://github.com/007revad/Synology_toggle_reset_button
#----------------------------------------------------------

scriptver="1.0.1-toolbox"

# Check that script is running as root
if [[ $( whoami ) != "root" ]]; then
	echo -e "Error: This script must be run as root or sudo!"
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
            echo -e "Invalid option '$1'"
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
    echo -e "Reset Button is disabled"
elif [[ $setting == "no" ]]; then
    echo -e "Reset Button is enabled"
elif [[ -z $setting ]]; then
    echo -e "Reset Button is enabled (default)"
fi

