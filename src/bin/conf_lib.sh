#!/bin/bash
# conf_lib.sh
# Shared conf read/write wrapper functions for Syno_Toolbox.
# Source this from any module script or from synotoolbox_api.sh:
#   source /var/packages/Syno_Toolbox/target/bin/conf_lib.sh
#
# Verified 2026-08-04 on DS925+:
#   synosetkeyvalue file key value
#   synogetkeyvalue  file key

set -u

# ---- Resolve VAR_DIR by DSM major version -----------------------------------
_tb_resolve_var_dir() {
    local dsm_major
    dsm_major="$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)"

    if [[ -z "$dsm_major" ]]; then
        echo "ERROR: could not determine DSM major version" >&2
        return 1
    fi

    if (( dsm_major >= 7 )); then
        echo "/var/packages/Syno_Toolbox/var"
    else
        echo "/var/packages/Syno_Toolbox/etc"
    fi
}

# Kept for anything that calls this directly rather than through tb_init.
resolve_conf_path() {
    local var_dir
    var_dir="$(_tb_resolve_var_dir)" || return 1
    echo "${var_dir}/toolbox.conf"
}

resolve_log_path() {
    local var_dir
    var_dir="$(_tb_resolve_var_dir)" || return 1
    echo "${var_dir}/toolbox.log"
}

# tb_get <key> [default]
tb_get() {
    local key="$1" default="${2:-}"
    local val
    val="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" "$key" 2>/dev/null)"
    if [[ -z "$val" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# tb_set <key> <value>
tb_set() {
    local key="$1" value="$2" curval
    curval="$(/usr/syno/bin/synogetkeyvalue "$TOOLBOX_CONF" "$key")"
    if [[ "$curval" != "$value" ]]; then
        /usr/syno/bin/synosetkeyvalue "$TOOLBOX_CONF" "$key" "$value"
    fi
}

# tb_set_bulk <json_blob>
# Writes every key=value in one pass instead of one synosetkeyvalue
# call per key. Format matches what synosetkeyvalue itself produces
# (quoted values), so tb_get/synogetkeyvalue can still read it back.
tb_set_bulk() {
    local json_blob="$1"
    local tmp
    tmp="$(mktemp)"
    # Start from existing conf, drop any key we're about to overwrite,
    # then append the new values - single rewrite, single lock.
    if [[ -f "$TOOLBOX_CONF" ]]; then
        cp "$TOOLBOX_CONF" "$tmp"
    fi
    echo "$json_blob" | jq -r 'to_entries[] | "\(.key)=\"\(.value)\""' | \
        while IFS='=' read -r key rest; do
            sed -i "/^${key}=/d" "$tmp"
        done
    echo "$json_blob" | jq -r 'to_entries[] | "\(.key)=\"\(.value)\""' >> "$tmp"
    mv "$tmp" "$TOOLBOX_CONF"
}

# tb_is_enabled <module_id>
tb_is_enabled() {
    local module_id="$1"
    [[ "$(tb_get "${module_id}_enabled" "no")" == "yes" ]]
}

# ---- Model / "requires" checks ----------------------------------------------

# tb_model
# Echoes this NAS's model name (e.g. "RS3621xs+"), or nothing if it
# can't be determined. upnpmodelname first, /proc/sys/kernel/syno_hw_version
# as the fallback - same two sources restore_rs3621_fan_speed.sh uses.
tb_model() {
    local m
    m="$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf upnpmodelname 2>/dev/null)"
    if [[ -z "$m" && -f /proc/sys/kernel/syno_hw_version ]]; then
        m="$(cat /proc/sys/kernel/syno_hw_version 2>/dev/null)"
    fi
    echo "$m"
}

# tb_requirements_unmet <manifest> <module_index>
# Exit status 0 = the module has a "requires" object in modules.json and
# this NAS does NOT satisfy it. Exit status 1 = supported (requirements
# met, or the module has none). Every key present must be satisfied:
#   min_dsm_major  integer  - /etc.defaults/VERSION majorversion >= value
#   min_build      integer  - /etc.defaults/VERSION buildnumber >= value
#   models         [string] - tb_model equals one of them (exact, case-insensitive)
#   exists         [path]   - every path exists
# If a value needed for a check can't be read (e.g. model unknown), the
# requirement counts as unmet - safer to grey a toggle out than to let
# something run on hardware it wasn't meant for.
tb_requirements_unmet() {
    local manifest="$1" idx="$2" req val p m model matched

    req="$(jq -c ".modules[$idx].requires // empty" "$manifest" 2>/dev/null)"
    [[ -n "$req" ]] || return 1

    val="$(jq -r '.min_dsm_major // empty' <<< "$req")"
    if [[ -n "$val" ]]; then
        m="$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion 2>/dev/null)"
        [[ "$m" =~ ^[0-9]+$ ]] || return 0
        (( m >= val )) || return 0
    fi

    val="$(jq -r '.min_build // empty' <<< "$req")"
    if [[ -n "$val" ]]; then
        m="$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber 2>/dev/null)"
        [[ "$m" =~ ^[0-9]+$ ]] || return 0
        (( m >= val )) || return 0
    fi

    if jq -e '.models' <<< "$req" >/dev/null 2>&1; then
        model="$(tb_model)"
        [[ -n "$model" ]] || return 0
        matched=1
        while IFS= read -r m; do
            [[ "${model,,}" == "${m,,}" ]] && matched=0
        done < <(jq -r '.models[]' <<< "$req")
        (( matched == 0 )) || return 0
    fi

    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ -e "$p" ]] || return 0
    done < <(jq -r '(.exists // [])[]' <<< "$req")

    return 1
}

# ---- Ensure conf file + directory exist -------------------------------------
tb_ensure_conf() {
    [[ -d "$VAR_DIR" ]] || mkdir -p "$VAR_DIR"
    [[ -f "$TOOLBOX_CONF" ]] || : > "$TOOLBOX_CONF"
}

# ---- Init: call once near the top of any script that sources this ----------
tb_init() {
    VAR_DIR="$(_tb_resolve_var_dir)" || return 1
    TOOLBOX_CONF="${VAR_DIR}/toolbox.conf"
    TOOLBOX_LOG="${VAR_DIR}/toolbox.log"
    tb_ensure_conf
    export VAR_DIR TOOLBOX_CONF TOOLBOX_LOG
}
