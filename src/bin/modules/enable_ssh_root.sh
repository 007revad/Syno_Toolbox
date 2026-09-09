#!/bin/bash
# Enable SSH root access

scriptname="enable_ssh_root"
scriptver="1.0.1-toolbox"

# Check running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "ERROR This script must be run as sudo!"
    exit 1
fi

# Check script is running on a Synology NAS
if ! /usr/bin/uname -a | grep -i synology >/dev/null; then
    echo "This script is NOT running on a Synology NAS!"
    echo "Copy the script to a folder on the Synology"
    echo "and run it from there."
    exit 1  # Not a Synology NAS
fi

# Check for flags with getopt
if options="$(getopt -o "" -l pwd,check,disable -- "$@")"; then
    eval set -- "$options"
    while true; do
        case "${1,,}" in
            --pwd)
                read -rs pwd
                ;;
            --check)            # Show if SSH root enabled
                check="yes"
                ;;
            --disable)
                disable="yes"
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

# Get DSM major version
dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)

# Check if root SSH enabled
if [[ "$check" == "yes" ]]; then
    if grep -qE '^PermitRootLogin yes' /etc/ssh/sshd_config; then
        echo "SSH root login is enabled"
    else
        echo "SSH root login is not enabled"
    fi

    # Check if SSH is enabled
    if [[ $dsm -gt "6" ]]; then
        # DSM 7
        enabled=$(synowebapi --exec api="SYNO.Core.Terminal" method="get" version="2" 2>/dev/null | grep -oE '"enable_ssh"[[:space:]]*:[[:space:]]*(true|false)' | grep -oE '(true|false)')
        if [[ "$enabled" == "true" ]]; then
            echo "SSH is enabled"
        else
            echo "SSH is not enabled"
        fi
    else
        # DSM 6 or older
        if /usr/syno/sbin/synoservice --status ssh-shell >/dev/null 2>&1; then
            echo "SSH is enabled"
        else
            echo "SSH is not enabled"
        fi
    fi
    exit 0
fi

# Disable root SSH login
if [[ "$disable" == "yes" ]]; then
    if grep -qE '^PermitRootLogin yes$' /etc/ssh/sshd_config; then
        echo "Reverting /etc/ssh/sshd_config"
        if sed -i '/^PermitRootLogin yes$/d' /etc/ssh/sshd_config; then
            echo "Successfully removed 'PermitRootLogin yes'"
            if [[ $dsm -gt "6" ]]; then
                /usr/syno/bin/synosystemctl restart sshd.service
            else
                setsid /usr/syno/sbin/synoservice --restart ssh-shell 2>&1 &
            fi
        else
            echo "ERROR Failed to edit /etc/ssh/sshd_config"
            exit 1
        fi
    else
        echo "/etc/ssh/sshd_config does not contain 'PermitRootLogin yes' (no change needed)"
    fi
    exit 0
fi

# Backup /etc/ssh/sshd_config
if ! [[ -f /etc/ssh/sshd_config.bak ]]; then
    echo "Backing up /etc/ssh/sshd_config"
    cp -p /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
fi

# Enable SSH if not enabled
if [[ $dsm -gt "6" ]]; then
    # DSM 7
    enabled=$(synowebapi --exec api="SYNO.Core.Terminal" method="get" version="2" 2>/dev/null | grep -oE '"enable_ssh"[[:space:]]*:[[:space:]]*(true|false)' | grep -oE '(true|false)')
    if [[ "$enabled" != "true" ]]; then
        echo "Enabling SSH"
        synowebapi --exec api="SYNO.Core.Terminal" method="set" version="2" enable_ssh=true
    fi
else
    # DSM 6 or older
    if ! /usr/syno/sbin/synoservice --status ssh-shell >/dev/null 2>&1; then
        echo "Enabling SSH"
        /usr/syno/sbin/synoservice --enable ssh-shell
    fi
fi


if [[ -t 1 ]] && [[ ! $pwd ]]; then  # Running in terminal
    # Prompt the user to enter the admin password and store it in the 'pwd' variable
    read -rs -p "Enter your admin password: " pwd
fi

# Set root password
if [[ ! $pwd ]]; then
    echo -e "ERROR Admin password missing!"
    exit 1
else
    echo "Setting root password"
    if /usr/syno/sbin/synouser --setpw root "$pwd"; then
        echo "Root password set successfully"
    else
        echo "ERROR Failed to set root password"
        exit 1
    fi
fi

# Check if "PermitRootLogin yes" is needed
if ! grep -qE '^PermitRootLogin yes' /etc/ssh/sshd_config; then
    echo "Editing /etc/ssh/sshd_config"
    if sed -i '/^#PermitRootLogin prohibit-password$/a PermitRootLogin yes' /etc/ssh/sshd_config; then
        #echo "Successfully edited /etc/ssh/sshd_config"
        echo "Successfully enabled SSH root login"
        restart_needed=yes
    else
        #echo "ERROR Failed to edit /etc/ssh/sshd_config"
        echo "ERROR Failed to enable SSH root login"
        exit 1
    fi
else
    #echo "/etc/ssh/sshd_config already contains 'PermitRootLogin yes'"
    echo "SSH root login is enabled"
fi

# Restart DSM 7 sshd.service or DSM 6 ssh-shell
if [[ "$restart_needed" == "yes" ]]; then
    if [[ $dsm -gt "6" ]]; then
        # DSM 7
        echo "Restarting sshd.service"
        /usr/syno/bin/synosystemctl restart sshd.service
    else
        # DSM 6 or older
        echo "Restarting ssh-shell"
        setsid /usr/syno/sbin/synoservice --restart ssh-shell 2>&1 &
    fi
fi

