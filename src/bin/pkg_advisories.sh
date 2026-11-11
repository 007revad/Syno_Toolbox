#!/bin/bash
# shellcheck shell=bash
#------------------------------------------------------------------------------
# pkg_advisories.sh - security advisory data for pkg_updates.sh
#
# SOURCED by pkg_updates.sh (never run directly). Because pkg_updates.sh runs
# as root, keep this file in bin/ next to conf_lib.sh so tb_self_heal
# (synotoolbox_api.sh) locks it to root:root 555 like the other scripts.
#
# Uses $BUILD and $ENTERPRISE, which pkg_updates.sh sets before sourcing this.
#
# To add a new advisory (e.g. Node2Shell, Synology-SA-26:15):
#   1. Add an entry to ADVISORIES below:  "<function_prefix>:<Vulnerability name>"
#   2. Write <function_prefix>_packages  - prints the package ids to check, one per line
#   3. Write <function_prefix>_fixed     - takes a package id and prints
#         the fixed version for this DSM version,
#         "none" if no fix will be provided (end of life),
#         or nothing if the package isn't affected on this DSM version
#------------------------------------------------------------------------------

# One entry per advisory: "<function_prefix>:<name shown in the Vulnerability column>"
ADVISORIES=(
    "php2shell:PHP2Shell"
    "node2shell:Node2Shell"
    "plex2shell:Plex2Shell"
)

#------------------------------------------------------------------------------
# PHP2Shell (Synology-SA-26:14)
# https://www.synology.com/en-global/security/advisory/Synology_SA_26_14
# Plex2Shell (Synology-SA-26:17)
# https://www.synology.com/en-global/security/advisory/Synology_SA_26_17
# https://www.synology.com/en-global/security/advisory
#------------------------------------------------------------------------------

php2shell_packages() {
    printf '%s\n' Calendar MailStation PHP7.3 PHP7.4 PHP8.0 PHP8.1 PHP8.2 PHP8.3 PHP8.4
}

php2shell_fixed() {
    case "$1" in
        Calendar)
            if   [[ "$BUILD" -ge 64570 ]]; then echo "3.0.4-21435"  # DSM 7.2 and later
            elif [[ "$BUILD" -ge 41890 ]]; then echo "2.4.8-10948"  # DSM 7.0 to 7.1
            elif [[ "$BUILD" -ge 24922 ]]; then echo "2.4.8-0948"   # DSM 6.2.2 to 6.2.4
            fi ;;
        MailStation)
            if   [[ "$BUILD" -ge 60000 ]]; then echo "30000002.3.19-20333"  # DSM 7.2 and later
            elif [[ "$BUILD" -ge 41805 ]]; then echo "30000002.3.19-10333"  # DSM 7.0 to 7.1
            elif [[ "$BUILD" -ge 24922 ]]; then echo "30000002.3.19-0333"   # DSM 6.2.2 to 6.2.4
            fi ;;
        PHP7.3)      echo "none" ;;  # End of life
        PHP7.4)
            if   [[ "$BUILD" -ge 60096 ]]; then echo "7.4.33-0131"  # DSM 7.2 and later
            elif [[ "$BUILD" -ge 41300 ]]; then echo "7.4.33-0122"  # DSM 7.0 to 7.1
            elif [[ "$BUILD" -ge 22232 ]]; then echo "7.4.33-0010"  # DSM 6.2 to 6.2.4
            fi ;;
        PHP8.0)
            if   [[ "$BUILD" -ge 60096 ]]; then echo "8.0.30-0122"  # DSM 7.2 and later
            elif [[ "$BUILD" -ge 41300 ]]; then echo "8.0.30-0104"  # DSM 7.0 to 7.1
            fi ;;
        PHP8.1) echo "8.1.34-0120" ;;  # DSM 7.2-60096 and later
        PHP8.2)
            if [[ "$ENTERPRISE" == "yes" ]]; then echo "8.2.35-0134"  # DSM Enterprise
            elif   [[ "$BUILD" -ge 60096 ]]; then echo "8.2.35-0171"  # DSM 7.2 and later
            fi ;;
        PHP8.3) echo "8.3.36-0051" ;;  # DSM 7.2-60096 and later
        PHP8.4) echo "8.4.27-0051" ;;  # DSM 7.2-60096 and later
    esac
}


#------------------------------------------------------------------------------
# Node2Shell (Synology-SA-26:15)
# https://www.synology.com/en-global/security/advisory/Synology_SA_26_15
#------------------------------------------------------------------------------

#node2shell_packages() {
#    printf '%s\n' Chat
#}

#node2shell_fixed() {
#    case "$1" in
#        Chat)
#            echo "1.2.5-0240"  # Chat Client - Chat Server
#    esac
#}


#------------------------------------------------------------------------------
# Plex2Shell (Synology-SA-26:17)
# https://www.synology.com/en-global/security/advisory/Synology_SA_26_17
# https://www.synology.com/en-global/security/advisory
#------------------------------------------------------------------------------

plex2shell_packages() {
    printf '%s\n' PlexMediaServer "Plex Media Server"
}

plex2shell_fixed() {
    case "$1" in
        PlexMediaServer)
            if   [[ "$BUILD" -ge 81180 ]]; then echo "1.43.5.11079-720011079"  # DSM 7.3 and above
            elif [[ "$BUILD" -ge 64890 ]]; then echo "1.43.5.11079-700011079"  # DSM 7.0, 7.1 and 7.2
            fi ;;
        "Plex Media Server")
            if   [[ "$BUILD" -ge 7321 ]]; then echo "1.43.5.11079-b3b13e506"  # DSM 6.0 to 6.2.4
            fi ;;
    esac
}


