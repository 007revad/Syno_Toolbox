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
MANIFEST="${PKG_DEST}/conf/modules.json"

source "${PKG_DEST}/bin/conf_lib.sh"
tb_init || exit 1

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
        # "${resolved_args[@]:-}" not "${resolved_args[@]}": bash < 4.4
        # (DSM 6's shipped bash) throws "unbound variable" under set -u
        # when expanding an EMPTY array with plain [@], even though the
        # array is legitimately defined as empty - a known bash bug fixed
        # in 4.4. The :- suffix works around it without changing behavior
        # when the array actually has elements.
        "$script_path" "${resolved_args[@]:-}"
    else
        echo "Syno_Toolbox: $script_path missing or not executable" >&2
        return 1
    fi
}

ACTION="${1:-}"
shift || true

case "$ACTION" in

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
                suffix="${key#${id}_}"
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
    JSON_BLOB="${1:-{\}}"

    # 1. Snapshot old *_enabled state before writing anything.
    declare -A OLD_STATE
    for (( i=0; i<MODULE_COUNT; i++ )); do
        id="$(module_field "$i" id)"
        OLD_STATE["$id"]="$(tb_get "${id}_enabled" "no")"
    done

    # 2. Write every submitted key=value to conf.
    while IFS=$'\t' read -r key value; do
        [[ -z "$key" ]] && continue
        tb_set "$key" "$value"
    done < <(echo "$JSON_BLOB" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

    # 3. Diff enabled state per module, run apply/reverse as appropriate.
    LOG=""
    for (( i=0; i<MODULE_COUNT; i++ )); do
        id="$(module_field "$i" id)"
        live="$(module_field "$i" live)"
        [[ "$live" == "true" ]] && continue

        old="${OLD_STATE[$id]:-no}"
        new="$(tb_get "${id}_enabled" "no")"

        if [[ "$old" == "no" && "$new" == "yes" ]]; then
            run_module_script "$id" run_args >/dev/null 2>>"${TOOLBOX_CONF%.conf}.log"
            LOG+="enabled:${id} "
        elif [[ "$old" == "yes" && "$new" == "no" ]]; then
            disable_args="$(module_field "$i" disable_args)"
            if [[ "$disable_args" != "null" ]]; then
                run_module_script "$id" disable_args >/dev/null 2>>"${TOOLBOX_CONF%.conf}.log"
                LOG+="disabled:${id} "
            fi
        fi
    done

    printf '{"success":true,"message":%s}\n' "$(printf '%s' "$LOG" | jq -Rs .)"
    ;;

*)
    echo '{"success":false,"message":"Unknown action"}'
    exit 1
    ;;
esac
