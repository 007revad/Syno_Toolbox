#!/usr/bin/env bash
# shellcheck disable=SC2034

scriptver="v1.0.0-toolbox"
#script=DSM_Version
#repo="007revad/DSM_Version"
scriptname=dsm_version

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "\nERROR This script must be run as sudo or root!\n"
    exit 1  # Not running as root
fi

#---------------------------------------------------------------------------
# Cache file location
# DSM 7: var/ exists and is writable by Syno_Toolbox (run-as: package)
# DSM 6: var/ doesn't exist; use etc/ (chmod 666 set in postinst)
#---------------------------------------------------------------------------
if [[ -d "/var/packages/Syno_Toolbox/var" ]]; then
    PKG_VAR_DIR="/var/packages/Syno_Toolbox/var"
else
    PKG_VAR_DIR="/var/packages/Syno_Toolbox/etc"
fi

# Get NAS model
nas_model=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf upnpmodelname 2>/dev/null)
# Fallback for systems where upnpmodelname is unavailable
if [[ -z "$nas_model" && -f /proc/sys/kernel/syno_hw_version ]]; then
    nas_model=$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null || echo "")
    # Check for dodgy characters after model number
    if [[ ${nas_model,,} =~ 'pv10-j'$ ]]; then  # GitHub issue #10
        nas_model=${nas_model%??????}+          # replace last 6 chars with +
    elif [[ ${nas_model} =~ '-j'$ ]]; then      # GitHub issue #2
        nas_model=${nas_model%??}               # remove last 2 chars
    fi
fi
if [[ -z "$nas_model" ]]; then
    nas_model="Unknown_model"
fi

# Get DSM name and version info
os_name=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION os_name)
if [[ -z "$os_name" ]]; then
    # DSM 6 never had os_name at all in either file and DSMUC is based on DSM 6
    # Detect DSMUC OS via the UC model prefix, otherwise assume regular DSM 6
    if [[ "${nas_model^^}" == UC* ]]; then
        os_name="DSMUC"
    else
        os_name="DSM"
    fi
fi
productversion=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION productversion)
base_raw=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION base)
base="$base_raw"
if [[ -n "$base" ]]; then base="-$base"; fi 
smallfixnumber=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION smallfixnumber)
if [[ "$smallfixnumber" -gt "0" ]]; then
    smallfixnumber_web="-$smallfixnumber"
    smallfixnumber_show=" Update $smallfixnumber"
fi 

# Show DSM version info
echo "$os_name $productversion$base$smallfixnumber_show"

#--------------------------------------------------------------------
# Check if DSM update is available

# Get DSM major version for notification method selection
DSM_MAJOR=$(synogetkeyvalue /etc.defaults/VERSION majorversion)
#log "DSM major version: $DSM_MAJOR"

# Force a fresh check from Synology servers, but at most once per TTL --
# synoupgrade --check itself takes a second or two, no need to pay that
# cost on every single Refresh/check click.
UPGRADE_CHECK_TS_FILE="${PKG_VAR_DIR}/synotoolbox_upgrade_check_ts"
UPGRADE_CHECK_TTL=86400  # 24h, matching the manual-update cache below
now_ts=$(date +%s)
last_check_ts=0
if [[ -f "$UPGRADE_CHECK_TS_FILE" ]]; then
    last_check_ts=$(cat "$UPGRADE_CHECK_TS_FILE" 2>/dev/null)
    [[ "$last_check_ts" =~ ^[0-9]+$ ]] || last_check_ts=0
fi
if [[ $(( now_ts - last_check_ts )) -ge $UPGRADE_CHECK_TTL ]]; then
    synoupgrade --check > /dev/null 2>&1
    echo "$now_ts" > "$UPGRADE_CHECK_TS_FILE" 2>/dev/null
fi

# Read cached check result
UPDATE_JSON=$(cat /var/update/check_result/update 2>/dev/null)

# If no cached result exists at all, check now regardless of the TTL above
# -- this fallback is independent of it (e.g. first-ever run, or DSM's own
# cache file got cleared).
if [[ -z "$UPDATE_JSON" ]]; then
    synoupgrade --check > /dev/null 2>&1
    UPDATE_JSON=$(cat /var/update/check_result/update 2>/dev/null)
fi

if [[ -z "$UPDATE_JSON" ]]; then
    echo "Unable to retrieve update information"
    exit 1
fi

# Parse fields
AVAILABLE=$(echo "$UPDATE_JSON" | grep -o '"blAvailable":true')
if [[ -n "$AVAILABLE" ]]; then
    UPDATE_TYPE=$(echo "$UPDATE_JSON" | grep -o '"updateType":"[^"]*"' | cut -d'"' -f4)
    BUILD=$(echo "$UPDATE_JSON" | grep -o '"iBuildNumber":[0-9]*' | cut -d: -f2)
    NANO=$(echo "$UPDATE_JSON" | grep -o '"iNano":[0-9]*' | cut -d: -f2)
    UNIQUE=$(echo "$UPDATE_JSON" | grep -o '"strUnique":"[^"]*"' | cut -d'"' -f4)
    MAJOR=$(echo "$UPDATE_JSON" | grep -o '"iMajor":[0-9]*' | head -1 | cut -d: -f2)
    MINOR=$(echo "$UPDATE_JSON" | grep -o '"iMinor":[0-9]*' | head -1 | cut -d: -f2)
    MICRO=$(echo "$UPDATE_JSON" | grep -o '"iMicro":[0-9]*' | cut -d: -f2)

    #echo "Update available: type=$UPDATE_TYPE build=$BUILD nano=$NANO unique=$UNIQUE"

    if [[ $NANO -gt 0 ]]; then UPDATE_TEXT=" Update "; fi
    echo "Update available: $os_name ${MAJOR}.${MINOR}.${MICRO}-${BUILD}${UPDATE_TEXT}$NANO"
    update_available="yes"
fi

#--------------------------------------------------------------------
# Check archive.synology.com for a manually-installable update
#
# synoupgrade only reports updates Synology's auto-update service is
# currently offering this NAS (e.g. it stops for EOL models). This walks
# archive.synology.com/download/Os/${os_name} from newest version to oldest
# looking for a .pat that matches this model, then reports it only if it
# is actually newer than what's installed.
#
# Uses $os_name rather than a hard-coded "DSM" since some models run
# DSMUC/DSM_Enterprise instead. NOTE: this assumes archive.synology.com
# mirrors the same Os/<os_name> layout and <os_name>_<model>_<build>.pat
# naming for those variants as it does for DSM -- unverified, since I
# don't have access to a DSMUC/DSM_Enterprise unit to confirm against a
# real archive listing. Worth testing on one if you have it.
#
# NOTE: for older/EOL models this can mean walking through most of the
# ~70 version directories on the archive site before finding a match --
# expect this to take noticeably longer than the synoupgrade check above.

archive_escape_re() {
    printf '%s' "$1" | sed -E 's/[][\.^$*+?(){}|/]/\\&/g'
}

# Percent-decode a URL (e.g. DSM_DS1821%2B_90080.pat -> DSM_DS1821+_90080.pat).
# Used for matching only -- the original (still-encoded) href is what we
# actually report/download, since that's the real working URL.
archive_url_decode() {
    local s="${1//%/\\x}"
    printf '%b' "$s"
}

# archive.synology.com uses site-root-relative hrefs, e.g.
# href="/download/Os/${os_name}/7.4.1-90080" -- NOT relative to the
# current directory page.
archive_resolve_url() {
    local href="$1" site_root="https://archive.synology.com"
    if [[ "$href" == http*://* ]]; then
        echo "$href"
    elif [[ "$href" == /* ]]; then
        echo "${site_root}${href}"
    else
        echo "${site_root}/${href}"
    fi
}

archive_extract_hrefs() {
    grep -oE 'href="[^"]+"' | sed -E 's/^href="//; s/"$//'
}

archive_fetch_version_dirs() {
    # os_name can contain a space (e.g. "DSM Enterprise" from synoinfo.conf)
    # but the archive site and .pat filenames use an underscore
    # ("DSM_Enterprise") -- confirmed 2026-08 against a real unit.
    local os_name_slug="${os_name// /_}"
    local base_url="https://archive.synology.com/download/Os/${os_name_slug}"
    local html
    html=$(curl -sS -L -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" \
        --connect-timeout 10 --max-time 30 "$base_url") || return 1

    printf '%s\n' "$html" \
        | archive_extract_hrefs \
        | grep -E '^[^"]*/[0-9][0-9.]*(-[0-9]+)*(-NanoPacked)?/?$|^[0-9][0-9.]*(-[0-9]+)*(-NanoPacked)?/?$' \
        | grep -v 'NanoPacked' \
        | while IFS= read -r href; do
            archive_resolve_url "$href"
        done
}

archive_fetch_pat_hrefs() {
    local dir_url="$1" html
    html=$(curl -sS -L -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" \
        --connect-timeout 10 --max-time 30 "$dir_url") || return 0
    printf '%s\n' "$html" | archive_extract_hrefs | grep -E '\.pat$' || true
}

# Parse a DSM version directory name (e.g. "6.2.4-25556-8") into
# product/base/update components.
archive_parse_version_dir() {
    local name="$1"
    if [[ "$name" =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?)-([0-9]+)(-([0-9]+))?$ ]]; then
        ARCHIVE_FOUND_PRODUCT="${BASH_REMATCH[1]}"
        ARCHIVE_FOUND_BASE="${BASH_REMATCH[3]}"
        ARCHIVE_FOUND_UPDATE="${BASH_REMATCH[5]:-0}"
        return 0
    fi
    return 1
}

# Build a fixed-width, zero-padded sortable key from product/base/update
# so two versions can be compared with a plain string comparison.
archive_version_key() {
    local product="$1" base_num="$2" update_num="$3" p1 p2 p3
    IFS='.' read -r p1 p2 p3 <<< "$product"
    printf '%03d%03d%03d-%08d-%05d' "${p1:-0}" "${p2:-0}" "${p3:-0}" "${base_num:-0}" "${update_num:-0}"
}

CACHE_FILE="${PKG_VAR_DIR}/synotoolbox_dsm_manual_update_cache"
CACHE_TTL=86400  # 24h -- archive.synology.com doesn't change often enough to
                 # justify re-walking ~70 directories on every Refresh click.

check_manual_update() {
    local nas_unique platform model model_lower model_bare_lower
    local model_esc model_lower_esc model_bare_lower_esc platform_esc os_name_esc
    local re_full re_crit
    local current_key found_key
    local cache_key result_line=""

    # Cache key = model + currently installed base. If an update is ever
    # actually applied, base_raw changes and this naturally invalidates,
    # so we never show a stale result after a real upgrade.
    cache_key="${os_name}|${nas_model}|${base_raw}"

    if [[ -f "$CACHE_FILE" ]]; then
        local file_key file_ts file_line now
        { read -r file_key; read -r file_ts; file_line=$(cat); } < "$CACHE_FILE"
        now=$(date +%s)
        if [[ "$file_key" == "$cache_key" && -n "$file_ts" \
              && $(( now - file_ts )) -lt $CACHE_TTL ]]; then
            # NOTE: this early-return path must set update_available too --
            # previously it only got set in the live-computation path below,
            # so a cache HIT with a real result never flagged it, and the
            # trailing "No update available" check fired unconditionally.
            if [[ -n "$file_line" ]]; then
                echo "$file_line"
                update_available="yes"
            fi
            return 0
        fi
    fi

    nas_unique=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf unique 2>/dev/null)
    if [[ "$nas_unique" == synology_* ]]; then
        platform=$(printf '%s' "$nas_unique" | sed -E 's/^synology_//; s/_[^_]+$//')
    fi

    model_lower=$(printf '%s' "$nas_model" | tr '[:upper:]' '[:lower:]')
    model_bare_lower=$(printf '%s' "$model_lower" | sed -E 's/^ds//; s/^rs//')

    model_esc=$(archive_escape_re "$nas_model")
    model_lower_esc=$(archive_escape_re "$model_lower")
    model_bare_lower_esc=$(archive_escape_re "$model_bare_lower")
    platform_esc=$(archive_escape_re "$platform")
    os_name_esc=$(archive_escape_re "${os_name// /_}")

    re_full="${os_name_esc}_${model_esc}_[0-9]+\.pat"
    if [[ -n "$platform" ]]; then
        re_crit="synology_${platform_esc}_(${model_lower_esc}|${model_bare_lower_esc})\.pat"
    else
        re_crit="synology_[a-z0-9]+_(${model_lower_esc}|${model_bare_lower_esc})\.pat"
    fi

    current_key=$(archive_version_key "$productversion" "$base_raw" "$smallfixnumber")
    local current_base_num=$(( 10#${base_raw:-0} ))

    local dir_url version_name href decoded full_match crit_match found_base_num
    while IFS= read -r dir_url; do
        version_name="${dir_url%/}"
        version_name="${version_name##*/}"

        full_match=""
        crit_match=""
        while IFS= read -r href; do
            [[ -z "$href" ]] && continue
            decoded=$(archive_url_decode "$href")
            if [[ "$decoded" =~ $re_full ]]; then
                full_match="$href"
                break  # a full installer always wins -- stop scanning this dir
            elif [[ -z "$crit_match" && "$decoded" =~ $re_crit ]]; then
                crit_match="$href"
            fi
        done < <(archive_fetch_pat_hrefs "$dir_url")

        if [[ -n "$full_match" ]]; then
            # Full installers are a valid direct upgrade path regardless of
            # which build is currently installed. This is the newest one
            # we'll encounter walking newest->oldest, so decide and stop.
            if archive_parse_version_dir "$version_name"; then
                found_key=$(archive_version_key "$ARCHIVE_FOUND_PRODUCT" "$ARCHIVE_FOUND_BASE" "$ARCHIVE_FOUND_UPDATE")
                if [[ "$found_key" > "$current_key" ]]; then
                    local found_url found_label update_suffix
                    found_url=$(archive_resolve_url "$full_match")
                    update_suffix=""
                    [[ "$ARCHIVE_FOUND_UPDATE" -gt 0 ]] && update_suffix=" Update $ARCHIVE_FOUND_UPDATE"
                    found_label="${os_name} ${ARCHIVE_FOUND_PRODUCT}-${ARCHIVE_FOUND_BASE}${update_suffix}"
                    result_line="Manual update available: <a href=\"${found_url}\">${found_label}</a>"
                fi
            fi
            break
        fi

        if [[ -n "$crit_match" ]] && archive_parse_version_dir "$version_name"; then
            found_base_num=$(( 10#${ARCHIVE_FOUND_BASE:-0} ))
            if [[ "$found_base_num" -eq "$current_base_num" ]]; then
                # Same base as what's installed -- a nano/critical update
                # can be applied directly. Newest for this base, so decide
                # and stop.
                found_key=$(archive_version_key "$ARCHIVE_FOUND_PRODUCT" "$ARCHIVE_FOUND_BASE" "$ARCHIVE_FOUND_UPDATE")
                if [[ "$found_key" > "$current_key" ]]; then
                    local found_url found_label update_suffix
                    found_url=$(archive_resolve_url "$crit_match")
                    update_suffix=""
                    [[ "$ARCHIVE_FOUND_UPDATE" -gt 0 ]] && update_suffix=" Update $ARCHIVE_FOUND_UPDATE"
                    found_label="${os_name} ${ARCHIVE_FOUND_PRODUCT}-${ARCHIVE_FOUND_BASE}${update_suffix}"
                    result_line="Manual update available: <a href=\"${found_url}\">${found_label}</a>"
                fi
                break
            fi
            # found_base_num > current_base_num: a nano/critical update for a
            # different (newer) base can't be applied directly -- DSM
            # requires installing that base's full installer first. Skip
            # and keep walking older directories for a DSM_ full .pat.
            # found_base_num < current_base_num: older/irrelevant, skip.
        fi
    done < <(archive_fetch_version_dirs)

    {
        echo "$cache_key"
        date +%s
        echo "$result_line"
    } > "$CACHE_FILE" 2>/dev/null

    if [[ -n "$result_line" ]]; then
        echo "$result_line"
        update_available="yes"
    fi
}

# Only run the manual-update check on DSM 7+. Confirmed via Synology's own
# upgrade-path tool: within DSM 7 (7.0/7.1/7.2/7.3 -> 7.4) a single full
# installer is a valid direct jump, matching this script's logic. But
# DSM 6 -> 7 is NOT a single hop -- e.g. 6.2.3 needs 6.2.4, then 7.0, then
# 7.4 in sequence. This script has no notion of a multi-step path, so on
# DSM 6 it would find the 7.4.1 full installer and wrongly present it as
# directly installable. Skipping entirely on DSM 6 avoids giving that bad
# advice rather than trying to half-solve multi-hop sequencing.
if [[ "$DSM_MAJOR" -ge "7" ]]; then
    check_manual_update
fi

if [[ "$update_available" != "yes" ]]; then
    echo "No update available"
fi
