#!/bin/bash
# conf_lib.sh
# Shared conf read/write wrapper functions for Syno_Toolbox.
# Source this from any module script or from synotoolbox_api.sh:
#   source /var/packages/Syno_Toolbox/target/scripts/conf_lib.sh
#
# Verified 2026-08-04 on DS925+:
#   synosetkeyvalue file key value
#   synogetkeyvalue  file key

set -u

# ---- Resolve conf path by DSM major version --------------------------------
resolve_conf_path() {
    local dsm_major
    dsm_major="$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)"

    if [[ -z "$dsm_major" ]]; then
        echo "ERROR: could not determine DSM major version" >&2
        return 1
    fi

    if (( dsm_major >= 7 )); then
        echo "/var/packages/Syno_Toolbox/var/toolbox.conf"
    else
        echo "/var/packages/Syno_Toolbox/etc/toolbox.conf"
    fi
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
    local key="$1" value="$2"
    /usr/syno/bin/synosetkeyvalue "$TOOLBOX_CONF" "$key" "$value"
}

# tb_is_enabled <module_id>
tb_is_enabled() {
    local module_id="$1"
    [[ "$(tb_get "${module_id}_enabled" "no")" == "yes" ]]
}

# ---- Ensure conf file + directory exist -------------------------------------
tb_ensure_conf() {
    local dir
    dir="$(dirname "$TOOLBOX_CONF")"
    [[ -d "$dir" ]] || mkdir -p "$dir"
    [[ -f "$TOOLBOX_CONF" ]] || : > "$TOOLBOX_CONF"
}

# ---- Init: call once near the top of any script that sources this ----------
tb_init() {
    TOOLBOX_CONF="$(resolve_conf_path)" || return 1
    tb_ensure_conf
    export TOOLBOX_CONF
}
