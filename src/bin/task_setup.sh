#!/bin/bash
#--------------------------------------------------------------------
# Generic DSM Task Scheduler helper (SYNO.Core.TaskScheduler) - shared
# across packages/modules, not specific to any one of them. Every
# identifying detail (task name, command to run, schedule) is passed
# in by the caller; this script has no built-in notion of which
# package or module it's managing a task for, so the same file can be
# dropped into any package unmodified.
#
# Originated in CPUTemp's task_setup.sh (verified 2026-07-31 against
# real test tasks - the DSM6/7 API-version split, WEBAPI_FLAG, and
# delete-not-disable pattern below are all unchanged from that
# verification, just no longer hardcoded to one task/package).
# Generalized to support multiple named tasks with a configurable
# interval, start time, and error notification, for Syno_Toolbox's
# cpu_usage module (and any future module/package that needs one).
#
# Minute-repeat schedules (--interval-type=minute) are confirmed on
# BOTH DSM7 and DSM6 - see build_schedule/schedule_api_version for the
# exact shapes. DSM6 needed one extra piece of digging: a real DSM6
# task's repeat_min field is invisible via method=get version=1 (looks
# like a non-repeating task), but fully visible via method=get
# version=2 - confirmed 2026-09-13. So DSM6 minute-repeat uses
# version=2 for create/set, not version=1 (hourly on DSM6 is
# unaffected and still uses version=1, as originally verified).
# DSM's own Task Scheduler UI also only offers 7 discrete minute
# values (1, 5, 10, 15, 20, 25, 30) on both DSM versions - matched
# exactly below rather than allowing an arbitrary range.
#
# --interval-type=month requires DSM build 64570+ (confirmed
# 2026-09-13 via a real monthly task read back with method=get) - that
# build number is where DSM's Task Scheduler UI gained a separate
# Monthly repeat mode at all; DSM 6, DSM 7.0, and DSM 7.1 (all below
# that build) have no monthly concept whatsoever, and --interval-type=month
# is rejected outright on those rather than guessing a workaround.
#
# --interval-type=week works everywhere, but the actual schedule shape
# depends on the same build threshold: build >= 64570 uses the real
# Weekly repeat mode (repeat_date=1002, confirmed via read-back);
# older builds have no separate Weekly mode at all, so week falls back
# to Daily mode with week_day restricted to just Monday - Dave's own
# specified recipe (2026-09-13), reusing each API version's already-
# verified daily repeat_date marker, but NOT independently read-back
# confirmed the way the newer shape was.
#
# Both week and month take NO --interval: DSM's own Task Scheduler has
# no "every N weeks/months" concept (Daily/Weekly/Monthly are the only
# repeat modes, each just picking day(s)/ordinal, not a count), so per
# spec these are kept fixed: always Monday, always 00:00, and for
# monthly always the first occurrence.
#
# One more open item found alongside week/month: method=list version=1
# doesn't find a monthly-scheduled task at all (version=3 does, on
# DSM7 - DSM6's list only works at version=1 at all, per Dave
# 2026-09-13, so the version=3 fallback below is effectively a DSM7-
# only path in practice) - see find_task_id, which falls back to
# version=3 when version=1 finds nothing. Weekly/hourly/minute tasks
# are still found fine at version=1, so this is a targeted fallback,
# not a wholesale version bump.
#
# Usage:
#   task_setup.sh set --name="<task name>" --command="<full command>" \
#       --interval-type=hour --interval=<1-11> [--start=HH:MM] \
#       [--notify-email=<address>]
#   task_setup.sh set --name="<task name>" --command="<full command>" \
#       --interval-type=minute --interval=<1|5|10|15|20|25|30> \
#       [--notify-email=<address>]
#   task_setup.sh set --name="<task name>" --command="<full command>" \
#       --interval-type=week [--notify-email=<address>]
#       (always Monday 00:00 - true Weekly mode on build 64570+, Daily-
#       restricted-to-Monday on older builds, see above)
#   task_setup.sh set --name="<task name>" --command="<full command>" \
#       --interval-type=month [--notify-email=<address>]
#       (build 64570+ only - see above; always 1st occurrence, Monday 00:00)
#   task_setup.sh remove  --name="<task name>"
#   task_setup.sh disable --name="<task name>"
#   task_setup.sh find    --name="<task name>"
#
# All diagnostic output goes to stderr - the caller decides where that
# lands (e.g. `task_setup.sh ... 2>>"$SOME_LOG"`), since this script no
# longer knows which package's log file it should be writing to.
#--------------------------------------------------------------------

# Same DSM-major-version detection api.cgi/synotoolbox_api.sh use.
dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="/var/packages/${PKG_NAME}/var"
    API_VER=4
    WEBAPI_FLAG="-s"
else
    API_VER=1
    VAR_DIR="/var/packages/${PKG_NAME}/etc"
    WEBAPI_FLAG=""
fi

# Build number, not just major version - confirmed 2026-09-13: DSM's
# Task Scheduler UI only gained separate Weekly/Monthly repeat modes
# (with a day-of-week/ordinal picker) from build 64570 onward. DSM 6,
# DSM 7.0, and DSM 7.1 all predate that (a single global build-number
# threshold, since Synology's build numbering is monotonic across
# major versions) and only offer "Daily" with a day-of-week checkbox
# list built in - no separate Weekly/Monthly mode at all. Falls back
# to 0 (treated as an old build - the safer default) if this key isn't
# where expected; ASSUMPTION not independently confirmed the way
# majorversion is - worth a quick manual check if this ever misbehaves.
BUILD=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION buildnumber 2>/dev/null)
[[ "$BUILD" =~ ^[0-9]+$ ]] || BUILD=0

find_task_id() {
    local task_name="$1"
    local raw id

    # version=1 finds hourly/minute/weekly tasks (all confirmed
    # directly). Monthly tasks are NOT visible via version=1 or
    # version=2 - confirmed 2026-09-13 (a real monthly task only
    # appeared once list was called at version=3). Rather than assume
    # why, fall back to version=3 only when version=1 finds nothing -
    # this hasn't been checked for regressions (does version=3 ever
    # fail to find something version=1 does?), so it's a pragmatic
    # two-step search, not a fully understood single answer.
    #
    # synowebapi prints its own "[Line NNN] Exec WebAPI: ..." trace
    # line before the actual JSON on every call (confirmed 2026-09-13
    # - visible in every synowebapi output throughout this whole
    # project) - on stderr specifically (confirmed by Dave: `2>/dev/null`
    # alone leaves clean JSON on stdout). The previous `2>&1` merged it
    # into what got parsed, breaking json.loads() silently on every
    # call, always returning "not found" regardless of whether a match
    # existed - a longstanding bug, not something specific to DSM6.
    # Fixed by dropping stderr at capture time instead.
    raw=$(synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=list version=1 2>/dev/null)
    id=$(echo "$raw" | TASK_NAME="$task_name" python3 -c "
import json, os, sys

task_name = os.environ['TASK_NAME']
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception as e:
    sys.stderr.write('find_task_id: JSON parse failed: %s\n' % e)
    sys.exit(0)

tasks = data.get('data', {}).get('tasks', [])
match = [t for t in tasks if t.get('name') == task_name]
if len(match) > 1:
    sys.stderr.write('find_task_id: WARNING %d tasks named %r found, using first (id=%s)\n' % (len(match), task_name, match[0].get('id')))
if match:
    print(match[0]['id'])
")
    if [[ -n "$id" ]]; then
        echo "$id"
        return 0
    fi

    # DSM6's list only works at version=1 at all (confirmed by Dave
    # 2026-09-13) - skip the fallback there entirely rather than make
    # a call that can't help.
    [[ "$API_VER" -eq 4 ]] || return 0

    raw=$(synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=list version=3 2>/dev/null)
    echo "$raw" | TASK_NAME="$task_name" python3 -c "
import json, os, sys

task_name = os.environ['TASK_NAME']
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception as e:
    sys.stderr.write('find_task_id: JSON parse failed (version=3 fallback): %s\n' % e)
    sys.exit(0)

tasks = data.get('data', {}).get('tasks', [])
match = [t for t in tasks if t.get('name') == task_name]
if len(match) > 1:
    sys.stderr.write('find_task_id: WARNING %d tasks named %r found (version=3 fallback), using first (id=%s)\n' % (len(match), task_name, match[0].get('id')))
if match:
    print(match[0]['id'])
"
}

# schedule_api_version <interval_type> - version=1 (DSM6) and version=4
# (DSM7) are what create/list/get/delete all use for HOURLY schedules
# (the original CPUTemp verification). For MINUTE schedules, DSM6
# needs version=2 instead - confirmed 2026-09-13: a real DSM6 task's
# repeat_min field is invisible via method=get version=1 (looks like a
# non-repeating task), but fully visible via method=get version=2. The
# task's repeat_min was clearly already stored correctly either way,
# so this is a read-schema difference, not proof that create/set
# itself needs version=2 - but since version=2's schema is the one
# confirmed to include repeat_min at all, matching it for create/set
# too is the safer bet than assuming version=1 accepts the field just
# because it was never seen to reject it outright. DSM7 needs no such
# adjustment - minute-repeat was already confirmed directly at
# version=4, same as hourly.
schedule_api_version() {
    local interval_type="$1"
    if [[ "$API_VER" -eq 4 ]]; then
        echo 4
    elif [[ "$interval_type" == "minute" ]]; then
        echo 2
    else
        echo 1
    fi
}

# build_schedule <interval_type> <interval> <start_hour> <start_minute>
build_schedule() {
    local interval_type="$1" interval="$2" start_hour="$3" start_minute="$4"

    if [[ "$interval_type" == "week" || "$interval_type" == "month" ]]; then
        # Confirmed 2026-09-13 by reading back real DSM7 tasks on a
        # build >= 64570 (the build where DSM's Task Scheduler UI
        # gained separate Weekly/Monthly repeat modes - see BUILD's
        # detection comment above):
        #   - Weekly (Repeat=Weekly, Friday): repeat_date=1002,
        #     week_day="5" (0=Sun..6=Sat, single day as a string)
        #   - Monthly (Repeat=Monthly, First+Monday): repeat_date=1003,
        #     week_day="1", monthly_week=["first"]
        #
        # Kept deliberately simple per spec: always Monday ("1") at
        # 00:00, and for monthly always the first occurrence - no
        # user-configurable day/ordinal, and no "every N weeks/months"
        # concept, since DSM's own Task Scheduler UI doesn't offer one
        # either.
        if [[ "$interval_type" == "month" ]]; then
            # No equivalent at all below build 64570 - confirmed
            # 2026-09-13: DSM 6, DSM 7.0, and DSM 7.1's Task Scheduler
            # only offers "Daily" with a day-of-week checkbox list
            # built in, with no monthly concept whatsoever (not even
            # as a workaround through another mode).
            if [[ "$BUILD" -lt 64570 ]]; then
                echo "task_setup.sh: --interval-type=month needs DSM build 64570 or later (DSM 6, 7.0, and 7.1 have no monthly repeat mode at all, confirmed 2026-09-13) - this NAS is build ${BUILD}" >&2
                return 1
            fi
            if [[ "$API_VER" -ne 4 ]]; then
                echo "task_setup.sh: --interval-type=month is only confirmed for DSM7 - DSM6 has not been checked, see this script's header comment" >&2
                return 1
            fi
            printf '{"date_type":0,"hour":0,"minute":0,"repeat_hour":0,"repeat_min":0,"repeat_date":1003,"week_day":"1","monthly_week":["first"],"last_work_hour":0,"version":4}'
            return 0
        fi

        # interval_type == "week"
        if [[ "$BUILD" -ge 64570 ]]; then
            if [[ "$API_VER" -ne 4 ]]; then
                echo "task_setup.sh: build ${BUILD} reports the newer Weekly/Monthly UI but this isn't DSM7 - unexpected combination, refusing rather than guessing" >&2
                return 1
            fi
            printf '{"date_type":0,"hour":0,"minute":0,"repeat_hour":0,"repeat_min":0,"repeat_date":1002,"week_day":"1","monthly_week":[],"last_work_hour":0,"version":4}'
        else
            # Older builds (DSM6, DSM 7.0/7.1) have no separate Weekly
            # mode - achieve the same result via Daily's own day-of-
            # week filter, restricted to just Monday ("1") instead of
            # every day ("0,1,2,3,4,5,6"). This is Dave's own specified
            # recipe (2026-09-13), reusing each API version's already-
            # verified daily repeat_date marker (1001 for v4, 0 for
            # v1) - NOT independently read-back confirmed the way the
            # build>=64570 shape above was, so worth a real create+get
            # round trip if this ever misbehaves.
            if [[ "$API_VER" -eq 4 ]]; then
                printf '{"date_type":0,"hour":0,"minute":0,"repeat_hour":0,"repeat_min":0,"repeat_date":1001,"week_day":"1","monthly_week":[],"last_work_hour":0,"version":4}'
            else
                printf '{"date_type":0,"hour":0,"minute":0,"repeat_hour":0,"repeat_date":0,"week_day":"1","last_work_hour":0}'
            fi
        fi
        return 0
    fi

    if [[ "$interval_type" == "minute" ]]; then
        # Confirmed 2026-09-13 by reading back real tasks created via
        # Control Panel > Task Scheduler on both DSM6 and DSM7 (Daily,
        # start 00:00, "Continue running within the same day" checked,
        # Repeat=Every 5 minutes, Last run time 23:55). repeat_hour
        # must be explicitly 0 (not omitted) alongside repeat_min.
        # last_work_hour is 23 (the whole day) - there's no separate
        # minute-level "last run" field, since the repeat_min pattern
        # itself naturally continues to :55 within that hour. This is
        # a fixed "run all day, every N minutes" shape - start_hour/
        # start_minute are intentionally ignored for this mode (always
        # 0/0) rather than threaded through, since there's no reason
        # for cpu_usage-style continuous sampling to have a partial-day
        # window.
        #
        # repeat_date differs by DSM version - 1001 on DSM7, 0 on DSM6
        # - matching exactly what the original hourly verification
        # already found for each version's "daily repeat" marker.
        # "version":4 and "monthly_week" are DSM7/v4-only fields, same
        # as the hourly shape below.
        #
        # repeat_hour_store_config/repeat_min_store_config also
        # appeared in both read-backs but are NOT included here - they
        # look like UI dropdown-history metadata, not something the
        # API requires, but that's an assumption: if create/set ever
        # misbehaves for minute-repeat, try adding them back in.
        if [[ "$API_VER" -eq 4 ]]; then
            printf '{"date_type":0,"hour":0,"minute":0,"repeat_hour":0,"repeat_min":%s,"repeat_date":1001,"week_day":"0,1,2,3,4,5,6","monthly_week":[],"last_work_hour":23,"version":4}' \
                "$interval"
        else
            printf '{"date_type":0,"hour":0,"minute":0,"repeat_hour":0,"repeat_min":%s,"repeat_date":0,"week_day":"0,1,2,3,4,5,6","last_work_hour":23}' \
                "$interval"
        fi
        return 0
    fi

    if [[ "$interval_type" != "hour" ]]; then
        echo "task_setup.sh: --interval-type=${interval_type} is not verified - see this script's header comment" >&2
        return 1
    fi

    # Fixed "run all day, every N hours" shape - start_hour/start_minute
    # are intentionally ignored (always 0/0), same treatment the
    # minute-type branch above already gives those two params, for the
    # same reason (no case here needs a partial-day window either).
    #
    # last_work_hour:23 mirrors the minute-type branch's already-
    # confirmed "whole day" value (real DSM task read-back, 2026-09-13).
    # The previous last_work_hour:0 here was never independently
    # verified for hour-type the way 23 was for minute-type, and a live
    # test on 2026-09-25/26 (Dave, schedule_ups_connected, start 11:00,
    # repeat every 6h) only ran twice (11:00, 13:00) before an unrelated
    # Edit-task-dialog interaction reset the schedule's stored
    # hour/last_work_hour fields mid-test - inconclusive on whether
    # last_work_hour:0 would have left a dead window before the next
    # day's start time, but not worth re-risking when 23 is the shape
    # that's actually confirmed. Re-verify by deleting and recreating
    # the task hands-off (no Edit-dialog interaction) and watching a
    # full 24h, including across midnight, if this ever needs re-
    # checking.
    if [[ "$API_VER" -eq 4 ]]; then
        printf '{"date_type":0,"hour":0,"minute":0,"repeat_hour":%s,"repeat_min":0,"repeat_date":1001,"week_day":"0,1,2,3,4,5,6","monthly_week":[],"last_work_hour":23,"version":4}' \
            "$interval"
    else
        printf '{"date_type":0,"hour":0,"minute":0,"repeat_hour":%s,"repeat_date":0,"week_day":"0,1,2,3,4,5,6","last_work_hour":23}' \
            "$interval"
    fi
}

# REFERENCE ONLY - not called anywhere in this script. Delete is used
# instead (see "remove" below), because it's the only option confirmed
# to actually change state on DSM 6.
#
# Kept here for reference: on DSM 6 v1, method=set_enable returns
# "success":true for every param shape tried below, but a follow-up
# method=list confirmed "enable" never actually changes. Tested
# 2026-08-01 on a real DSM 6.2.4 task (id=24):
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

ACTION="${1:-}"
shift || true

TASK_NAME=""
COMMAND=""
INTERVAL_TYPE="hour"
INTERVAL=""
START=""
NOTIFY_EMAIL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name=*)          TASK_NAME="${1#--name=}" ;;
        --command=*)        COMMAND="${1#--command=}" ;;
        --interval-type=*)  INTERVAL_TYPE="${1#--interval-type=}" ;;
        --interval=*)        INTERVAL="${1#--interval=}" ;;
        --start=*)              START="${1#--start=}" ;;
        --notify-email=*) NOTIFY_EMAIL="${1#--notify-email=}" ;;
        *) echo "task_setup.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [[ -z "$TASK_NAME" ]]; then
    echo '{"success":false,"message":"--name is required"}'
    exit 1
fi

case "$ACTION" in
set)
    if [[ -z "$COMMAND" ]]; then
        echo '{"success":false,"message":"--command is required"}'
        exit 1
    fi

    if [[ "$INTERVAL_TYPE" == "hour" ]]; then
        if ! [[ "$INTERVAL" =~ ^([1-9]|1[01])$ ]]; then
            echo '{"success":false,"message":"--interval must be 1-11 for --interval-type=hour"}'
            exit 1
        fi
    elif [[ "$INTERVAL_TYPE" == "minute" ]]; then
        # DSM's own Task Scheduler UI only offers these 7 values for a
        # minute-repeat schedule (confirmed on both DSM6 and DSM7) -
        # matching that exactly rather than allowing an arbitrary 1-59
        # range, since values outside this set were never exercised
        # through the UI and might not behave as expected.
        case "$INTERVAL" in
            1|5|10|15|20|25|30) ;;
            *)
                echo '{"success":false,"message":"--interval must be one of 1, 5, 10, 15, 20, 25, 30 for --interval-type=minute"}'
                exit 1
                ;;
        esac
    elif [[ "$INTERVAL_TYPE" == "week" || "$INTERVAL_TYPE" == "month" ]]; then
        # No --interval concept for these - see build_schedule's
        # comment. Fixed Monday 00:00 (first occurrence for monthly).
        :
    else
        echo "{\"success\":false,\"message\":\"Unknown --interval-type: ${INTERVAL_TYPE}\"}"
        exit 1
    fi

    if [[ "$INTERVAL_TYPE" == "minute" || "$INTERVAL_TYPE" == "week" || "$INTERVAL_TYPE" == "month" ]]; then
        # Fixed shape - see build_schedule's comment for why --start
        # isn't threaded through for any of these three types.
        START_HOUR=0
        START_MINUTE=0
    elif [[ -n "$START" ]]; then
        if ! [[ "$START" =~ ^([0-1][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
            echo '{"success":false,"message":"--start must be HH:MM (24-hour)"}'
            exit 1
        fi
        # 10#$x forces base-10 so bash arithmetic doesn't misread a
        # leading-zero hour/minute (e.g. "08") as an invalid octal
        # literal.
        START_HOUR=$((10#${START%%:*}))
        START_MINUTE=$((10#${START##*:}))
    else
        # Default: start at the next hour, so enabling this at, say,
        # 1am doesn't wait up to 23 hours for the first run.
        CURRENT_HOUR=$(date +%-H)
        START_HOUR=$(( (CURRENT_HOUR + 1) % 24 ))
        START_MINUTE=0
    fi

    SCHEDULE=$(build_schedule "$INTERVAL_TYPE" "$INTERVAL" "$START_HOUR" "$START_MINUTE") || exit 1

    if [[ -n "$NOTIFY_EMAIL" ]]; then
        NOTIFY_ENABLE=true
        NOTIFY_IF_ERROR=true
    else
        NOTIFY_ENABLE=false
        NOTIFY_IF_ERROR=false
    fi
    # NOTE: notify_enable/notify_if_error/notify_mail were accepted
    # without error by the original verified create() call, but
    # whether DSM actually sends an email on failure was never
    # specifically tested - only that create() itself succeeded.
    EXTRA=$(COMMAND="$COMMAND" NOTIFY_ENABLE="$NOTIFY_ENABLE" NOTIFY_IF_ERROR="$NOTIFY_IF_ERROR" NOTIFY_EMAIL="$NOTIFY_EMAIL" python3 -c "
import json, os
print(json.dumps({
    'script': os.environ['COMMAND'],
    'notify_enable': os.environ['NOTIFY_ENABLE'] == 'true',
    'notify_if_error': os.environ['NOTIFY_IF_ERROR'] == 'true',
    'notify_mail': os.environ['NOTIFY_EMAIL']
}))
")

    EXISTING_ID=$(find_task_id "$TASK_NAME")
    SCHEDULE_VER="$(schedule_api_version "$INTERVAL_TYPE")"

    if [[ -n "$EXISTING_ID" ]]; then
        # method=set was previously UNVERIFIED for taking the full
        # create-style schedule payload, and is now confirmed NOT to
        # work that way: Dave, 2026-09-26, changing an already-enabled
        # hourly task's interval (1h -> 4h) via this path silently
        # returned success but left the real DSM task half-configured
        # (start reset to next-hour, "Continue running within the same
        # day" unchecked, repeat effectively 0) instead of applying the
        # new schedule. Deleting and recreating instead, reusing the
        # exact delete call already confirmed reliable on both DSM
        # versions by the "remove" action below, rather than guessing
        # at a corrected method=set shape.
        if [[ "$dsm" -ge 7 ]]; then
            synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=delete version=2 \
                tasks="[{\"id\":${EXISTING_ID},\"real_owner\":\"root\"}]" >/dev/null
        else
            synowebapi --exec api=SYNO.Core.TaskScheduler method=delete version=1 \
                task="${EXISTING_ID}" >/dev/null
        fi
    fi

    synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=create version="$SCHEDULE_VER" \
        name="$TASK_NAME" owner="root" enable=true type="script" \
        schedule="$SCHEDULE" extra="$EXTRA"
    ;;

remove)
    EXISTING_ID=$(find_task_id "$TASK_NAME")
    if [[ -z "$EXISTING_ID" ]]; then
        echo '{"success":true,"message":"No task to remove"}'
        exit 0
    fi
    # Deletes the task rather than disabling it - see
    # set_enable_task_REFERENCE_ONLY above for why. Pattern verified
    # working on both DSM versions:
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
    EXISTING_ID=$(find_task_id "$TASK_NAME")
    if [[ -z "$EXISTING_ID" ]]; then
        echo '{"success":true,"message":"No task to disable"}'
        exit 0
    fi
    # Only works for DSM 7 - see set_enable_task_REFERENCE_ONLY above.
    synowebapi $WEBAPI_FLAG --exec api=SYNO.Core.TaskScheduler method=set_enable version=2 \
        status="[{\"id\":${EXISTING_ID},\"real_owner\":\"root\",\"enable\":false}]"
    ;;

find)
    EXISTING_ID=$(find_task_id "$TASK_NAME")
    if [[ -n "$EXISTING_ID" ]]; then
        echo "{\"success\":true,\"exists\":true,\"id\":${EXISTING_ID}}"
    else
        echo '{"success":true,"exists":false}'
    fi
    ;;

*)
    echo '{"success":false,"message":"Unknown action"}'
    exit 1
    ;;
esac
