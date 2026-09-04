#!/bin/bash
#----------------------------------------------------------
# synotoolbox_api.sh
# Privileged root-side action script for Syno_Toolbox.
# Invoked via `sudo -n` from api.cgi (same pattern as CPUTemp's
# cpu_temp_api.sh). Never call directly over HTTP.
#
# Usage:
#   synotoolbox_api.sh getstate
#   synotoolbox_api.sh run <module_id>
#   synotoolbox_api.sh save '<json blob of submitted form fields>'
#----------------------------------------------------------

set -u

PKG_NAME="Syno_Toolbox"
PKG_DEST="/var/packages/${PKG_NAME}/target"
BIN_DIR="${PKG_DEST}/bin"
MODULES_DIR="${BIN_DIR}/modules"
MANIFEST="${PKG_DEST}/conf/modules.json"

# ---------------------------------------------------------------------
# Self-heal file ownership.
#
# bin/ and bin/modules/ are locked to 555 by postinst, which blocks
# create/delete/rename of files inside them - but postinst runs as
# Syno_Toolbox, not root (confirmed 2026-08-15), so it can never chown
# anything. Every file under bin/ therefore starts out still owned by
# Syno_Toolbox. An owner can always chmod u+w their own file regardless
# of the containing directory's permissions, then overwrite its
# content in place - confirmed exploitable against conf_lib.sh on
# DS218 2026-08-15 despite bin/ being 555.
#
# Since this script always runs as root (invoked only via
# synotoolbox-helper's setuid), it closes that gap on every single
# invocation: chown root:root + re-lock any file that's still
# Syno_Toolbox-owned. Cheap enough to run unconditionally rather than
# caching a "did we already do this" flag - a handful of stat calls.
#
# Targets are found by globbing bin/ and bin/modules/ directly, not by
# reading modules.json's own "script" list - the manifest itself is
# one of the things being secured, so building the target list from
# its content would let a compromised manifest hide its own overwrite
# target from this check. Since both directories are 555 (no new
# files can be created), globbing what's actually on disk covers every
# possible overwrite target without trusting content that could be
# the attack itself.
#
# LIMITATION: This cannot protect this script (synotoolbox_api.sh)
# itself if it's been replaced before this code runs, the replacement
# executes instead and this check never fires - self-heal logic in the
# original file doesn't help once the original file is gone. This is
# a narrow, accepted gap: the window between postinst completing and
# the first invocation of this script (which happens automatically on
# first page load via getstate). Everything this function iterates
# over is fully self-healing from that point forward; this file itself
# is the one exception.
tb_self_heal() {
    local f owner
    for f in "$BIN_DIR"/*.sh "$BIN_DIR"/*.py \
             "$MODULES_DIR"/*.sh "$MODULES_DIR"/*.py \
             "$MANIFEST" \
             "$0"; do
        [[ -f "$f" ]] || continue
        owner="$(stat -c '%U' "$f" 2>/dev/null)"
        if [[ "$owner" != "root" ]]; then
            chown root:root "$f" 2>/dev/null
            chmod 555 "$f" 2>/dev/null
            echo "Syno_Toolbox: self-heal secured $f (was owned by $owner)" \
                >> "${TOOLBOX_CONF%.conf}.log" 2>/dev/null
        fi
    done

    # toolbox.conf is data, not code - root still writes it on every
    # save. 600 rather than 555: no group/other bits at all, since
    # root bypasses the mode entirely and the only thing left to
    # control is whether Syno_Toolbox can read config values (some,
    # e.g. config_backup_remote_user/_remote_ip, are worth keeping
    # off a wider read path even though nothing currently depends on
    # that confidentiality).
    if [[ -f "$TOOLBOX_CONF" ]]; then
        owner="$(stat -c '%U' "$TOOLBOX_CONF" 2>/dev/null)"
        if [[ "$owner" != "root" ]]; then
            chown root:root "$TOOLBOX_CONF" 2>/dev/null
            chmod 600 "$TOOLBOX_CONF" 2>/dev/null
            echo "Syno_Toolbox: self-heal secured $TOOLBOX_CONF (was owned by $owner)" \
                >> "${TOOLBOX_CONF%.conf}.log" 2>/dev/null
        fi
    fi
}

# shellcheck source=/dev/null
source "${PKG_DEST}/bin/conf_lib.sh"
tb_init || exit 1
tb_self_heal

if ! command -v jq >/dev/null 2>&1; then
    echo '{"success":false,"message":"jq not found on this NAS"}'
    exit 1
fi

MODULE_COUNT=$(jq '.modules | length' "$MANIFEST")

# module_field <index> <field>  -- raw jq passthrough, "null" if absent
module_field() {
    jq -r ".modules[$1].${2} // \"null\"" "$MANIFEST"
}

# find_module_index <id> -- echoes array index or empty if not found
find_module_index() {
    local id="$1"
    for (( i=0; i<MODULE_COUNT; i++ )); do
        if [[ "$(module_field "$i" id)" == "$id" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# run_module_script <module_id> <args_field: run_args|disable_args|check_args>
# args_field values in the manifest may contain placeholders like {kb} or
# {volumes} -- any {field} is resolved by reading conf key "<id>_<field>".
# {volumes} specifically is expected to hold a comma-separated list (e.g.
# "volume1,volume3") and is substituted as a single --volumes=a,b,c style
# token, not split into separate args.
run_module_script() {
    local id="$1" args_field="$2"
    local idx script args_json line resolved_args=()

    idx="$(find_module_index "$id")" || { echo "Syno_Toolbox: unknown module $id" >&2; return 1; }
    script="$(module_field "$idx" script)"
    args_json="$(jq -c ".modules[$idx].${args_field} // []" "$MANIFEST")"

    [[ "$args_json" == "null" ]] && args_json="[]"

    while IFS= read -r line; do
        # Substitute every {field} placeholder found in this arg string.
        while [[ "$line" =~ \{([a-z_]+)\} ]]; do
            local field="${BASH_REMATCH[1]}"
            local value
            value="$(tb_get "${id}_${field}" "")"
            line="${line//\{${field}\}/${value}}"
        done
        resolved_args+=("$line")
    done < <(echo "$args_json" | jq -r '.[]')

    local script_path="${PKG_DEST}/${script}"
    if [[ -x "$script_path" ]]; then
        # Explicit count check instead of "${resolved_args[@]:-}": the
        # latter was assumed safe on bash < 4.4 but still throws
        # "unbound variable" under set -u on Webber's DSM 6 bash for a
        # genuinely empty array - confirmed 2026-08-30. ${#arr[@]} is
        # always safe to expand under set -u regardless of bash
        # version, even when the array is empty or never populated.
        if (( ${#resolved_args[@]} )); then
            "$script_path" "${resolved_args[@]}"
        else
            "$script_path"
        fi
    else
        echo "Syno_Toolbox: $script_path missing or not executable" >&2
        return 1
    fi
}

ACTION="${1:-}"
shift || true

case "$ACTION" in

selfheal)
    echo '{"success":true,"message":"Self-heal complete"}'
    ;;

runboot)
    # Called only via synotoolbox-helper on DSM 7+ package start, since
    # start-stop-status never runs as root there (confirmed by Dave -
    # unlike DSM 6, where start-stop-status runs as root and calls
    # run_boot_modules.sh directly instead of going through this helper
    # gate). Same enabled/trigger logic run_boot_modules.sh used to do
    # on its own, but reusing run_module_script/module_field here so
    # there's one implementation of "resolve args, find script, run it"
    # instead of two.
    for (( i=0; i<MODULE_COUNT; i++ )); do
        id="$(module_field "$i" id)"
        trigger="$(module_field "$i" trigger)"
        [[ "$trigger" == "boot" || "$trigger" == "scheduled" ]] || continue
        tb_is_enabled "$id" || continue

        echo "Syno_Toolbox: running $id"
        run_module_script "$id" run_args 2>&1
    done
    ;;

getstate)
    # Dump manifest + current conf values merged, for main.js to render.
    # current_fields is generic: every "<module_id>_<field>" key found in
    # toolbox.conf, with the id prefix stripped - so adding a new field to
    # a module (or a whole new module) never requires touching this action.
    OUT="[]"
    for (( i=0; i<MODULE_COUNT; i++ )); do
        id="$(module_field "$i" id)"
        enabled="$(tb_get "${id}_enabled" "no")"

        fields_json="{}"
        if [[ -f "$TOOLBOX_CONF" ]]; then
            while IFS='=' read -r key raw_val; do
                [[ "$key" == "${id}_"* ]] || continue
                suffix="${key#"${id}"_}"
                val="${raw_val%\"}"; val="${val#\"}"
                fields_json=$(echo "$fields_json" | jq --arg k "$suffix" --arg v "$val" '. + {($k): $v}')
            done < "$TOOLBOX_CONF"
        fi

        entry=$(jq -n --argjson mod "$(jq ".modules[$i]" "$MANIFEST")" \
                       --arg enabled "$enabled" \
                       --argjson fields "$fields_json" \
                       '$mod + {current_enabled: $enabled, current_fields: $fields}')
        OUT=$(echo "$OUT" | jq --argjson e "$entry" '. + [$e]')
    done
    echo "$OUT"
    ;;

listvolumes)
    # Mounted volumes only, ignoring /volumeUSB* and /volume0.
    volumes=()
    for volume in /volume*; do
        if [[ "$volume" =~ ^/volume[1-9][0-9]?$ ]]; then
            if df -h | grep -q "$volume"; then
                volumes+=("$(basename "$volume")")
            fi
        fi
    done
    printf '%s\n' "${volumes[@]:-}" | jq -R . | jq -s .
    ;;

listwoldevices)
    # Reads the persistent store discover_ip_macs.sh (send_wol's sibling
    # discovery script, run separately/on its own schedule) maintains via
    # arp-scan: mac\tip\thost\tseen, one device per line, "-" for host
    # when no NetBIOS name resolved. Store lives alongside toolbox.conf -
    # derived from $TOOLBOX_CONF's own directory (set by conf_lib.sh's
    # tb_init) rather than re-deriving VAR_DIR a second time here, since
    # TOOLBOX_CONF is the one path this script already has confirmed.
    STORE="$(dirname "$TOOLBOX_CONF")/wol_devices.tsv"
    if [[ ! -f "$STORE" ]]; then
        echo '[]'
    else
        OUT="[]"
        while IFS=$'\t' read -r mac ip host seen; do
            [[ -z "$mac" ]] && continue
            [[ "$host" == "-" ]] && host=""
            entry=$(jq -n --arg mac "$mac" --arg ip "$ip" --arg host "$host" '{mac: $mac, ip: $ip, host: $host}')
            OUT=$(echo "$OUT" | jq --argjson e "$entry" '. + [$e]')
        done < "$STORE"
        echo "$OUT" | jq 'sort_by(if .host == "" then 1 else 0 end, .host, (.ip | split(".") | map(tonumber)))'
    fi
    ;;

listshares)
    # Shared folder -> /volumeN/share path map, via synoshare.
    # Optional exclude regex as $1 (pipe-separated share names).
    EXCLUDE="${1:-}"
    if [[ -n "$EXCLUDE" ]]; then
        EXCLUDE_RE=$(echo "$EXCLUDE" | sed 's/|/\\b|\\b/g; s/^/\\b/; s/$/\\b/')
        readarray -t shares_array < <(synoshare --enum ALL | tail -n +3 | grep -P -v "$EXCLUDE_RE")
    else
        readarray -t shares_array < <(synoshare --enum ALL | tail -n +3)
    fi

    OUT="[]"
    for share in "${shares_array[@]:-}"; do
        path="$(synoshare --getmap "$share" | grep '\[/volume[1-9]' | cut -d"[" -f2 | cut -d"]" -f1)"
        [[ -z "$path" ]] && continue
        entry=$(jq -n --arg name "$share" --arg path "$path" '{name: $name, path: $path}')
        OUT=$(echo "$OUT" | jq --argjson e "$entry" '. + [$e]')
    done
    echo "$OUT"
    ;;

listfolder)
    # Lists immediate subdirectories of a real /volumeN/... path. Plain
    # filesystem read - no Synology webapi, no SynoToken, no DSM 6 vs 7
    # branching. Used by main.js's folder picker to browse below a share
    # root (listshares gives the share roots themselves).
    TARGET_PATH="${1:-}"
    # Only real volume paths, and reject any segment starting with "."
    # (blocks ".." traversal and hidden dirs) rather than trying to
    # resolve/canonicalize the path ourselves.
    if [[ -z "$TARGET_PATH" || ! "$TARGET_PATH" =~ ^/volume[0-9]+(/[^./][^/]*)*$ ]]; then
        echo '{"success":false,"message":"Invalid path"}'
        exit 1
    fi
    if [[ ! -d "$TARGET_PATH" ]]; then
        echo '{"success":false,"message":"Not a directory"}'
        exit 1
    fi

    OUT="[]"
    shopt -s nullglob
    for dir in "$TARGET_PATH"/*/; do
        dir="${dir%/}"
        name="$(basename "$dir")"
        # Skip Synology's own system/hidden folders (#recycle, @eaDir,
        # @tmp, etc.) - not useful backup destinations.
        case "$name" in
            \#*|@*) continue ;;
        esac
        entry=$(jq -n --arg name "$name" --arg path "$dir" '{name: $name, path: $path}')
        OUT=$(echo "$OUT" | jq --argjson e "$entry" '. + [$e]')
    done
    shopt -u nullglob
    echo "$OUT" | jq 'sort_by(.name)'
    ;;

discovernas)
    # syno_discover.py is bundled inside Syno_Toolbox itself (confirmed
    # 2026-08-04 by Dave, tested as root on DS925+) - no dependency on
    # Drive Info being installed.
    DISCOVER_SCRIPT="/var/packages/Syno_Toolbox/target/bin/syno_discover.py"
    if [[ ! -f "$DISCOVER_SCRIPT" ]]; then
        echo '{"success":false,"message":"syno_discover.py not found in this package build. Add target NAS manually instead."}'
        exit 0
    fi

    PYTHON_BIN="$(command -v python3 || command -v python)"
    if [[ -z "$PYTHON_BIN" ]]; then
        echo '{"success":false,"message":"No python interpreter found on this NAS"}'
        exit 0
    fi

    RESULT="$("$PYTHON_BIN" "$DISCOVER_SCRIPT" --json --timeout 3 2>>"${TOOLBOX_CONF%.conf}.log")"
    if [[ -z "$RESULT" ]]; then
        echo '{"success":false,"message":"No NAS found on the network"}'
    else
        printf '{"success":true,"result":%s}\n' "$RESULT"
    fi
    ;;

run)
    MODULE_ID="${1:-}"
    if [[ -z "$MODULE_ID" ]]; then
        echo '{"success":false,"message":"No module id given"}'
        exit 1
    fi
    RESULT="$(run_module_script "$MODULE_ID" run_args 2>&1)"
    RC=$?
    if [[ $RC -eq 0 ]]; then
        printf '{"success":true,"result":%s}\n' "$(printf '%s' "$RESULT" | jq -Rs .)"
    else
        printf '{"success":false,"message":%s}\n' "$(printf '%s' "$RESULT" | jq -Rs .)"
    fi
    ;;

check)
    # Runs a module's check_args regardless of its enabled/disabled state - this
    # is a status display independentof Syno_Toolbox's own toggle for that module.
    MODULE_ID="${1:-}"
    if [[ -z "$MODULE_ID" ]]; then
        echo '{"success":false,"message":"No module id given"}'
        exit 1
    fi
    RESULT="$(run_module_script "$MODULE_ID" check_args 2>&1)"
    RC=$?
    if [[ $RC -eq 0 ]]; then
        printf '{"success":true,"result":%s}\n' "$(printf '%s' "$RESULT" | jq -Rs .)"
    else
        printf '{"success":false,"message":%s}\n' "$(printf '%s' "$RESULT" | jq -Rs .)"
    fi
    ;;

save)
    #date +%s.%N >> "${TOOLBOX_CONF%.conf}.log"   # start
    #echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] start save" >> "${TOOLBOX_CONF%.conf}.log"

    JSON_BLOB="${1:-{\}}"

    # 1. Snapshot old *_enabled state before writing anything.
    declare -A OLD_STATE
    for (( i=0; i<MODULE_COUNT; i++ )); do
        id="$(module_field "$i" id)"
        OLD_STATE["$id"]="$(tb_get "${id}_enabled" "no")"
    done

    #echo "old_state done: $(date +%s.%N)" >> "${TOOLBOX_CONF%.conf}.log"
    #echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] old state done" >> "${TOOLBOX_CONF%.conf}.log"

    # 2. Write every submitted key=value to conf.
    while IFS=$'\t' read -r key value; do
        [[ -z "$key" ]] && continue
        tb_set "$key" "$value"
    done < <(echo "$JSON_BLOB" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

    #echo "tb_set loop done: $(date +%s.%N)" >> "${TOOLBOX_CONF%.conf}.log"
    #echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] tb_set loop done" >> "${TOOLBOX_CONF%.conf}.log"

    # 3. Diff enabled state per module, run apply/reverse as appropriate,
    #    capturing each module's stdout so the frontend can show it
    #    directly instead of discarding it.
    LOG=""
    RESULTS="{}"
    for (( i=0; i<MODULE_COUNT; i++ )); do
        id="$(module_field "$i" id)"
        live="$(module_field "$i" live)"
        [[ "$live" == "true" ]] && continue

        old="${OLD_STATE[$id]:-no}"
        new="$(tb_get "${id}_enabled" "no")"

        if [[ "$old" == "no" && "$new" == "yes" ]]; then
            output="$(run_module_script "$id" run_args 2>>"${TOOLBOX_CONF%.conf}.log")"
            LOG+="enabled:${id} "
            RESULTS=$(echo "$RESULTS" | jq --arg k "$id" --arg v "$output" '. + {($k): $v}')
        elif [[ "$old" == "yes" && "$new" == "no" ]]; then
            disable_args="$(module_field "$i" disable_args)"
            if [[ "$disable_args" != "null" ]]; then
                output="$(run_module_script "$id" disable_args 2>>"${TOOLBOX_CONF%.conf}.log")"
                LOG+="disabled:${id} "
                RESULTS=$(echo "$RESULTS" | jq --arg k "$id" --arg v "$output" '. + {($k): $v}')
            fi
        fi
    done

    #echo "diff loop done: $(date +%s.%N)" >> "${TOOLBOX_CONF%.conf}.log"
    #echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] diff loop done" >> "${TOOLBOX_CONF%.conf}.log"

    printf '{"success":true,"message":%s,"results":%s}\n' \
        "$(printf '%s' "$LOG" | jq -Rs .)" "$RESULTS"
    ;;

*)
    echo '{"success":false,"message":"Unknown action"}'
    exit 1
    ;;
esac
