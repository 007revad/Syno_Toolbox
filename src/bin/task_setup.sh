#!/bin/bash
#----------------------------------------------------------
# Creates/updates/disables the CPUTemp scheduled task via
# SYNO.Core.TaskScheduler. Run as root (sudo'd from cpu_temp_api.sh).
#
# Confirmed 2026-07-31 against real test tasks:
#   DSM 7 (api version 4): schedule needs repeat_hour, repeat_min,
#     repeat_date=1001 (the "daily repeat" marker for v4 - a plain 0
#     was rejected with "Invalid repeat [0] for date_type [0] for v4"),
#     and a "version":4 key nested inside the schedule object itself.
#   DSM 6 (api version 1): schedule has no repeat_min/version keys;
#     repeat_date=0 is correct for daily repeat.
#   Both confirmed via method=create on DS218 (DSM7) and by reading
#   back a task manually created on Webber (DSM6) with synowebapi
#   method=get.
#
#   method=list always needs version=1 regardless of DSM major
#   version - unlike create/get, which use version=1 (DSM6) or
#   version=4 (DSM7). Confirmed 2026-07-31 on DS218 (DSM7): version=4
#   with list silently returned nothing usable.
#
#   The -s flag is required on DSM 7 and must be OMITTED on DSM 6 -
#   without this, DSM 6 fails every synowebapi call with "Create
#   CredRequest fail", regardless of sudo/env/HOME. Confirmed here,
#   and matches the same verified pattern already in Drive Info's
#   task_scheduler.sh (DSM7 needs -s for create, DSM6 must not have
#   it). Applied to list/create/set below via WEBAPI_FLAG.
#
#   method=set_enable with enable=false on DSM 6 v1 returned success:true
#   for every param shape tried (id=, task=, with/without real_owner)
#   without ever actually taking effect (confirmed via a follow-up
#   method=list check each time). "disable" below uses method=delete
#   instead, via the pattern already verified working on both DSM
#   versions in Drive Info's task_scheduler.sh.
#
# Usage:
#   task_setup.sh set <repeat_hour 1-11>
#   task_setup.sh remove
#----------------------------------------------------------

PKG_NAME="CPUTemp"
PKG_DEST="/var/packages/${PKG_NAME}/target"
TASK_NAME="CPU Temperature"
COMMAND="${PKG_DEST}/bin/cpu_temp_api.sh run"

# Same DSM-major-version detection syno_cpu_temp.sh itself uses.
dsm=$(get_key_value /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="/var/packages/${PKG_NAME}/var"
    API_VER=4
    WEBAPI_FLAG="-s"
else
    API_VER=1
    VAR_DIR="/var/packages/${PKG_NAME}/etc"
    WEBAPI_FLAG=""
fi

find_task_id() {
    local raw
    raw=$(synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=list version=1 2>>"${VAR_DIR}/api.log")
    echo "$raw" >> "${VAR_DIR}/api.log"
    echo "$raw" | python3 -c "
import json, sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception as e:
    sys.stderr.write('find_task_id: JSON parse failed: %s\n' % e)
    sys.exit(0)

tasks = data.get('data', {}).get('tasks', [])
match = [t for t in tasks if t.get('name') == '${TASK_NAME}']
if len(match) > 1:
    sys.stderr.write('find_task_id: WARNING %d tasks named ${TASK_NAME} found, using first (id=%s)\n' % (len(match), match[0].get('id')))
if match:
    print(match[0]['id'])
" 2>>"${VAR_DIR}/api.log"
}

build_schedule() {
    local repeat_hour="$1"
    local start_hour="$2"
    if [[ "$API_VER" -eq 4 ]]; then
        printf '{"date_type":0,"hour":%s,"minute":0,"repeat_hour":%s,"repeat_min":0,"repeat_date":1001,"week_day":"0,1,2,3,4,5,6","monthly_week":[],"last_work_hour":0,"version":4}' "$start_hour" "$repeat_hour"
    else
        printf '{"date_type":0,"hour":%s,"minute":0,"repeat_hour":%s,"repeat_date":0,"week_day":"0,1,2,3,4,5,6","last_work_hour":0}' "$start_hour" "$repeat_hour"
    fi
}

# REFERENCE ONLY - not called anywhere in this package. CPUTemp uses
# delete (see the "remove" case below) instead, because it's the only
# option confirmed to actually change state on DSM 6.
#
# Kept here for future packages: on DSM 6 v1, method=set_enable
# returns "success":true for every param shape tried below, but a
# follow-up method=list confirmed "enable" never actually changes.
# Tested 2026-08-01 on Webber (DSM 6.2.4) against a real task (id=24):
#   version=1 id=<id> enable=false                         -> success:true, no effect
#   version=1 id=<id> real_owner=root enable=false          -> success:true, no effect
#   version=1 task=<id> enable=false                        -> success:true, no effect
#   version=1 task=<id> real_owner=root enable=false        -> success:true, no effect
#   version=2 id=<id> [real_owner=root] enable=false        -> error code 103 (method
#                                                              doesn't exist at v2)
# The -s flag was correctly omitted throughout (per WEBAPI_FLAG's
# DSM6 rule) - that wasn't the issue. If DSM 6's real set_enable param
# shape ever gets found (browser network capture would be the way),
# this is where to update it. DSM 7's shape is also unconfirmed since
# testing stopped once delete proved reliable on both versions.
set_enable_task_REFERENCE_ONLY() {
    local task_id="$1"
    local enable="$2"  # "true" or "false"
    synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=set_enable version="$API_VER" \
        id="$task_id" enable="$enable"
}

ACTION="$1"
shift

case "$ACTION" in
set)
    HOUR="$1"
    if ! [[ "$HOUR" =~ ^([1-9]|1[01])$ ]]; then
        echo '{"success":false,"message":"repeat_hour must be 1-11"}'
        exit 1
    fi

    # Start the schedule at the next hour, not midnight - otherwise a
    # user enabling this at, say, 1am would wait up to 23 hours for
    # the first run. %-H strips any leading zero (date's default
    # zero-padded output, e.g. "08", would otherwise be misread as an
    # invalid octal literal by bash arithmetic).
    CURRENT_HOUR=$(date +%-H)
    START_HOUR=$(( (CURRENT_HOUR + 1) % 24 ))

    SCHEDULE=$(build_schedule "$HOUR" "$START_HOUR")
    EXTRA=$(python3 -c "
import json
print(json.dumps({
    'script': '${COMMAND}',
    'notify_enable': False,
    'notify_if_error': False,
    'notify_mail': ''
}))
")

    EXISTING_ID=$(find_task_id)

    if [[ -n "$EXISTING_ID" ]]; then
        # UNVERIFIED: assumes method=set takes the same shape as create + id
        synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=set version="$API_VER" \
            id="$EXISTING_ID" name="$TASK_NAME" owner="root" enable=true type="script" \
            schedule="$SCHEDULE" extra="$EXTRA"
    else
        synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=create version="$API_VER" \
            name="$TASK_NAME" owner="root" enable=true type="script" \
            schedule="$SCHEDULE" extra="$EXTRA"
    fi
    ;;

remove)
    EXISTING_ID=$(find_task_id)
    if [[ -z "$EXISTING_ID" ]]; then
        echo '{"success":true,"message":"No task to remove"}'
        exit 0
    fi
    # Deletes the task rather than disabling it. method=set_enable was
    # tried first (matching create/list's WEBAPI_FLAG pattern, then
    # several param shapes: id=, task=, with/without real_owner) - on
    # DSM 6 v1 it always returned success:true without actually
    # flipping "enable" in a follow-up method=list check. Rather than
    # keep guessing at an unreliable method, this uses the delete
    # pattern already verified working on both DSM versions in Drive
    # Info's task_scheduler.sh:
    #   DSM 7: -s, version=2, tasks=[{"id":..,"real_owner":".."}] (array)
    #   DSM 6: no -s, version=1, task=<id> (bare id, not array/object)
    if [[ "$dsm" -ge 7 ]]; then
        synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=delete version=2 \
            tasks="[{\"id\":${EXISTING_ID},\"real_owner\":\"root\"}]"
    else
        synowebapi --exec api=SYNO.Core.TaskScheduler method=delete version=1 \
            task="${EXISTING_ID}"
    fi
    ;;

disable)
    EXISTING_ID=$(find_task_id)
    if [[ -z "$EXISTING_ID" ]]; then
        echo '{"success":true,"message":"No task to disable"}'
        exit 0
    fi
    # Only works for DSM 7
    # See set_enable_task_REFERENCE_ONLY() above
    synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=set_enable version=2 \
        status="[{\"id\":${EXISTING_ID},\"real_owner\":\"root\",\"enable\":false}]"
    ;;

*)
    echo '{"success":false,"message":"Unknown action"}'
    exit 1
    ;;
esac
