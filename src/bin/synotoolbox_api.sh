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
                >> "$TOOLBOX_LOG" 2>/dev/null
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
                >> "$TOOLBOX_LOG" 2>/dev/null
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

# scheduled_task_name <idx> - the DSM Task Scheduler task name a
# module's schedule (if any) uses. Shared by getstate's reconciliation
# and sync_scheduled_task so there's exactly one place this convention
# ("Syno_Toolbox " + the manifest's own "name" field) is defined -
# confirmed 2026-09-13 to match a real deployed task
# ("CPU Usage" -> "Syno_Toolbox CPU Usage").
scheduled_task_name() {
    local idx="$1"
    echo "Syno_Toolbox $(module_field "$idx" name)"
}

# schedule_type <idx> - which schedule "family" a module's manifest
# entry has, or empty if none:
#   default_repeat_minute -> "minute" (numeric interval, e.g. cpu_usage)
#   default_repeat_hour   -> "hour"   (numeric interval, e.g. schedule_ups_connected)
#   default_frequency     -> "frequency" (a week/month CHOICE, not a
#                             numeric interval - e.g. config_backup;
#                             the actual chosen value is resolved
#                             separately, see sync_scheduled_task)
schedule_type() {
    local idx="$1"
    if jq -e ".modules[$idx].schedule.default_repeat_minute" "$MANIFEST" >/dev/null 2>&1; then
        echo minute
    elif jq -e ".modules[$idx].schedule.default_repeat_hour" "$MANIFEST" >/dev/null 2>&1; then
        echo hour
    elif jq -e ".modules[$idx].schedule.default_frequency" "$MANIFEST" >/dev/null 2>&1; then
        echo frequency
    fi
}

ACTION="${1:-}"
shift || true

# sync_scheduled_task <module_id> - for any module with a "schedule"
# object in the manifest, keeps its real DSM Task Scheduler entry in
# sync with conf's "<id>_enabled" and its interval/frequency field.
# Fully generic and manifest-driven (task name from
# scheduled_task_name, command from the module's "script"), same
# principle as run_module_script - no per-module hardcoding here,
# unlike the cpu_usage-only block this replaced.
#
# hour, minute, and now week/month (via the "frequency" family) all
# have a CONFIRMED SYNO.Core.TaskScheduler schedule shape
# (task_setup.sh's build_schedule) - week/month confirmed 2026-09-13,
# DSM7/v4 only. DSM6 is unverified for week/month and rejected by
# task_setup.sh itself, so a DSM6 attempt here surfaces as a normal
# task_setup.sh failure (logged, conf reverted), not a special case
# needed in this function.
sync_scheduled_task() {
    local id="$1"
    local idx task_name command enabled interval interval_type family

    idx="$(find_module_index "$id")" || { echo "Syno_Toolbox: sync_scheduled_task: unknown module $id" >&2; return 1; }
    task_name="$(scheduled_task_name "$idx")"
    command="${PKG_DEST}/$(module_field "$idx" script)"
    enabled="$(tb_get "${id}_enabled" "no")"
    family="$(schedule_type "$idx")"

    case "$family" in
        minute)
            interval_type="minute"
            interval="$(tb_get "${id}_minute" "$(jq -r ".modules[$idx].schedule.default_repeat_minute" "$MANIFEST")")"
            ;;
        hour)
            interval_type="hour"
            interval="$(tb_get "${id}_hour" "$(jq -r ".modules[$idx].schedule.default_repeat_hour" "$MANIFEST")")"
            ;;
        frequency)
            # week/month take no --interval at all (see task_setup.sh)
            # - the CHOICE between them is what "interval_type" means
            # here, resolved from conf same as any other field.
            interval_type="$(tb_get "${id}_frequency" "$(jq -r ".modules[$idx].schedule.default_frequency" "$MANIFEST")")"
            interval=""
            ;;
        *)
            echo "Syno_Toolbox: sync_scheduled_task: ${id} has a \"schedule\" object with no recognized default_repeat_*/default_frequency key" >&2
            return 1
            ;;
    esac

    local task_setup="${BIN_DIR}/task_setup.sh"
    [[ -x "$task_setup" ]] || { echo "Syno_Toolbox: sync_scheduled_task: ${task_setup} missing or not executable" >&2; return 1; }

    local task_output
    if [[ "$enabled" == "yes" ]]; then
        if [[ -n "$interval" ]]; then
            task_output="$("$task_setup" set --name="$task_name" --command="$command" --interval-type="$interval_type" --interval="$interval" 2>>"$TOOLBOX_LOG")"
        else
            task_output="$("$task_setup" set --name="$task_name" --command="$command" --interval-type="$interval_type" 2>>"$TOOLBOX_LOG")"
        fi
        if echo "$task_output" | grep -q '"success":false'; then
            echo "Syno_Toolbox: ${id} enable FAILED (${interval_type}${interval:+=$interval}) - task_setup.sh set: ${task_output}" >> "$TOOLBOX_LOG"
            # Don't leave conf claiming "enabled" when nothing was
            # actually created - getstate's reconciliation would catch
            # this on the next call anyway, but fixing it here avoids
            # even one round-trip of an inconsistent state.
            tb_set "${id}_enabled" "no"
        else
            echo "Syno_Toolbox: ${id} enabled (${interval_type}${interval:+=$interval}) - task_setup.sh set: ${task_output}" >> "$TOOLBOX_LOG"
        fi
    else
        task_output="$("$task_setup" remove --name="$task_name" 2>>"$TOOLBOX_LOG")"
        echo "Syno_Toolbox: ${id} disabled - task_setup.sh remove: ${task_output}" >> "$TOOLBOX_LOG"
    fi
    RESULTS=$(echo "$RESULTS" | jq --arg k "$id" --arg v "$task_output" '. + {($k): $v}')
}

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

        # A schedule-having module's "enabled" is meant to reflect a
        # real DSM Task Scheduler entry, not just the last checkbox
        # state saved. If save's step 4 (sync_scheduled_task) failed to
        # create one, or it was removed some other way (e.g. deleted
        # directly in DSM's own Task Scheduler), correct the flag back
        # to "no" here rather than show a toggle that's on but backed
        # by nothing. Confirmed as the intended behavior, not a bug, on
        # 2026-09-13. Covers all three schedule families (hour/minute/
        # frequency) now that week/month have confirmed shapes too.
        if [[ "$enabled" == "yes" ]]; then
            sched_type="$(schedule_type "$i")"
            if [[ "$sched_type" == "hour" || "$sched_type" == "minute" || "$sched_type" == "frequency" ]]; then
                TASK_SETUP="${BIN_DIR}/task_setup.sh"
                if [[ -x "$TASK_SETUP" ]]; then
                    task_name="$(scheduled_task_name "$i")"
                    TASK_CHECK="$("$TASK_SETUP" find --name="$task_name" 2>>"$TOOLBOX_LOG")"
                    if ! echo "$TASK_CHECK" | grep -q '"exists":true'; then
                        enabled="no"
                        tb_set "${id}_enabled" "no"
                        echo "Syno_Toolbox: getstate reconciled ${id}_enabled=no (no Task Scheduler entry named \"${task_name}\" found)" >> "$TOOLBOX_LOG"
                    fi
                fi
            fi
        fi

        fields_json="{}"
        if [[ -f "$TOOLBOX_CONF" ]]; then
            while IFS='=' read -r key raw_val; do
                [[ "$key" == "${id}_"* ]] || continue
                suffix="${key#"${id}"_}"
                # Never echo a secret back to the browser - getstate's
                # result feeds main.js's field prefill directly, and a
                # write-only credential (e.g. config_backup_shared_secret)
                # must stay that way. Matched generically by suffix so any
                # future "<id>_..._secret" field is covered without a
                # per-field allowlist here.
                [[ "$suffix" == *secret* ]] && continue
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
    # when no NetBIOS name resolved. Lives in $VAR_DIR alongside
    # toolbox.conf/toolbox.log - both now exported directly by
    # conf_lib.sh's tb_init, no derivation needed.
    STORE="${VAR_DIR}/wol_devices.tsv"
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

wolscanstatus)
    # Reports the status file discoverwol's setsid'd wrapper maintains:
    # {"status":"running"} while a scan is in flight, {"status":"done"
    # /"error","rc":N} once it finishes. {"status":"idle"} if no scan
    # has ever run yet (file doesn't exist). Lets the frontend poll
    # real completion state for the spinner instead of guessing on a
    # fixed timer.
    STATUS_FILE="${VAR_DIR}/wol_scan_status.json"
    if [[ -f "$STATUS_FILE" ]]; then
        cat "$STATUS_FILE"
    else
        echo '{"status": "idle"}'
    fi
    ;;

discoverwol)
    # Launches discover_ip_macs.sh (the arp-scan that populates
    # wol_devices.tsv, ~4.5s) detached from this request entirely, so
    # the HTTP response returns immediately - main.js fires this once
    # on page open and never waits on its result. If a scan is already
    # running (page reopened quickly, or overlapping with a scheduled
    # run once one exists), skip launching a second one rather than
    # stacking concurrent arp-scans against the same interfaces.
    DISCOVER_SCRIPT="${BIN_DIR}/discover_ip_macs.sh"
    if [[ ! -x "$DISCOVER_SCRIPT" ]]; then
        echo '{"launched": false, "reason": "script not found or not executable"}'
    elif pgrep -f "$DISCOVER_SCRIPT" >/dev/null 2>&1; then
        echo '{"launched": false, "reason": "already running"}'
    else
        # nohup+disown only stops SIGHUP reaching this and detaches it
        # from bash's own job table - it does NOT move the process into
        # a new session, so it stays in the same process group as this
        # CGI request. DSM's web server almost certainly reaps that
        # whole group once the request completes, killing this mid-scan
        # before it ever writes the tsv - matching exactly what's been
        # observed (works via a live SSH session, silently dies when
        # triggered from the browser). setsid fully detaches into its
        # own session, immune to that group's lifecycle.
        #
        # setsid has to wrap the *whole* start/run/finish sequence, not
        # just the scan invocation - a wrapper that only setsid's the
        # scan itself would still have its own START/FINISH-logging
        # shell sitting in the original process group, just as exposed
        # to the same reaping this is meant to escape. Passed via
        # exported vars rather than string-substituting into the -c
        # script, to avoid a quoting mess.
        #
        # discover_ip_macs.sh's own stdout/stderr lines aren't
        # individually timestamped, and its parallel per-host lookups
        # can interleave their output - these START/FINISH banners
        # (with exit code) at least bound where one run begins and ends
        # in the shared, otherwise timestamp-free log.
        #
        # Also maintains a small status file so the frontend (via the
        # wolscanstatus action below) can poll real completion state -
        # "running" while in flight, "done"/"error" (with rc) once
        # finished - rather than guessing on a fixed timer.
        STATUS_FILE="${VAR_DIR}/wol_scan_status.json"
        export DISCOVER_SCRIPT TOOLBOX_LOG STATUS_FILE
        setsid bash -c '
            echo "[$(date "+%Y-%m-%d %H:%M:%S")] [INFO] discoverwol: START $DISCOVER_SCRIPT (detached via setsid)" >> "$TOOLBOX_LOG"
            echo "{\"status\":\"running\",\"started\":$(date +%s)}" > "$STATUS_FILE"
            "$DISCOVER_SCRIPT" </dev/null >> "$TOOLBOX_LOG" 2>&1
            rc=$?
            echo "[$(date "+%Y-%m-%d %H:%M:%S")] [INFO] discoverwol: FINISH rc=$rc" >> "$TOOLBOX_LOG"
            if [[ $rc -eq 0 ]]; then
                echo "{\"status\":\"done\",\"rc\":$rc,\"finished\":$(date +%s)}" > "$STATUS_FILE"
            else
                echo "{\"status\":\"error\",\"rc\":$rc,\"finished\":$(date +%s)}" > "$STATUS_FILE"
            fi
        ' &
        disown
        echo '{"launched": true}'
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

    RESULT="$("$PYTHON_BIN" "$DISCOVER_SCRIPT" --json --timeout 3 2>>"$TOOLBOX_LOG")"
    if [[ -z "$RESULT" ]]; then
        echo '{"success":false,"message":"No NAS found on the network"}'
    else
        printf '{"success":true,"result":%s}\n' "$RESULT"
    fi
    ;;

discovertoolboxnas)
    # Broadcast-discover all Synology NAS (same syno_discover.py as
    # discovernas above), then probe each one's own api.cgi to find
    # which are actually running Syno_Toolbox with a reachable admin
    # port - syno_discover.py finds ANY Synology, this narrows it down
    # for config_backup's remote-target dropdowns. Read-only probe
    # (pingtoolbox action), no shared secret involved - only
    # receive_backup itself is secret-gated.
    DISCOVER_SCRIPT="/var/packages/Syno_Toolbox/target/bin/syno_discover.py"
    PROBE_SCRIPT="${BIN_DIR}/probe_toolbox_nas.py"
    if [[ ! -f "$DISCOVER_SCRIPT" || ! -f "$PROBE_SCRIPT" ]]; then
        echo '{"success":false,"message":"Discovery scripts missing from this package build"}'
        exit 0
    fi

    PYTHON_BIN="$(command -v python3 || command -v python)"
    if [[ -z "$PYTHON_BIN" ]]; then
        echo '{"success":false,"message":"No python interpreter found on this NAS"}'
        exit 0
    fi

    RAW="$("$PYTHON_BIN" "$DISCOVER_SCRIPT" --json --timeout 3 2>>"$TOOLBOX_LOG")"
    if [[ -z "$RAW" ]]; then
        echo '{"success":true,"result":[]}'
        exit 0
    fi

    PROBED="$(echo "$RAW" | "$PYTHON_BIN" "$PROBE_SCRIPT" --timeout 3 2>>"$TOOLBOX_LOG")"
    [[ -z "$PROBED" ]] && PROBED="[]"
    printf '{"success":true,"result":%s}\n' "$PROBED"
    ;;

receive_backup)
    # Called only via api.cgi's raw-body intercept, itself invoked
    # through run_privileged_stdin - the presented secret arrives on
    # our own stdin (never argv/ps, same pattern as enable_ssh_root's
    # --pwd), FILENAME and the CGI-user-written temp file path arrive
    # as normal args. Verifying the secret needs root: toolbox.conf is
    # chmod 600 root-owned (see tb_self_heal above), unreadable to the
    # unprivileged CGI user that wrote TMP_FILE. Writing the final file
    # into TARGET_DIR needs root too, same as the local export's own
    # `chown admin:administrators` step.
    FILENAME="${1:-}"
    TMP_FILE="${2:-}"
    read -r PRESENTED_SECRET

    cleanup_tmp() { [[ -n "$TMP_FILE" ]] && rm -f "$TMP_FILE" 2>/dev/null; }

    STORED_SECRET="$(tb_get "config_backup_shared_secret" "")"
    if [[ -z "$STORED_SECRET" ]]; then
        echo '{"success":false,"message":"No shared secret configured on this NAS"}'
        cleanup_tmp
        exit 1
    fi
    if [[ -z "$PRESENTED_SECRET" || "$PRESENTED_SECRET" != "$STORED_SECRET" ]]; then
        echo '{"success":false,"message":"Invalid shared secret"}'
        cleanup_tmp
        exit 1
    fi

    # Plain filename only - no path separators, no leading dot. Same
    # defensive style as listfolder's TARGET_PATH check above, applied
    # to a bare filename instead of a /volumeN/... path.
    if [[ -z "$FILENAME" || ! "$FILENAME" =~ ^[A-Za-z0-9._-]+$ || "$FILENAME" == .* ]]; then
        echo '{"success":false,"message":"Invalid filename"}'
        cleanup_tmp
        exit 1
    fi
    if [[ -z "$TMP_FILE" || ! -f "$TMP_FILE" ]]; then
        echo '{"success":false,"message":"Upload temp file missing"}'
        exit 1
    fi

    TARGET_DIR="$(tb_get "config_backup_target_dir" "")"
    if [[ -z "$TARGET_DIR" || ! -d "$TARGET_DIR" ]]; then
        echo '{"success":false,"message":"No valid backup target dir configured on this NAS"}'
        cleanup_tmp
        exit 1
    fi

    DEST="${TARGET_DIR}/${FILENAME}"
    if [[ -e "$DEST" ]]; then
        echo '{"success":false,"message":"A backup with that filename already exists on this NAS"}'
        cleanup_tmp
        exit 1
    fi

    if ! mv "$TMP_FILE" "$DEST"; then
        echo '{"success":false,"message":"Failed to move upload into place"}'
        cleanup_tmp
        exit 1
    fi
    chown admin:administrators "$DEST" 2>/dev/null

    echo '{"success":true,"message":"Backup received"}'
    ;;

run)
    MODULE_ID="${1:-}"
    if [[ -z "$MODULE_ID" ]]; then
        echo '{"success":false,"message":"No module id given"}'
        exit 1
    fi

    if [[ "$MODULE_ID" == "cpu_usage_seed" ]]; then
        # Not a real module id - intercepted here before find_module_index,
        # same pattern as secret_input below intercepts enable_ssh_root.
        # One arg only ("run cpu_usage_seed") to stay inside the setuid
        # helper's one_arg whitelist - see synotoolbox-helper.c.
        RESULT="$("${PKG_DEST}/bin/modules/cpu_usage.sh" seed 2>&1)"
        RC=$?
        if [[ $RC -eq 0 ]]; then
            printf '{"success":true,"result":%s}\n' "$(printf '%s' "$RESULT" | jq -Rs .)"
        else
            printf '{"success":false,"message":%s}\n' "$(printf '%s' "$RESULT" | jq -Rs .)"
        fi
        exit 0
    fi

    idx="$(find_module_index "$MODULE_ID")" || { echo '{"success":false,"message":"Unknown module id"}'; exit 1; }
    secret_input="$(module_field "$idx" secret_input)"

    if [[ "$secret_input" == "true" ]]; then
        # Password arrives on our own stdin (piped by api.cgi's
        # run_privileged_stdin) - forward it via --pwd instead of
        # routing through run_module_script's run_args/{field}-from-conf
        # substitution, which would require persisting it to
        # toolbox.conf first (never do that for a secret).
        script="$(module_field "$idx" script)"
        script_path="${PKG_DEST}/${script}"
        if [[ ! -x "$script_path" ]]; then
            echo '{"success":false,"message":"Module script missing or not executable"}'
            exit 1
        fi
        RESULT="$("$script_path" --pwd 2>&1)"
    else
        RESULT="$(run_module_script "$MODULE_ID" run_args 2>&1)"
    fi
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
    #date +%s.%N >> "$TOOLBOX_LOG"   # start
    #echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] start save" >> "$TOOLBOX_LOG"

    JSON_BLOB="${1:-{\}}"

    # 1. Snapshot old *_enabled state before writing anything.
    declare -A OLD_STATE
    for (( i=0; i<MODULE_COUNT; i++ )); do
        id="$(module_field "$i" id)"
        OLD_STATE["$id"]="$(tb_get "${id}_enabled" "no")"
    done

    #echo "old_state done: $(date +%s.%N)" >> "$TOOLBOX_LOG"
    #echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] old state done" >> "$TOOLBOX_LOG"

    # 2. Write every submitted key=value to conf.
    while IFS=$'\t' read -r key value; do
        [[ -z "$key" ]] && continue
        # A "*_secret" field arriving blank means "leave it as-is", not
        # "clear it" - the browser never gets to see the stored value
        # (see getstate's fields_json filter above), so an unrelated
        # save (e.g. flipping some other module's toggle) always submits
        # this field empty and must not wipe out a previously-set
        # secret. Only a real, non-empty value from the Settings modal
        # actually updates it.
        if [[ "$key" == *secret* && -z "$value" ]]; then
            continue
        fi
        tb_set "$key" "$value"
    done < <(echo "$JSON_BLOB" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

    #echo "tb_set loop done: $(date +%s.%N)" >> "$TOOLBOX_LOG"
    #echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] tb_set loop done" >> "$TOOLBOX_LOG"

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
            output="$(run_module_script "$id" run_args 2>>"$TOOLBOX_LOG")"
            LOG+="enabled:${id} "
            RESULTS=$(echo "$RESULTS" | jq --arg k "$id" --arg v "$output" '. + {($k): $v}')
        elif [[ "$old" == "yes" && "$new" == "no" ]]; then
            disable_args="$(module_field "$i" disable_args)"
            if [[ "$disable_args" != "null" ]]; then
                output="$(run_module_script "$id" disable_args 2>>"$TOOLBOX_LOG")"
                LOG+="disabled:${id} "
                RESULTS=$(echo "$RESULTS" | jq --arg k "$id" --arg v "$output" '. + {($k): $v}')
            fi
        fi
    done

    #echo "diff loop done: $(date +%s.%N)" >> "$TOOLBOX_LOG"
    #echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] diff loop done" >> "$TOOLBOX_LOG"

    # 4. Task Scheduler sync for any module that has a "schedule" object
    #    in the manifest - separate from the enable-diff loop above
    #    (which explicitly skips live modules, since ordinary live
    #    modules just render on demand rather than being enabled/
    #    disabled via run_args/disable_args scripts). Fully generic and
    #    manifest-driven via sync_scheduled_task - currently matches
    #    cpu_usage (minute), schedule_ups_connected (hour), and
    #    config_backup (week, though week-type is logged-and-skipped
    #    until its schedule shape is verified - see sync_scheduled_task).
    for (( i=0; i<MODULE_COUNT; i++ )); do
        id="$(module_field "$i" id)"
        has_schedule="$(jq -r ".modules[$i].schedule // empty" "$MANIFEST")"
        [[ -n "$has_schedule" ]] || continue
        sync_scheduled_task "$id"
    done

    printf '{"success":true,"message":%s,"results":%s}\n' \
        "$(printf '%s' "$LOG" | jq -Rs .)" "$RESULTS"
    ;;

*)
    echo '{"success":false,"message":"Unknown action"}'
    exit 1
    ;;
esac
