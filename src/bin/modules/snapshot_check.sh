#!/bin/bash
#--------------------------------------------------------------------------------
# snapshot_check.sh - Syno_Toolbox "Snapshots" tab
#
# Adapted from syno_snapshot_checker.sh (Synology_Snapshot_Checker).
#
# Usage (always run as root, via synotoolbox-helper -> synotoolbox_api.sh):
#   snapshot_check.sh "exclude=name1|name2"   print the HTML report, skipping those shares
#   snapshot_check.sh exclude=                print the HTML report for every Btrfs share
#   snapshot_check.sh --list                  print a JSON array of the Btrfs shared folders
#                                             (fills the Settings checklist in main.js)
#
# The report is ONE complete HTML document on stdout. main.js gets it through the
# ordinary authenticated `run` action and shows it in a sandboxed iframe. Nothing is
# written to disk and nothing is served unauthenticated, because this page tells you
# which shares are NOT protected.
#
# Per share it reports:
#   - snapshot schedule (state, type, next run)     synosharesnapshot + synoschedtask
#   - retention policy                              synoretentionconf --get
#   - immutable (WORM) setting and lock days        synoretentionconf --get-worm-lock (only on models with support_worm=yes)
#   - snapshot count, oldest, newest                /volumeN/@sharesnap/<share>/GMT*
#   - is the newest snapshot immutable / locked     /volumeN/@sharesnap/@<share>.meta
#
# Shares on a volume that is not Btrfs are listed as "not supported". Shares the user
# unticked in Settings are left out of the table and counted in the summary.
# Share names can't contain "|", so it is safe as the separator in the exclude list.
#
# DSM 6 differences (confirmed on DS1812+, DSM 6):
#   - no immutable (WORM) snapshots, so --get-worm-lock is never called there
#   - synoretentionconf --get has no RetainDay: line; "Policy type:" is a bare number
#     (0 = retain all, 1 = advanced/time-based, 20 = keep latest N) and "Recently:" is
#     only meaningful when the policy type is 20
#
# DSM 7.2 was the first DSM version to have immutable snapshots.
# Value and J series models do not have immutable snapshots.
# Officially only 20 series and newer models have immutable snapshots.
# https://kb.synology.com/en-global/DSM/tutorial/which_synology_nas_models_support_WriteOnce_and_secure_snapshots
#--------------------------------------------------------------------------------

# Same PATH synotoolbox-helper sets, so it behaves the same however it is called.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/syno/bin:/usr/syno/sbin"
# No "set -u": older bash (DSM 6) treats expanding an empty array as an unbound variable.
shopt -s nullglob

# Check if immutable (WORM) snapshots are enabled (DSM 7.2 and later 20 series + or higher models).
worm_enabled="$(/usr/syno/bin/synogetkeyvalue /etc.defaults/synoinfo.conf support_worm 2>/dev/null)"
has_worm=no
if [[ $worm_enabled == yes ]]; then
    has_worm=yes
fi

if [[ $(id -u) -ne 0 ]]; then
    echo "snapshot_check.sh must be run as root" >&2
    exit 1
fi

for cmd in synoshare synodisk synosharesnapshot synoschedtask synoretentionconf get_section_key_value jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "snapshot_check.sh: required command not found: $cmd" >&2
        exit 1
    fi
done

mode=report
exclude_arg=""
case "${1:-}" in
    --list)     mode=list ;;
    exclude=*)  exclude_arg="${1#exclude=}" ;;
esac

host_name="$(hostname)"

# HTML-escape text that came from the NAS (share names etc.)
esc() {
    # sed rather than ${var//&/&amp;}: bash 5.2 treats an unquoted & in the
    # replacement as "the matched text", older bash doesn't. sed is the same everywhere.
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# badge <ok|warn|bad|off> <text>
badge() { printf '<span class="b %s">%s</span>' "$1" "$(esc "$2")"; }

# 2026.03.09-16.00.00 -> 2026-03-09 16:00
pretty_date() {
    local d="${1:-}"
    if [[ $d =~ ^([0-9]{4})\.([0-9]{2})\.([0-9]{2})-([0-9]{2})\.([0-9]{2})\.[0-9]{2}$ ]]; then
        printf '%s-%s-%s %s:%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
            "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
    else
        printf '%s' "$d"
    fi
}

# Volume file system, asked once per volume
declare -A vol_btrfs
is_btrfs() {
    local v="$1"
    if [[ -z "${vol_btrfs[$v]:-}" ]]; then
        if synodisk --detect_fs "/$v" 2>/dev/null | grep -q 'BTRFS'; then
            vol_btrfs[$v]=yes
        else
            vol_btrfs[$v]=no
        fi
    fi
    [[ "${vol_btrfs[$v]}" == "yes" ]]
}

readarray -t shares < <(synoshare --enum ALL 2>/dev/null | tail -n +3)

#------------------------------------------------------------------ --list mode
if [[ $mode == list ]]; then
    names=()
    for share in "${shares[@]}"; do
        [[ -n "$share" ]] || continue
        path="$(synoshare --getmap "$share" 2>/dev/null | grep '\[/volume[1-9]' | head -n1 | cut -d"[" -f2 | cut -d"]" -f1)"
        [[ -n "$path" ]] || continue
        volume="$(echo "$path" | cut -d"/" -f2)"
        is_btrfs "$volume" && names+=("$share")
    done
    if (( ${#names[@]} )); then
        printf '%s\n' "${names[@]}" | sort -f | jq -R . | jq -s -c .
    else
        echo '[]'
    fi
    exit 0
fi

#---------------------------------------------------------------- report mode
declare -A excluded
if [[ -n "$exclude_arg" ]]; then
    IFS='|' read -ra ex_list <<< "$exclude_arg"
    for e in "${ex_list[@]}"; do
        [[ -n "$e" ]] && excluded["$e"]=1
    done
fi

rows_bad=""
rows_warn=""
rows_ok=""
rows_na=""
n_bad=0
n_warn=0
n_ok=0
excluded_names=()

# Sort the shares case-insensitively so rows within each status group are in name order
readarray -t shares < <(printf '%s\n' "${shares[@]}" | sort -f)

for share in "${shares[@]}"; do
    [[ -n "$share" ]] || continue

    # /volumeN/share - ignores external USB and eSATA volumes
    path="$(synoshare --getmap "$share" 2>/dev/null | grep '\[/volume[1-9]' | head -n1 | cut -d"[" -f2 | cut -d"]" -f1)"
    [[ -n "$path" ]] || continue
    volume="$(echo "$path" | cut -d"/" -f2)"

    if ! is_btrfs "$volume"; then
        rows_na+="<tr class=\"na\"><td class=\"name\">$(esc "$share")<div class=\"sub\">$(esc "$volume")</div></td><td colspan=\"5\" class=\"nacell\">Snapshots not supported - $(esc "$volume") is not a Btrfs volume</td><td>$(badge off "N/A")</td></tr>"
        continue
    fi

    if [[ -n "${excluded[$share]:-}" ]]; then
        excluded_names+=("$share")
        continue
    fi

    # Every per-share variable is reset here, so a value from the previous
    # share can never leak into this share's row.
    problems=()
    warnings=()
    c_sched=""
    c_ret=""
    c_imm=""
    c_qty=""
    c_new=""

    #---------------------------------------------------------------- schedule
    sched_state=""
    sched_type=""
    sched_next=""
    sched_repeat=""
    repeat_hours=""

    schedule_id="$(synosharesnapshot shareconf get "$share" 2>/dev/null | grep 'schedule_task_id' | head -n1 | cut -d"=" -f2 | xargs)"
    if [[ $schedule_id =~ ^[0-9]+$ ]]; then
        task="$(synoschedtask --get id="$schedule_id" 2>/dev/null)"
        sched_state="$(echo "$task" | grep 'State:' | head -n1 | cut -d"[" -f2 | cut -d"]" -f1)"
        sched_type="$(echo "$task" | grep ' Type:' | head -n1 | cut -d"[" -f2 | cut -d"]" -f1)"
        sched_next="$(echo "$task" | grep 'Next Trigger:' | head -n1 | cut -d"[" -f2 | cut -d"]" -f1)"
        # e.g. "Repeat every [6] hour(s) until [18]:[5]"
        sched_repeat="$(echo "$task" | grep 'Repeat every' | head -n1 | tr -d '[]' | xargs)"
        sched_repeat="${sched_repeat%% until*}"    # drop "until 18:5" - brackets stripped the zero padding
        if [[ $sched_repeat =~ ^Repeat\ every\ ([0-9]+)\ hour ]]; then
            repeat_hours="${BASH_REMATCH[1]}"
        fi
    fi
    has_sched=no
    [[ -n "$sched_state" ]] && has_sched=yes

    #---------------------------------------------------------------- snapshots
    snaps=()
    snapdir="/$volume/@sharesnap/$share"
    # Snapshots of an encrypted shared folder live in @<share>@ with an @<share>@.meta file
    # (confirmed on DSM 7: /volume1/@sharesnap/@Encrypted@ and @Encrypted@.meta).
    snapmeta="/$volume/@sharesnap/@${share}.meta"
    if [[ ! -d "$snapdir" && -d "/$volume/@sharesnap/@${share}@" ]]; then
        snapdir="/$volume/@sharesnap/@${share}@"
        snapmeta="/$volume/@sharesnap/@${share}@.meta"
    fi
    if [[ -d "$snapdir" ]]; then
        for d in "$snapdir"/GMT*; do
            name="${d##*/}"
            # GMT-2026.03.09-16.00.00  or  GMT+11-2026.03.09-16.00.00
            if [[ $name =~ ^GMT([+-][0-9]{1,2})?-([0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2})$ ]]; then
                snaps+=("${BASH_REMATCH[2]}|$name")
            fi
        done
    fi
    qty="${#snaps[@]}"

    #--------------------------------------------------- retention and immutable
    # A share that never had snapshots turned on still answers these commands with
    # defaults (DS218: "7 days, keep latest 32") or with a failure, so they only mean
    # something once the share has a schedule or snapshots.
    keep_days=""
    keep_latest=""
    ptype=""            # e.g. "64 (Retain by day)" on DSM 7, just "1" on DSM 6
    ptype_num=""        # first word of ptype
    ret_parts=""        # e.g. "7 daily, 4 weekly, 3 monthly"
    retention_ok=no
    worm_enabled=""     # yes | no | notset | unknown (empty on DSM 6: no immutable snapshots)
    worm_days=""

    if [[ $has_sched == yes ]]; then
        if ret="$(synoretentionconf --get "Share#" "$share" 2>/dev/null)"; then
            retention_ok=yes
            keep_days="$(echo "$ret" | grep -E '^RetainDay:' | head -n1 | cut -d":" -f2 | xargs)"
            keep_latest="$(echo "$ret" | grep -E '^Recently:' | head -n1 | cut -d":" -f2 | xargs)"
            ptype="$(echo "$ret" | grep -E '^Policy type:' | head -n1 | cut -d":" -f2- | xargs)"
            ptype_num="${ptype%% *}"
            # Time-based policy (type 1): describe the counts that are actually set.
            # "Recently:" is NOT part of this policy - it keeps its old value when
            # another policy is selected, so it must not be shown here.
            if [[ "$ptype_num" == "1" ]]; then
                for pair in Hourly:hourly Daily:daily Weekly:weekly Monthly:monthly Yearly:yearly; do
                    n="$(echo "$ret" | grep -E "^${pair%%:*}:" | head -n1 | cut -d":" -f2 | xargs)"
                    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
                        ret_parts+="${ret_parts:+, }${n} ${pair##*:}"
                    fi
                done
            fi
        else
            warnings+=("Retention not configured")
        fi
    fi

    # Immutable (WORM) snapshots only exist on DSM 7.2+, so DSM 6 never asks.
    if [[ $has_worm == yes && ( $has_sched == yes || $qty -gt 0 ) ]]; then
        # "Enable: 1" / "Lock Day: 7". For a share whose immutable setting was never
        # touched it prints "Can't get worm lock policy with prefix='Share#', name='...'"
        # (confirmed on Oscar's "downloads"), which means off. "Enable: 0" (Oscar's
        # "docker") is a share where it was once set up and then turned off.
        if worm="$(synoretentionconf --get-worm-lock "Share#" "$share" 2>/dev/null)"; then
            worm_en="$(echo "$worm" | grep -E '^Enable:' | head -n1 | cut -d":" -f2 | xargs)"
            worm_days="$(echo "$worm" | grep -E '^Lock Day:' | head -n1 | cut -d":" -f2 | xargs)"
            case "$worm_en" in
                1) worm_enabled=yes ;;
                0) worm_enabled=no ;;
                "") worm_enabled=notset ;;   # no "Enable:" line, e.g. only "Can't get worm lock policy ..."
                *) worm_enabled=unknown ;;
            esac
        else
            worm_enabled=notset
        fi
    fi

    #-------------------------------------------------------------- newest snapshot
    oldest=""
    newest=""
    newest_name=""
    newest_worm=""      # true | false | ""
    newest_lock=""
    age_note=""
    if (( qty > 0 )); then
        readarray -t sorted < <(printf '%s\n' "${snaps[@]}" | sort)
        oldest="${sorted[0]%%|*}"
        newest="${sorted[${#sorted[@]}-1]%%|*}"
        newest_name="${sorted[${#sorted[@]}-1]#*|}"

        meta="$snapmeta"
        newest_worm="$(get_section_key_value "$meta" "$newest_name" worm_lock 2>/dev/null)"
        newest_lock="$(get_section_key_value "$meta" "$newest_name" lock 2>/dev/null)"
    fi

    #--------------------------------------------------------------------- verdict
    if [[ $has_sched == no && $qty -eq 0 ]]; then
        # Snapshots were never set up - one reason, not a pile of "not configured"s
        problems+=("Snapshots not enabled")
    else
        if [[ $has_sched == no ]]; then
            problems+=("No snapshot schedule")
        elif [[ "$sched_state" != "enabled" ]]; then
            problems+=("Snapshot schedule is $sched_state")
        fi

        # worm_enabled stays empty on DSM 6, so nothing is said about immutable there.
        case "$worm_enabled" in
            no)      warnings+=("Immutable snapshots are off") ;;
            notset)  warnings+=("Immutable snapshots not set up") ;;
            unknown) warnings+=("Could not read immutable setting") ;;
        esac

        if (( qty == 0 )); then
            problems+=("No snapshots")
        else
            if [[ "$newest_worm" == "false" && "$worm_enabled" == "yes" ]]; then
                problems+=("Newest snapshot is not immutable")
            elif [[ -z "$newest_worm" && "$worm_enabled" == "yes" ]]; then
                warnings+=("Could not read newest snapshot's immutable flag")
            fi

            # Stale check - only where the expected interval is known for sure
            # (Snapshot Replication only offers daily, or daily repeating every N hours).
            interval_h=""
            if [[ -n "$repeat_hours" ]]; then
                interval_h="$repeat_hours"
            elif [[ "$sched_type" == "daily" ]]; then
                interval_h=24
            fi
            if [[ -n "$interval_h" && "$sched_state" == "enabled" ]]; then
                newest_epoch="$(date -d "${newest:0:4}-${newest:5:2}-${newest:8:2} ${newest:11:2}:${newest:14:2}:00" +%s 2>/dev/null)"
                if [[ $newest_epoch =~ ^[0-9]+$ ]]; then
                    age_h=$(( ( $(date +%s) - newest_epoch ) / 3600 ))
                    if (( age_h > interval_h * 2 )); then
                        warnings+=("Newest snapshot is ${age_h}h old (expected about every ${interval_h}h)")
                    fi
                    age_note="${age_h}h ago"
                fi
            fi
        fi
    fi

    if (( ${#problems[@]} > 0 )); then
        status=bad
        status_text="Problem"
        n_bad=$((n_bad + 1))
    elif (( ${#warnings[@]} > 0 )); then
        status=warn
        status_text="Warning"
        n_warn=$((n_warn + 1))
    else
        status=ok
        status_text="OK"
        n_ok=$((n_ok + 1))
    fi

    reasons=""
    for (( i = 0; i < ${#problems[@]}; i++ )); do
        reasons+="<div class=\"why\">$(esc "${problems[$i]}")</div>"
    done
    for (( i = 0; i < ${#warnings[@]}; i++ )); do
        reasons+="<div class=\"why\">$(esc "${warnings[$i]}")</div>"
    done

    #--------------------------------------------------------------------- cells
    dash='<span class="dash">&ndash;</span>'

    # Schedule
    if [[ $has_sched == no ]]; then
        c_sched="$(badge bad "None")"
    else
        if [[ "$sched_state" == "enabled" ]]; then
            c_sched="$(badge ok "Enabled")"
        else
            c_sched="$(badge bad "$sched_state")"
        fi
        # values come from synoschedtask, so escape each one before adding our own <br>
        sub="$(esc "$sched_type")"
        [[ -n "$sched_repeat" ]] && sub+=", $(esc "${sched_repeat,}")"
        [[ -n "$sched_next" ]] && sub+="<br>next $(esc "$sched_next")"
        c_sched+="<div class=\"sub\">$sub</div>"
    fi

    # Retention - show what the policy in force actually is
    if [[ $retention_ok == yes && "$keep_days" =~ ^[0-9]+$ && "$keep_days" -gt 0 && "$ptype" == *"Retain by day"* ]]; then
        # DSM 7 "Keep all snapshots for N days"
        c_ret="$(esc "$keep_days") days"
    elif [[ $retention_ok == yes && -n "$ret_parts" ]]; then
        # Time-based policy (DSM 6 "Advanced retention policy")
        c_ret="$(esc "$ret_parts")"
    elif [[ $retention_ok == yes && "$ptype_num" == "1" ]]; then
        c_ret="Advanced policy"
    elif [[ $retention_ok == yes && "$ptype_num" == "20" ]]; then
        c_ret="keep latest $(esc "${keep_latest:-?}")"
    elif [[ $retention_ok == yes && "$ptype_num" == "0" ]]; then
        c_ret="Keep all"
    elif [[ $retention_ok == yes && -n "$ptype" ]]; then
        # A policy type not handled above: show it as reported rather than guess
        c_ret="$(esc "$ptype")"
    elif [[ $has_sched == yes ]]; then
        c_ret="$(badge warn "Not configured")"
    else
        c_ret="$dash"
    fi

    # Immutable
    if [[ $has_worm == no ]]; then
        c_imm='<span class="dash">not supported</span>'
    else
        case "$worm_enabled" in
            yes)     c_imm="$(badge ok "On")<div class=\"sub\">$(esc "${worm_days:-?}") days</div>" ;;
            no)      c_imm="$(badge warn "Off")" ;;
            notset)  c_imm="$(badge warn "Off")<div class=\"sub\">not set up</div>" ;;
            unknown) c_imm="$(badge off "Unknown")" ;;
            *)       c_imm="$dash" ;;
        esac
    fi

    # Snapshots
    if (( qty > 0 )); then
        c_qty="$qty<div class=\"sub\">oldest $(esc "$(pretty_date "$oldest")")</div>"
    else
        c_qty="$(badge bad "None")"
    fi

    # Newest
    if (( qty > 0 )); then
        c_new="<span class=\"nw\">$(esc "$(pretty_date "$newest")")</span>"
        [[ -n "$age_note" ]] && c_new+="<div class=\"sub\">$age_note</div>"
        case "$newest_worm" in
            true)  c_new+="<div>$(badge ok "Immutable")</div>" ;;
            false) # red only when immutable is switched on for the share (then it is a real problem)
                   if [[ $worm_enabled == yes ]]; then
                       c_new+="<div>$(badge bad "Not immutable")</div>"
                   else
                       c_new+="<div>$(badge warn "Not immutable")</div>"
                   fi ;;
            *)     # DSM 6 has no immutable flag, so there is nothing to show there
                   [[ $has_worm == yes ]] && c_new+="<div>$(badge off "Immutable ?")</div>" ;;
        esac
        [[ "$newest_lock" == "true" ]] && c_new+="<div class=\"sub\">locked</div>"
    else
        c_new="$dash"
    fi

    row="<tr class=\"$status\"><td class=\"name\">$(esc "$share")<div class=\"sub\">$(esc "$volume")</div></td><td>$c_sched</td><td>$c_ret</td><td>$c_imm</td><td>$c_qty</td><td>$c_new</td><td>$(badge "$status" "$status_text")$reasons</td></tr>"

    case "$status" in
        bad)  rows_bad+="$row" ;;
        warn) rows_warn+="$row" ;;
        *)    rows_ok+="$row" ;;
    esac
done

total=$((n_bad + n_warn + n_ok))
n_excl="${#excluded_names[@]}"

#------------------------------------------------------------------------ output
cat <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Snapshots</title>
<style>
:root { color-scheme: light; }
html, body { height:100%; }
body { margin:0; padding:10px 12px; box-sizing:border-box; display:flex; flex-direction:column; overflow:hidden; font-family:Verdana,Arial,sans-serif; font-size:12px; color:#222; background:#fff; }
.scroll { flex:1 1 auto; min-height:0; overflow:auto; }
.summary { flex:0 0 auto; display:flex; flex-wrap:wrap; align-items:center; gap:8px; margin-bottom:10px; }
.summary .host { font-weight:bold; font-size:13px; margin-right:6px; }
.summary .when { color:#888; margin-left:auto; }
table { width:100%; border-collapse:collapse; }
th { position:sticky; top:0; z-index:1; text-align:left; background:#f3f5f8; color:#444; font-weight:bold; padding:6px 6px; box-shadow:inset 0 -2px 0 #d5dae1; white-space:nowrap; }
td { padding:6px 6px; border-bottom:1px solid #e6e9ee; vertical-align:top; }
td.name { font-weight:bold; }
tr.bad td:first-child { box-shadow:inset 3px 0 0 #d93025; }
tr.warn td:first-child { box-shadow:inset 3px 0 0 #e8a100; }
tr.ok td:first-child { box-shadow:inset 3px 0 0 #1e9e4a; }
tr.na td:first-child { box-shadow:inset 3px 0 0 #b8bec7; }
tr.na td { color:#888; }
td.nacell { font-style:italic; }
.sub { color:#888; font-size:11px; font-weight:normal; margin-top:2px; }
.nw { white-space:nowrap; }
.dash { color:#aaa; }
.why { color:#666; font-size:11px; margin-top:3px; }
.b { display:inline-block; padding:1px 8px; border-radius:10px; font-size:11px; font-weight:bold; white-space:nowrap; }
.b.ok   { background:#e3f5e9; color:#14793a; }
.b.warn { background:#fdf0cf; color:#8a5d00; }
.b.bad  { background:#fde4e1; color:#b3261e; }
.b.off  { background:#eceff3; color:#666; }
.note { flex:0 0 auto; margin-top:8px; max-height:3.6em; overflow:auto; color:#888; font-size:11px; }
.empty { padding:40px 0; text-align:center; color:#888; font-size:13px; }
</style>
</head>
<body>
<div class="summary">
  <span class="host">$(esc "$host_name")</span>
EOF

if (( total > 0 )); then
    printf '  %s %s %s' \
        "$(badge ok "$n_ok OK")" \
        "$( (( n_warn > 0 )) && badge warn "$n_warn Warning" || badge off "0 Warning")" \
        "$( (( n_bad > 0 )) && badge bad "$n_bad Problem" || badge off "0 Problem")"
    (( n_excl > 0 )) && printf ' %s' "$(badge off "$n_excl excluded")"
    echo
fi

cat <<EOF
  <span class="when">checked $(date '+%Y-%m-%d %H:%M')</span>
</div>
EOF

if (( total > 0 )) || [[ -n "$rows_na" ]]; then
    cat <<EOF
<div class="scroll">
<table>
<thead><tr><th>Shared folder</th><th>Schedule</th><th>Retention</th><th>Immutable</th><th>Snapshots</th><th>Newest snapshot</th><th>Status</th></tr></thead>
<tbody>
${rows_bad}${rows_warn}${rows_ok}${rows_na}
</tbody>
</table>
</div>
EOF
fi

if (( total == 0 )); then
    if (( n_excl > 0 )); then
        echo '<div class="empty">Every Btrfs shared folder is excluded. Use Settings to include some.</div>'
    elif [[ -z "$rows_na" ]]; then
        echo '<div class="empty">No shared folders were found.</div>'
    fi
fi

if (( n_excl > 0 )); then
    list=""
    for (( i = 0; i < n_excl; i++ )); do
        list+="${list:+, }$(esc "${excluded_names[$i]}")"
    done
    echo "<div class=\"note\">Excluded from this check (see Settings): $list</div>"
fi

cat <<EOF
</body>
</html>
EOF
exit 0
