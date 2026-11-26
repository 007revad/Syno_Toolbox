#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Enables Secure Erase in Storage Manager for drives in expansion units.
#
# DRAFT - only tested by hand erasing a drive in a DX213 on a DS720+ (DSM 7.4.1)
# and on a NAS running DSM 6.2.4. Only x86-64 models are supported.
#
# DSM 7 - it makes 2 edits:
#   1. storage_panel.js (Storage Manager UI) so the UI offers Secure Erase
#      for drives in expansion units.
#   2. /usr/lib/libsynostoragemgmt.so so DSM's backend accepts the request.
#
# DSM 6 - it only edits storage.js (and storage.js.gz) so the UI offers
# Secure Erase for drives in expansion units.
#
# While a secure erase is running Storage Manager, and the System Health and
# Storage widgets, may stop responding (DSM 6 shows "Connection failed").
# They recover when the secure erase finishes. Don't reboot while it runs.
#
# DSM updates will undo the edits. Run the script again after updating DSM.
#
# To run in a shell (replace /volume1/scripts/ with path to script):
# sudo /volume1/scripts/syno_eunit_secure_erase.sh
#-------------------------------------------------------------------------------

scriptver="v1.0.0-toolbox"
script=syno_eunit_secure_erase

# Get location of script
scriptpath="$(realpath "$0")"

if [[ $scriptpath =~ Syno_Toolbox ]]; then
    is_toolbox=yes
fi

PKG_NAME="Syno_Toolbox"
PKG_ROOT="/var/packages/${PKG_NAME}"

dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="${PKG_ROOT}/var"
else
    VAR_DIR="${PKG_ROOT}/etc"
fi
LOG_FILE="${VAR_DIR}/eunit_secure_erase.log"

log() { 
    if [[ $is_toolbox == yes ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
    fi
}

if [[ $dsm -eq 6 ]]; then
    echo "Not available for DSM 6 yet"
    exit 0
fi

# Prevent Entware or user edited PATH causing issues
# shellcheck disable=SC2155  # Declare and assign separately to avoid masking return values
export PATH=$(echo "$PATH" | sed -e 's/\/opt\/bin:\/opt\/sbin://')

# Check BASH variable is bash
if [ ! "$(basename "$BASH")" = bash ]; then
    log "This is a bash script. Do not run it with $(basename "$BASH")"
    echo "This is a bash script. Do not run it with $(basename "$BASH")"
    exit 1
fi

# Check script is running on a Synology NAS
if ! /usr/bin/uname -a | grep -i synology >/dev/null; then
    log "This script is NOT running on a Synology NAS!"
    echo "This script is NOT running on a Synology NAS!"
    echo "Copy the script to a folder on the Synology and run it from there."
    exit 1
fi

usage(){
    cat <<EOF
$script $scriptver - by 007revad

Usage: $(basename "$0") [options]

Options:
  -c, --check           Check if the files are edited
  -r, --restore         Undo all changes made by the script
  -f, --force           Edit files even if the NAS has no eSATA expansion port
  -h, --help            Show this help message
  -v, --version         Show the script version

EOF
    exit 0
}


scriptversion(){
    cat <<EOF
$script $scriptver - by 007revad
EOF
    exit 0
}


# Save options used
args=("$@")


# Check for flags with getopt
if options="$(getopt -o abcdefghijklmnopqrstuvwxyz0123456789 -l \
    check,restore,force,help,version,log,debug -- "$@")"; then
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
                #log=yes
                ;;
            -d|--debug)         # Show and log debug info
                debug=yes
                ;;
            -c|--check)         # Check if files are edited
                check=yes
                ;;
            -r|--restore)       # Restore from backups to undo changes
                restore=yes
                ;;
            -f|--force)         # Edit files even if no eSATA port found
                force=yes
                ;;
            --)
                shift
                break
                ;;
            *)                  # Show usage options
                echo "Invalid option '$1'"
                usage "$1"
                ;;
        esac
        shift
    done
#else
#    echo
#    usage
fi


if [[ $debug == "yes" ]]; then
    set -x
    export PS4='`[[ $? == 0 ]] || echo "\e[1;31;40m($?)\e[m\n "`:.$LINENO:'
fi


# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    log "Error: This script must be run as sudo or root!"
    echo "Error: This script must be run as sudo or root!"
    exit 1
fi

if [[ $dsm -lt "6" ]]; then
    log "This script only works for DSM 6 and 7."
    echo "This script only works for DSM 6 and 7."
    exit 1
fi
if [[ $dsm -eq "6" ]]; then dsm6=yes; fi

# Get Synology model
model=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf upnpmodelname)
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

# Show script version
if [[ $is_toolbox != yes ]]; then
    echo "$script $scriptver"
fi

# Get DSM full version
productversion=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION productversion)
buildphase=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildphase)
buildnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber)
smallfixnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION smallfixnumber)

# Show DSM full version and model
if [[ $buildphase == GM ]]; then buildphase=""; fi
if [[ $smallfixnumber -gt "0" ]]; then smallfix="-$smallfixnumber"; fi
if [[ $is_toolbox != yes ]]; then
    echo -e "$model DSM $productversion-$buildnumber$smallfix $buildphase\n"
fi

# Get StorageManager version
storagemgrver=$(/usr/syno/bin/synopkg version StorageManager)
# Show StorageManager version
if [[ $is_toolbox != yes ]]; then
    if [[ $storagemgrver ]]; then echo -e "StorageManager $storagemgrver \n"; fi
fi

# Show options used
if [[ ${#args[@]} -gt "0" ]] && [[ $is_toolbox != yes ]]; then
    echo -e "Using options: ${args[*]}"
fi


# DSM 6 only needs sed and grep. DSM 7 needs python3.
if [[ $dsm6 != "yes" ]] && ! command -v python3 >/dev/null 2>&1; then
    log "Error: python3 not found!"
    echo "Error: python3 not found!"
    exit 1
fi


#------------------------------------------------------------------------------
# Set file variables

libsm="/usr/lib/libsynostoragemgmt.so"

if [[ $buildnumber -gt 64570 ]]; then
    # DSM 7.2.1 and later (Storage Manager is a package)
    strgmgr="/usr/local/packages/@appstore/StorageManager/ui/storage_panel.js"
elif [[ $buildnumber -gt 41890 ]]; then
    # DSM 7.0 to 7.2 (Storage Manager is built-in)
    strgmgr="/usr/syno/synoman/webman/modules/StorageManager/storage_panel.js"
else
    # DSM 6 (Storage Manager is built-in)
    # In DSM 6 we edit storage.js instead of storage_panel.js
    strgmgr="/usr/syno/synoman/webman/modules/StorageManager/storage.js"
fi

# If storage_panel.js is not where we expect, try the other location
if [[ ! -f $strgmgr ]]; then
    for alt in \
        "/usr/local/packages/@appstore/StorageManager/ui/storage_panel.js" \
        "/usr/syno/synoman/webman/modules/StorageManager/storage_panel.js"; do
        if [[ -f $alt ]]; then strgmgr="$alt"; break; fi
    done
fi

# Backups of storage_panel.js are named per Storage Manager version
# (built-in Storage Manager has no package version so use the DSM build number)
sgver="${storagemgrver:-$buildnumber}"
strgmgrbak="${strgmgr}.${sgver}.eunit_erase_bak"

if [[ $dsm6 != "yes" ]] && [[ ! -f $libsm ]]; then
    log "Error: $(basename -- "$libsm") not found!"
    echo "Error: $(basename -- "$libsm") not found!"
    exit 1
fi
if [[ ! -f $strgmgr ]]; then
    log "Error: $(basename -- "$strgmgr") not found!"
    echo "Error: $(basename -- "$strgmgr") not found!"
    exit 1
fi


#------------------------------------------------------------------------------
# Python helpers
#
# Both return: 0 = patched (or patched successfully)
#              1 = not patched (or already patched, in patch mode)
#              2 = error (pattern not found, ambiguous match, unsupported build)

# $1 = file, $2 = mode: "check" or "patch" (patch edits $1 in place)
libsm_action_run(){
    python3 -I - "$1" "$2" <<'PYEOF'
import re
import struct
import sys

SYMBOL = "SYNODiskIsSupportErase"
LOGSTR = b"does NOT support secure erase"
NOPS = b"\x90" * 6


def die(msg):
    print(f"\nError: {msg}", file=sys.stderr)
    sys.exit(2)


def parse(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2:
        die("not a 64-bit ELF file")
    if struct.unpack_from("<H", data, 0x12)[0] != 62:
        die("not an x86-64 file (only x86-64 builds are supported)")
    phoff = struct.unpack_from("<Q", data, 0x20)[0]
    phentsz = struct.unpack_from("<H", data, 0x36)[0]
    phnum = struct.unpack_from("<H", data, 0x38)[0]
    segs = []  # (offset, vaddr, filesz, flags)
    dyn = None
    for i in range(phnum):
        p_type, p_flags, p_off, p_va, _pa, p_fsz, _msz, _al = struct.unpack_from(
            "<IIQQQQQQ", data, phoff + i * phentsz)
        if p_type == 1:
            segs.append((p_off, p_va, p_fsz, p_flags))
        elif p_type == 2:
            dyn = (p_off, p_fsz)
    if dyn is None:
        die("no PT_DYNAMIC segment found")
    tags = {}
    for pos in range(dyn[0], dyn[0] + dyn[1], 16):
        tag, val = struct.unpack_from("<qQ", data, pos)
        if tag == 0:
            break
        tags.setdefault(tag, val)
    for tag in (2, 5, 6, 23):
        if tag not in tags:
            die(f"required DT_* tag {tag} missing from dynamic section")
    return data, segs, tags


def v2o(segs, va):
    for off, sva, fsz, _fl in segs:
        if sva <= va < sva + fsz:
            return off + va - sva
    return None


def cstr(data, off):
    return data[off:data.index(b"\0", off)]


def plt_got_for_symbol(data, segs, tags):
    """Return the set of GOT slot addresses that belong to SYMBOL."""
    symtab = v2o(segs, tags[6])
    strtab = v2o(segs, tags[5])
    rela = v2o(segs, tags[23])
    slots = set()
    for i in range(0, tags[2], 24):
        r_off, r_info, _add = struct.unpack_from("<QQq", data, rela + i)
        st_name = struct.unpack_from("<I", data, symtab + (r_info >> 32) * 24)[0]
        if cstr(data, strtab + st_name) == SYMBOL.encode():
            slots.add(r_off)
    if not slots:
        die(f"{SYMBOL} is not imported through the PLT in this file")
    return slots


def find_sites(path):
    """Find calls to SYMBOL followed by test eax,eax and a je (or 6 NOPs)."""
    data, segs, tags = parse(path)
    slots = plt_got_for_symbol(data, segs, tags)
    pat = re.compile(rb"\xe8(....)\x85\xc0(?:\x0f\x84(....)|(\x90{6}))", re.S)
    sites = []
    for off, va, fsz, fl in segs:
        if not fl & 1:  # executable segments only
            continue
        pos = off
        end = off + fsz
        while True:
            m = pat.search(data, pos, end)
            if not m:
                break
            pos = m.start() + 1
            call_va = va + m.start() - off
            tgt = call_va + 5 + struct.unpack("<i", m.group(1))[0]
            tof = v2o(segs, tgt)
            if tof is None:
                continue
            stub = data[tof:tof + 16]
            k = stub.find(b"\xff\x25")
            if k < 0 or k > 6:
                continue
            got = tgt + k + 6 + struct.unpack("<i", stub[k + 2:k + 6])[0]
            if got not in slots:
                continue
            je_off = m.start() + 7
            je_va = call_va + 7
            jtgt = None
            if m.group(2) is not None:
                jtgt = je_va + 6 + struct.unpack("<i", m.group(2))[0]
            sites.append((je_off, jtgt))
    return data, segs, sites


def refusal_block_ok(data, segs, jtgt):
    """The je must land on a block that loads the 'does NOT support' string."""
    i = data.find(LOGSTR)
    if i < 0:
        return False
    start = data.rfind(b"\0", 0, i) + 1
    str_va = None
    for off, sva, fsz, _fl in segs:
        if off <= start < off + fsz:
            str_va = sva + start - off
    if str_va is None:
        return False
    tof = v2o(segs, jtgt)
    if tof is None:
        return False
    blk = data[tof:tof + 0x80]
    for m in re.finditer(rb"\x48\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d](....)", blk, re.S):
        lea_va = jtgt + m.start() + 7 + struct.unpack("<i", m.group(1))[0]
        if lea_va == str_va:
            return True
    return False


def main():
    path, mode = sys.argv[1], sys.argv[2]
    data, segs, sites = find_sites(path)
    if len(sites) != 1:
        die(f"expected exactly 1 call site of {SYMBOL}, found {len(sites)} "
            f"- this DSM build is not supported")
    je_off, jtgt = sites[0]
    patched = data[je_off:je_off + 6] == NOPS
    if not patched:
        if data[je_off:je_off + 2] != b"\x0f\x84":
            die("unexpected bytes at patch site")
        if not refusal_block_ok(data, segs, jtgt):
            die("the jump does not lead to the 'does NOT support secure erase' "
                "block - this DSM build is not supported")
    if mode == "check":
        if patched:
            print(f"Already patched at file offset 0x{je_off:x}")
            sys.exit(0)
        print(f"Not patched - original bytes found at file offset 0x{je_off:x}")
        sys.exit(1)
    # mode == "patch"
    if patched:
        print(f"Already patched at file offset 0x{je_off:x}")
        sys.exit(1)
    with open(path, "r+b") as f:
        f.seek(je_off)
        f.write(NOPS)
    print(f"Patched 0x{je_off:x}: {data[je_off:je_off + 6].hex()} -> {NOPS.hex()}")
    sys.exit(0)


main()
PYEOF
    return $?
}

# DSM 6 storage.js. The gate is:
#   if(!a.appWin.supportSas&&("ebox"===b.get("container").type)){...disk_cant_erase_eunit...}
# $1 = file, $2 = mode: "check" or "patch" (patch edits $1 in place)
# Returns the same codes as the python helpers.
strgmgr6_action(){
    local f="$1" mode="$2" orig patched n_orig n_patched
    orig='!a.appWin.supportSas&&("ebox"===b.get("container").type)'
    patched='if(!1){Ext.getCmp(a.secureEraseId).disable();d=_T("disk_info","disk_cant_erase_eunit")'
    n_orig=$(grep -oF "$orig" "$f" | wc -l)
    n_patched=$(grep -oF "$patched" "$f" | wc -l)

    if [[ $((n_orig + n_patched)) -ne 1 ]]; then
        log "Error: expected exactly 1 secure erase gate, found"\
            "$n_orig unpatched and $n_patched patched - this Storage Manager"\
            "version is not supported" >&2
        echo "Error: expected exactly 1 secure erase gate, found"\
            "$n_orig unpatched and $n_patched patched - this Storage Manager"\
            "version is not supported" >&2
        return 2
    fi

    if [[ $mode == "check" ]]; then
        if [[ $n_patched -eq 1 ]]; then
            log "Already patched"
            echo "Already patched"
            return 0
        fi
        log "Not patched"
        echo "Not patched"
        return 1
    fi

    if [[ $n_patched -eq 1 ]]; then
        log "Already patched"
        echo "Already patched"
        return 1
    fi

    sed -i 's/!a\.appWin\.supportSas&&("ebox"===b\.get("container")\.type)/!1/' "$f"
    if [[ $(grep -oF "$patched" "$f" | wc -l) -eq 1 ]]; then
        log "Patched secure erase gate"
        echo "Patched secure erase gate"
        return 0
    fi
    return 2
}

# $1 = file, $2 = mode: "check" or "patch" (patch edits $1 in place)
strgmgr_action_run(){
    if [[ $dsm6 == "yes" ]]; then
        strgmgr6_action "$1" "$2"
        return $?
    fi
    python3 -I - "$1" "$2" <<'PYEOF'
import re
import sys

path, mode = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read()

# DSM's gate: only allow secure erase when the disk is NOT in an expansion unit
orig = re.compile(r'(SYNO\.SDS\.StorageUtils\.supportSas\|\|)"ebox"!==\w+\.container\.type')
done = 'SYNO.SDS.StorageUtils.supportSas||!0'

n_orig = len(orig.findall(text))
n_done = text.count(done)

if n_orig + n_done != 1:
    print(f"\nError: expected exactly 1 secure erase gate, found "
          f"{n_orig} unpatched and {n_done} patched - this Storage Manager "
          f"version is not supported", file=sys.stderr)
    sys.exit(2)

if mode == "check":
    if n_done:
        print("Already patched")
        sys.exit(0)
    print("Not patched")
    sys.exit(1)

if n_done:
    print("Already patched")
    sys.exit(1)

new = orig.sub(lambda m: m.group(1) + "!0", text, count=1)
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(new)
print("Patched secure erase gate")
sys.exit(0)
PYEOF
    return $?
}


# In Syno Toolbox the helpers' normal output is hidden so only errors show.
# Their errors go to stderr, so send stderr to stdout and drop stdout.
libsm_action(){
    if [[ $is_toolbox == yes ]]; then
        libsm_action_run "$@" 2>&1 >/dev/null
    else
        libsm_action_run "$@"
    fi
}

strgmgr_action(){
    if [[ $is_toolbox == yes ]]; then
        strgmgr_action_run "$@" 2>&1 >/dev/null
    else
        strgmgr_action_run "$@"
    fi
}


# Copy $1 over $2 using a new file then rename, so $2 gets a new inode and
# processes with the old file mapped keep running with the old contents.
swap_file(){
    # $1 is source, $2 is destination
    if cp -p "$1" "${2}.new" && mv -f "${2}.new" "$2"; then
        return 0
    else
        rm -f "${2}.new"
        return 1
    fi
}

regen_gz(){
    # Make sure storage_manager.js.gz includes our changes
    # storage.js.gz in DSM 6
    if [[ -f "${strgmgr}.gz" ]]; then
        gzip -c "${strgmgr}" > "${strgmgr}.gz"
    fi
}

reloadmsg(){
    echo -e "\nWARNING: You need to sign out of DSM and sign back in."
    #echo "so the browser loads the edited $(basename -- "$strgmgr")."
    #echo "You do not need to restart the Synology."
}


#------------------------------------------------------------------------------
# Check files

if [[ $check == "yes" ]]; then
    err=0
    libsmrc=0
    strgmgrrc=0

    if [[ $dsm6 != "yes" ]]; then
        log "Checking $(basename -- "$libsm")"
        if [[ -t 1 ]]; then  # Running in terminal
            echo "Checking $(basename -- "$libsm")"
        fi
        libsm_action "$libsm" check
        libsmrc=$?
        case $libsmrc in
            0|1) ;;
            *) err=1 ;;
        esac
        if [[ -f ${libsm}.bak ]]; then
            log "Checking $(basename -- "$libsm").bak"
            if [[ -t 1 ]]; then  # Running in terminal
                echo "Checking $(basename -- "$libsm").bak"
            fi
            if [[ $is_toolbox == yes ]]; then
                libsm_action "${libsm}.bak" check >/dev/null 2>&1
            else
                libsm_action "${libsm}.bak" check
            fi
            if [[ $? -eq 0 ]]; then
                log "Backup file has been edited!"
                echo "Error: $(basename -- "$libsm").bak has been edited!"
                err=1
            fi
        else
            log "No backup of $(basename -- "$libsm") found."
            if [[ -t 1 ]]; then  # Running in terminal
                echo "No backup of $(basename -- "$libsm") found."
            fi
        fi
    fi

    log "Checking $(basename -- "$strgmgr")"
    if [[ -t 1 ]]; then  # Running in terminal
        echo "Checking $(basename -- "$strgmgr")"
    fi
    strgmgr_action "$strgmgr" check
    strgmgrrc=$?
    case $strgmgrrc in
        0|1) ;;
        *) err=1 ;;
    esac
    if [[ ! -f $strgmgrbak ]]; then
        log "No backup of $(basename -- "$strgmgr") found for $sgver."
        if [[ -t 1 ]]; then  # Running in terminal
            echo "No backup of $(basename -- "$strgmgr") found for $sgver."
        fi
    fi

    # Only report the state if both files could be checked
    if [[ $libsmrc -le 1 ]] && [[ $strgmgrrc -le 1 ]]; then
        if [[ $libsmrc -eq 0 ]] && [[ $strgmgrrc -eq 0 ]]; then
            log "Secure Erase for expansion units enabled"
            echo "Secure Erase for expansion units enabled"
        else
            log "Secure Erase for expansion units not enabled"
            echo "Secure Erase for expansion units not enabled"
        fi
    fi

    exit "$err"
fi


#------------------------------------------------------------------------------
# Restore from backups

if [[ $restore == "yes" ]]; then
    if [[ $is_toolbox != yes ]]; then echo ""; fi
    restoreerr=0
    restored=""

    # Only restore libsynostoragemgmt.so if it is currently edited. Otherwise
    # (e.g. DSM was updated since) the backup could be from an older DSM build.
    libsmstate=1
    if [[ $dsm6 != "yes" ]]; then
        libsm_action "$libsm" check >/dev/null 2>&1
        libsmstate=$?
    fi

    # Restore libsynostoragemgmt.so
    if [[ $dsm6 == "yes" ]]; then
        :  # DSM 6 does not edit libsynostoragemgmt.so
    elif [[ $libsmstate -eq 1 ]]; then
        log "$(basename -- "$libsm") is not edited. Nothing to restore."
    elif [[ $libsmstate -ne 0 ]]; then
        restoreerr=1
        log "Error: Cannot check $(basename -- "$libsm"). This DSM build may not be supported."
        echo "Error: Cannot check $(basename -- "$libsm"). This DSM build may not be supported."
    elif [[ -f ${libsm}.bak ]]; then
        filesize=$(wc -c "${libsm}" | awk '{print $1}')
        filebaksize=$(wc -c "${libsm}.bak" | awk '{print $1}')
        answer=yes
        if [[ ! $filesize -eq "$filebaksize" ]]; then
            log "WARNING Backup file size is different to file!"
            if [[ -t 1 ]]; then  # Running in terminal
                echo "WARNING Backup file size is different to file!"
                echo "Do you want to restore this backup? [yes/no]:"
                read -r -t 20 answer
            fi
        fi
        if [[ $answer == "yes" ]]; then
            if ! cmp -s "${libsm}.bak" "$libsm"; then
                if swap_file "${libsm}.bak" "$libsm"; then
                    restored="yes"
                    log "Restored $(basename -- "$libsm")"
                    if [[ -t 1 ]]; then  # Running in terminal
                        echo "Restored $(basename -- "$libsm")"
                    fi
                else
                    restoreerr=1
                    log "Error: Failed to restore $(basename -- "$libsm")!"
                    echo "Error: Failed to restore $(basename -- "$libsm")!"
                fi
            fi
        fi
    else
        log "No backup of $(basename -- "$libsm") found."
        if [[ $is_toolbox != yes ]]; then
            echo "No backup of $(basename -- "$libsm") found."
        fi
    fi

    # Restore storage_panel.js (storage.js for DSM 6)
    if [[ -f $strgmgrbak ]]; then
        if ! cmp -s "$strgmgrbak" "$strgmgr"; then
            if cp -p "$strgmgrbak" "$strgmgr"; then
                regen_gz
                restored="yes"
                log "Restored $(basename -- "$strgmgr")"
                if [[ -t 1 ]]; then  # Running in terminal
                    echo "Restored $(basename -- "$strgmgr")"
                fi
            else
                restoreerr=1
                log "Error: Failed to restore $(basename -- "$strgmgr")!"
                echo "Error: Failed to restore $(basename -- "$strgmgr")!"
            fi
        fi
    else
        log "No backup of $(basename -- "$strgmgr") found for $sgver."
        if [[ $is_toolbox != yes ]]; then
            echo "No backup of $(basename -- "$strgmgr") found for $sgver."
        fi
    fi

    # In Syno Toolbox confirm the files really are back to original
    if [[ $is_toolbox == yes ]] && [[ $restoreerr -eq 0 ]]; then
        stilledited=""
        if [[ $dsm6 != "yes" ]]; then
            libsm_action "$libsm" check
            case $? in
                0) stilledited="$(basename -- "$libsm")" ;;
                1) ;;
                *) restoreerr=1 ;;
            esac
        fi
        strgmgr_action "$strgmgr" check
        case $? in
            0) stilledited="${stilledited:+$stilledited and }$(basename -- "$strgmgr")" ;;
            1) ;;
            *) restoreerr=1 ;;
        esac
        if [[ -n $stilledited ]]; then
            restoreerr=1
            log "Error: $stilledited is still edited and has no backup to restore."
            echo "Error: $stilledited is still edited and has no backup to restore."
        fi
    fi

    if [[ $restoreerr -eq 0 ]]; then
        if [[ $is_toolbox == yes ]]; then
            log "Secure Erase for expansion units has been disabled"
            echo "Secure Erase for expansion units has been disabled"
            if [[ $restored == "yes" ]]; then
                reloadmsg
            fi
        elif [[ $restored == "yes" ]]; then
            log "Restore successful."
            echo "Restore successful."
            reloadmsg
        else
            log "Nothing to restore."
            echo "Nothing to restore."
        fi
    fi
    exit "$restoreerr"
fi


#------------------------------------------------------------------------------
# Check the NAS has an eSATA, Infiniband or Min-SAS HD expansion port
#
# syno_slot_mapping (models that use a device tree blob) shows:
#   Esata port count: 1
# If syno_slot_mapping is not available we can't tell, so carry on.

# DSM models without syno_slot_mapping that Synology lists as supporting expansion units
# (Synology KB "Which Synology NAS model can I use with Synology Expansion Units?").
# Includes models that can only use expansion units for independent volumes.
dsm6models="DS1019+
DS112
DS112+
DS114
DS115
DS1511+
DS1512+
DS1513+
DS1515
DS1515+
DS1517
DS1517+
DS1618+
DS1621xs+
DS1812+
DS1813+
DS1815+
DS1817
DS1817+
DS1819+
DS2015xs
DS212+
DS213+
DS214+
DS214play
DS215+
DS216+
DS216+II
DS218+
DS2411+
DS2413+
DS2415+
DS2419+
DS2419+II
DS3018xs
DS3611xs
DS3612xs
DS3615xs
DS3617xs
DS3617xsII
DS412+
DS413
DS415+
DS712+
DS713+
DS715
DS716+
DS716+II
DS718+
DS916+
DS918+
DVA3219
DVA3221
FS1018
NVR1218
NVR216
RS10613xs+
RS1219+
RS214
RS217
RS2211+
RS2211RP+
RS2212+
RS2212RP+
RS2414+
RS2414RP+
RS2416+
RS2416RP+
RS3411RPxs
RS3411xs
RS3412RPxs
RS3412xs
RS3413xs+
RS3614RPxs
RS3614xs
RS3614xs+
RS3617RPxs
RS3617xs
RS3617xs+
RS3618xs
RS812
RS812+
RS812RP+
RS814
RS814+
RS814RP+
RS815
RS815+
RS815RP+
RS816
RS818+
RS818RP+
RS819
RS820+
RS820RP+
RS1619xs+
RS2418+
RS2418RP+
RS2818RP+
RS4017xs+"

# DSM 6 Secure Erase in RS1619xs+, RS2418+, RS2418RP+, RS2818RP+ and RS4017xs+ unconfirmed


if [[ $force != "yes" ]]; then
    #if command -v syno_slot_mapping >/dev/null 2>&1; then
    if [[ -x /usr/syno/bin/syno_slot_mapping ]]; then
        # Models that use a device tree blob show: Esata port count: 1
        esataports=$(/usr/syno/bin/syno_slot_mapping | grep -i 'Esata port count' |\
            grep -oE '[0-9]+' | head -n1)
        if [[ -n $esataports ]]; then
            if [[ $esataports -lt 1 ]]; then
                log "Error: $model has no eSATA expansion port."
                log "Secure Erase of drives in expansion units is not needed."
                echo "Error: $model has no eSATA expansion port."
                echo "Secure Erase of drives in expansion units is not needed."
                if [[ -t 1 ]]; then  # Running in terminal
                    echo "Use the --force option to edit the files anyway."
                fi
                exit 1
            fi
        fi
    elif [[ $dsm6 == "yes" ]]; then
        # DSM 6 has no syno_slot_mapping, so check the model against the list
        if ! grep -Fxqi "$model" <<< "$dsm6models"; then
            log "Error: $model is not listed as supporting expansion units."
            echo "Error: $model is not listed as supporting expansion units."
            if [[ -t 1 ]]; then  # Running in terminal
                echo "Use the --force option to edit the files anyway."
            fi
            exit 1
        fi
    else
        # Other models: esataportcfg is a hex mask of the eSATA ports.
        # 0x0 means the NAS has no eSATA port.
        esataports=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf esataportcfg)
        if [[ $esataports =~ ^0[xX][0-9a-fA-F]+$ ]]; then
            if [[ $(( esataports )) -eq 0 ]]; then
                log "Error: $model has no eSATA expansion port."
                log "Secure Erase of drives in expansion units is not needed."
                echo "Error: $model has no eSATA expansion port."
                echo "Secure Erase of drives in expansion units is not needed."
                if [[ -t 1 ]]; then  # Running in terminal
                    echo "Use the --force option to edit the files anyway."
                fi
                exit 1
            fi
        fi
    fi
fi


#------------------------------------------------------------------------------
# Edit libsynostoragemgmt.so (DSM 7 only)

if [[ $dsm6 != "yes" ]]; then
    if [[ -t 1 ]]; then  # Running in terminal
        echo "Checking $(basename -- "$libsm")"
    fi
    log "Checking $(basename -- "$libsm")"
    libsm_action "$libsm" check
    case $? in
        0)  # Already patched
            ;;
        1)  # Not patched, so back it up and patch it
            if [[ ! -f ${libsm}.bak ]]; then
                if cp -p "$libsm" "${libsm}.bak"; then
                    if [[ -t 1 ]]; then  # Running in terminal
                        echo "Backup successful."
                    fi
                    log "Backup successful."
                else
                    log "Error: Backup failed!"
                    echo "Error: Backup failed!"
                    exit 1
                fi
            else
                # Check if backup size matches file size
                filesize=$(wc -c "$libsm" | awk '{print $1}')
                filebaksize=$(wc -c "${libsm}.bak" | awk '{print $1}')
                if [[ ! $filesize -eq "$filebaksize" ]]; then
                    if [[ -t 1 ]]; then  # Running in terminal
                        echo "WARNING Backup file size is different to file!"
                        echo "Maybe you've updated DSM since last running this script?"
                        echo "Renaming file.bak to file.bak.old"
                        log "WARNING Backup file size is different to file!"
                        log "Maybe you've updated DSM since last running this script?"
                        log "Renaming file.bak to file.bak.old"
                    fi
                    mv -f "${libsm}.bak" "${libsm}.bak.old"
                    if cp -p "$libsm" "${libsm}.bak"; then
                        if [[ -t 1 ]]; then  # Running in terminal
                            echo "Backup successful."
                        fi
                        log "Backup successful."
                    else
                        log "Error: Backup failed!"
                        echo "Error: Backup failed!"
                        exit 1
                    fi
                fi
            fi

            # Patch a copy, check the copy, then swap it in as a new file
            rm -f "${libsm}.new"
            if ! cp -p "$libsm" "${libsm}.new"; then
                log "Error: Failed to copy $(basename -- "$libsm")!"
                echo "Error: Failed to copy $(basename -- "$libsm")!"
                exit 1
            fi
            libsm_action "${libsm}.new" patch
            if [[ $? -ne 0 ]]; then
                rm -f "${libsm}.new"
                log "Error: Failed to edit $(basename -- "$libsm")!"
                echo "Error: Failed to edit $(basename -- "$libsm")!"
                exit 1
            fi

            # Only 6 bytes may differ, and the copy must now check as patched
            diffcount=$(cmp -l "$libsm" "${libsm}.new" | wc -l)
            libsm_action "${libsm}.new" check >/dev/null
            checkresult=$?
            if [[ $diffcount -ne 6 ]] || [[ $checkresult -ne 0 ]]; then
                rm -f "${libsm}.new"
                log "Error: Edited copy failed verification. Nothing changed."
                echo "Error: Edited copy failed verification. Nothing changed."
                exit 1
            fi

            if mv -f "${libsm}.new" "$libsm"; then
                if [[ -t 1 ]]; then  # Running in terminal
                    echo "Edited $(basename -- "$libsm")"
                fi
                log "Edited $(basename -- "$libsm")"
            else
                rm -f "${libsm}.new"
                echo "Error: Failed to replace $(basename -- "$libsm")!"
                log "Error: Failed to replace $(basename -- "$libsm")!"
                exit 1
            fi
            ;;
        *)
            log "Error: Cannot edit $(basename -- "$libsm")."
            log "This DSM build may not be supported yet."
            echo "Error: Cannot edit $(basename -- "$libsm")."
            echo "This DSM build may not be supported yet."
            exit 1
            ;;
    esac
fi


#------------------------------------------------------------------------------
# Edit storage_panel.js (storage.js on DSM 6)

if [[ $is_toolbox != yes ]]; then
    echo "Checking $(basename -- "$strgmgr")"
fi
strgmgr_action "$strgmgr" check
case $? in
    0)  # Already patched
        ;;
    1)  # Not patched, so back it up and patch it
        if [[ ! -f $strgmgrbak ]]; then
            if cp -p "$strgmgr" "$strgmgrbak"; then
                if [[ -t 1 ]]; then  # Running in terminal
                    log "Backed up $(basename -- "$strgmgr")"
                    echo "Backed up $(basename -- "$strgmgr")"
                fi
            else
                log "Error: Failed to backup $(basename -- "$strgmgr")!"
                echo "Error: Failed to backup $(basename -- "$strgmgr")!"
                exit 1
            fi
        fi
        strgmgr_action "$strgmgr" patch
        if [[ $? -eq 0 ]]; then
            regen_gz
            edited=yes
        else
            log "Error: Failed to edit $(basename -- "$strgmgr")!"
            echo "Error: Failed to edit $(basename -- "$strgmgr")!"
            exit 1
        fi
        ;;
    *)
        log "Error: Cannot edit $(basename -- "$strgmgr")."
        log "This Storage Manager version may not be supported yet."
        echo "Error: Cannot edit $(basename -- "$strgmgr")."
        echo "This Storage Manager version may not be supported yet."
        exit 1
        ;;
esac


#------------------------------------------------------------------------------
# Finished

if [[ $is_toolbox == yes ]]; then
    log "Secure Erase for expansion units enabled"
    echo "Secure Erase for expansion units enabled"
    if [[ $edited == "yes" ]]; then
        reloadmsg
    fi
else
    echo "Secure Erase is now enabled for drives in expansion units."
    if [[ $edited == "yes" ]]; then
        reloadmsg
    fi
fi

exit
