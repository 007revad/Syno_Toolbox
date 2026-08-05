#!/bin/bash
# run_boot_modules.sh
# Called from start-stop-status on "start" (already running as root -
# no sudo needed here, unlike synotoolbox_api.sh which is reached via
# the unprivileged CGI).
#
# Runs every enabled module whose manifest trigger is "boot" or
# "scheduled" (scheduled modules also get a run-once-at-boot pass;
# their recurring cadence is handled separately via task_setup.sh,
# not here).

set -u

PKG_DEST="/var/packages/Syno_Toolbox/target"
MANIFEST="${PKG_DEST}/conf/modules.json"

source "${PKG_DEST}/bin/conf_lib.sh"
tb_init || exit 1

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found, cannot parse modules.json" >&2
    exit 1
fi

MODULE_COUNT=$(jq '.modules | length' "$MANIFEST")

for (( i=0; i<MODULE_COUNT; i++ )); do
    id=$(jq -r ".modules[$i].id" "$MANIFEST")
    trigger=$(jq -r ".modules[$i].trigger" "$MANIFEST")
    script=$(jq -r ".modules[$i].script" "$MANIFEST")

    [[ "$trigger" == "boot" || "$trigger" == "scheduled" ]] || continue
    tb_is_enabled "$id" || continue

    args_json=$(jq -c ".modules[$i].run_args // []" "$MANIFEST")
    [[ "$args_json" == "null" ]] && args_json="[]"

    args=()
    while IFS= read -r arg; do
        while [[ "$arg" =~ \{([a-z_]+)\} ]]; do
            field="${BASH_REMATCH[1]}"
            value="$(tb_get "${id}_${field}" "")"
            arg="${arg//\{${field}\}/${value}}"
        done
        args+=("$arg")
    done < <(echo "$args_json" | jq -r '.[]')

    script_path="${PKG_DEST}/${script}"
    if [[ -x "$script_path" ]]; then
        echo "Syno_Toolbox: running $id ($script ${args[*]})"
        "$script_path" "${args[@]}" >> /var/log/synotoolbox.log 2>&1
    else
        echo "Syno_Toolbox: WARNING $script_path missing or not executable" >&2
    fi
done
