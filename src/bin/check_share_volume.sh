#!/usr/bin/env bash
# shellcheck disable=SC2034
#------------------------------------------------------------
# Check which volume a shared folder is currently located on
#------------------------------------------------------------

if [[ $1 ]]; then
    bakpath="$1"
else
    exit 1
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

echo "${volshare:?}/$subfolder"
