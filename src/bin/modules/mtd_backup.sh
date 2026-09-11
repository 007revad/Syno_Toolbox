#!/usr/bin/env bash
# shellcheck disable=SC2034
#------------------------------------------------------------------------------
# Back up onboard MTD flash (RedBoot/zImage/rd.gz/vendor/FIS directory) on
# DS218-class NAS models that boot from raw NAND/NOR flash instead of a
# USB DOM, so you can recover from a corrupt/dying flash chip.
#
# Sibling to synoboot_backup.sh, not a replacement - synoboot_backup.sh
# handles /dev/synoboot* (USB DOM models), this handles /proc/mtd +
# /dev/mtdblockN (onboard flash models). A NAS only ever has one or the
# other, never both.
#
# Verified against real DS218 hardware 2026-09-09: all five partitions
# read identically across two consecutive reads (matching size and
# md5sum), confirming reliable/repeatable reads via mtdblockN. Content
# at partition start looks structurally sane for what each is meant to
# hold (RedBoot magic 0xd00dfeed, FIS directory starts with literal
# "RedBoot" string). zImage/rd.gz partitions are NOT plain
# uncompressed-zImage/gzip format on this board - they start with a
# raw LZMA stream header (0x5d property byte + 4-byte dict size + 8
# bytes of 0xff), decompressed directly by RedBoot rather than via the
# standard self-extracting zImage mechanism. This script does not
# attempt to validate that content beyond size/checksum - it's a raw
# flash dump either way.
#
# To run in a shell (replace /volume1/scripts/ with path to script):
# sudo -s /volume1/scripts/mtd_backup.sh
#------------------------------------------------------------------------------

PKG_NAME="Syno_Toolbox"
PKG_ROOT="/var/packages/${PKG_NAME}"

if [[ "$1" == "check" ]]; then
    check=yes
fi

dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="${PKG_ROOT}/var"
else
    VAR_DIR="${PKG_ROOT}/etc"
fi
TOOLBOX_CONF="${VAR_DIR}/toolbox.conf"
TOOLBOX_LOG="${VAR_DIR}/toolbox.log"

# Set bakpath to suit the location to backup to
#bakpath=/volume1/backups/mtd
bakpath="$(/usr/syno/bin/synogetkeyvalue $TOOLBOX_CONF mtd_backup_path)"

# Get volume $backupshare is currently located on
backupshare=$(echo -n "$bakpath" | cut -d"/" -f3)
buildnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber)
if [[ $buildnumber -gt "64570" ]]; then
    # DSM 7.2.1 and later
    # synoshare --get-real-path is case insensitive
    vol=$(/usr/syno/sbin/synoshare --get-real-path "$backupshare")
else
    # DSM 7.2 and earlier
    # synoshare --getmap is case insensitive
    vol=$(/usr/syno/sbin/synoshare --getmap "$backupshare" | grep volume | cut -d"[" -f2 | cut -d"]" -f1)
    # I could also have used:
    # vol=$(/usr/syno/sbin/synoshare --get "$backupshare" | tr '[]' '\n' | sed -n "9p")
fi
# Set current volume where shared folder is located
#if [[ ! $vol =~ $bakpath ]]; then
#    
#fi

scriptver="v1.0.0-toolbox"
script=mtd_backup

# Shell Colors
##Black='\e[0;30m'   # ${Black}
##Red='\e[0;31m'     # ${Red}
##Green='\e[0;32m'   # ${Green}
##Yellow='\e[0;33m'   # ${Yellow}
##Blue='\e[0;34m'    # ${Blue}
##Purple='\e[0;35m'  # ${Purple}
#Cyan='\e[0;36m'     # ${Cyan}
##White='\e[0;37m'   # ${White}
#Error='\e[41m'      # ${Error}
#Off='\e[0m'         # ${Off}

Cyan=""
Error=""
Off=""

# Show script version
#echo -e "$script $scriptver\ngithub.com/$repo\n"
#echo "$script $scriptver"

#ding(){ 
#    printf \\a
#}

# Check script is running as root
if [[ $(whoami) != "root" ]]; then
    #ding
    echo -e "${Error}Error:${Off} This script must be run as sudo or root!" |& tee -a "$TOOLBOX_LOG"
    exit 1
fi

# Check script is running on a Synology NAS
if ! uname -a | grep -i synology >/dev/null; then
    #ding
    echo -e "${Error}Error:${Off} This script is NOT running on a Synology NAS!" |& tee -a "$TOOLBOX_LOG"
    echo -e "Copy the script to a folder on the Synology and run it from there." >> "$TOOLBOX_LOG"
    exit 1  # Not a Synology NAS
fi


# Get NAS model
model=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf upnpmodelname 2>/dev/null)
# Fallback for systems where upnpmodelname is unavailable
if [[ -z "$model" && -f /proc/sys/kernel/syno_hw_version ]]; then
    model=$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null || echo "")
    # Check for dodgy characters after model number
    if [[ ${model,,} =~ 'pv10-j'$ ]]; then  # GitHub issue #10
        model=${model%??????}+              # replace last 6 chars with +
    elif [[ ${model} =~ '-j'$ ]]; then      # GitHub issue #2
        model=${model%??}                   # remove last 2 chars
    fi
fi
if [[ -z "$model" ]]; then
    model="Unknown_model"
fi

# Get serial number
serial=$(cat /proc/sys/kernel/syno_serial)

# Get DSM full version
productversion=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION productversion)
buildphase=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildphase)
buildnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber)
smallfixnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION smallfixnumber)
#majorversion=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)

# Show DSM full version and model
if [[ $buildphase == GM ]]; then buildphase=""; fi
if [[ $smallfixnumber -gt "0" ]]; then smallfix="-U$smallfixnumber"; fi
echo -e "$model DSM $productversion-$buildnumber$smallfix $buildphase" >> "$TOOLBOX_LOG"

echo -e "Backup path: ${bakpath}" >> "$TOOLBOX_LOG"


# Check NAS has /proc/mtd (onboard flash models only - USB DOM models
# should use synoboot_backup.sh instead, they won't have this)
if [[ ! -f /proc/mtd ]]; then
    #ding
    echo -e "${Error}Error:${Off} /proc/mtd not found!" >> "$TOOLBOX_LOG"
    echo -e "This model has no onboard MTD flash. Use Backup Synoboot Image instead." |& tee -a "$TOOLBOX_LOG"
    exit
fi

# Check backup folder exists
if [[ ! -d $bakpath ]]; then
    #ding
    echo -e "${Error}Error:${Off} Backup path not found: ${bakpath}" |& tee -a "$TOOLBOX_LOG"
    exit 1
fi

# Base filename prefix shared by every partition backup and the full image
baseprefix="${model}_${serial}_${productversion}-${buildnumber}${smallfix}"

if [[ "$check" == "yes" ]]; then
    for n in _mtd_full _mtd0_redboot _mtd1_zimage _mtd2_rdgz _mtd3_vendor _mtd4_fis_directory; do
        file_name="${baseprefix}${n}.img"
        if [[ -f "${bakpath}/$file_name" ]]; then
            echo -e "$file_name already backed up" |& tee -a "$TOOLBOX_LOG"
        else
            echo -e "$file_name not backed up" |& tee -a "$TOOLBOX_LOG"
        fi
    done
    exit
fi

# concat_parts collects the mtdblockN device paths in /proc/mtd order,
# so we can optionally cat them together into one full-chip image after
# the per-partition loop.
concat_parts=()

# Parse /proc/mtd, skipping the header line. Each line looks like:
#   mtd0: 00100000 00001000 "RedBoot"
while IFS= read -r line; do
    [[ "$line" =~ ^mtd([0-9]+):\ +([0-9a-fA-F]+)\ +([0-9a-fA-F]+)\ +\"(.*)\"$ ]] || continue
    idx="${BASH_REMATCH[1]}"
    label="${BASH_REMATCH[4]}"
    dev="/dev/mtdblock${idx}"

    # Sanitize label for use in a filename, e.g. "FIS directory" -> fis_directory
    safe_label=$(echo -n "$label" | tr '[:upper:] ' '[:lower:]_' | tr -cd '[:alnum:]_')

    if [[ ! -e "$dev" ]]; then
        echo -e "${Error}Error:${Off} $dev not found - skipping mtd${idx} \"${label}\"" |& tee -a "$TOOLBOX_LOG"
        continue
    fi

    concat_parts+=("$dev")

    imgname="${baseprefix}_mtd${idx}_${safe_label}"

    if [[ ! -f "${bakpath}/${imgname}.img" ]]; then
        echo -e "Backing up ${Cyan}${imgname}.img${Off} (mtd${idx} \"${label}\")" |& tee -a "$TOOLBOX_LOG"
        dd if="$dev" of="${bakpath:?}/${imgname:?}".img
        echo "" |& tee -a "$TOOLBOX_LOG"
    else
        echo -e "mtd${idx} \"${label}\" backup already exists: \n${imgname}.img" |& tee -a "$TOOLBOX_LOG"
    fi
done < /proc/mtd


# Also back up the whole chip as one concatenated image, in /proc/mtd
# order. Relies on the partitions being contiguous across the chip in
# that order - true for every DS218-class /proc/mtd layout seen so far,
# but worth spot-checking against a fresh model before trusting this
# blindly on hardware that hasn't been tested yet.
fullimgname="${baseprefix}_mtd_full"

if [[ ${#concat_parts[@]} -gt 0 ]]; then
    if [[ ! -f "${bakpath}/${fullimgname}.img" ]]; then
        echo -e "Backing up ${Cyan}${fullimgname}.img${Off} (full chip, ${#concat_parts[@]} partitions concatenated)" |& tee -a "$TOOLBOX_LOG"
        cat "${concat_parts[@]}" >> "${bakpath:?}/${fullimgname:?}".img
        echo "" |& tee -a "$TOOLBOX_LOG"
    else
        echo -e "Full chip backup already exists: \n${fullimgname}.img" |& tee -a "$TOOLBOX_LOG"
    fi
fi

#echo -e "\nFinished\n"

exit
