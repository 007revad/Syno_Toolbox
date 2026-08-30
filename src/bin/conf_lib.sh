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
