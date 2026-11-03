#!/bin/bash
#----------------------------------------------------------
# Syno_Toolbox module: failed_logins.sh
# Failed DSM web UI and SSH sign-ins in the last 24 hours, read from
# Log Center's Connection database. First argument selects the mode:
#   summary - one line for the Info row: count in the last 24 hr plus the
#             time of the most recent failed login ever recorded
#   list    - JSON for the [View] modal: the latest N failed logins however
#             old (N = second argument, 100-500, default 100), each flagged
#             as recent if it is inside the last 24 hr
#   count   - "<all-time total> <last-24-hr total>" for deciding whether
#             [View] is shown (it is shown whenever the first number > 0)
#   count   - just the number of failed logins (an integer), so main.js can show
#             or hide [View] without reading the translated summary text. Counts
#             exactly what summary and list count. If the log can't be read it
#             prints the same error text as the other modes (not an integer),
#             which main.js treats as "nothing to view".
#
# Always prints something and exits 0 - api.cgi's run action treats
# empty output as a failure. sqlite3/jq stderr is discarded because
# synotoolbox_api.sh merges stderr into the result.
#----------------------------------------------------------

# Get DSM major version
dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)

DB="/var/log/synolog/.SYNOCONNDB"

SINCE="CAST(strftime('%s','now','-24 hours') AS INTEGER)"
WHERE="level='warning'
  AND ((protocol='DSM' AND msg LIKE '%failed to sign in to [DSM]%')
    OR (protocol='SSH' AND msg LIKE '%failed to log in via [SSH]%'))"

# [View] row limit: only the whitelisted values from Settings, else 100
limit=100
case "$2" in
    100|200|300|400|500) limit=$2 ;;
esac

if [[ ! -r "$DB" ]]; then
    echo "Cannot read $DB"
    exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 not found on this NAS"
    exit 0
fi

# DSM 6's sqlite3 has no -readonly or -json; use -readonly only where supported
ro=()
sqlite3 -help 2>&1 | grep -q -- '-readonly' && ro=(-readonly)

# "<all-time count>|<last-24-hr count>|<newest time, local>"
stats=$(sqlite3 "${ro[@]}" "$DB" \
    "SELECT count(*),
            coalesce(sum(time >= $SINCE),0),
            coalesce(strftime('%Y-%m-%d %H:%M',max(time),'unixepoch','localtime'),'')
     FROM logs WHERE $WHERE;" 2>/dev/null)
total=${stats%%|*}
rest=${stats#*|}
recent=${rest%%|*}
newest=${rest#*|}
if [[ ! "$total" =~ ^[0-9]+$ || ! "$recent" =~ ^[0-9]+$ ]]; then
    echo "Could not read the connection log"
    exit 0
fi

case "$1" in
    summary)
        if (( recent == 0 )); then
            msg="No failed login attempts in the last 24 hr"
        elif (( recent == 1 )); then
            msg="WARNING: 1 failed login attempt in the last 24 hr"
        else
            msg="WARNING: ${recent} failed login attempts in the last 24 hr"
        fi
        [[ -n "$newest" ]] && msg="${msg} (latest: ${newest})"
        echo "$msg"
        ;;
    count)
        echo "$total $recent"
        ;;
    list)
        rows=$(sqlite3 "${ro[@]}" -separator $'\x1f' "$DB" \
            "SELECT datetime(time,'unixepoch','localtime'), protocol,
                    replace(replace(replace(substr(username,1,64),char(10),' '),char(13),' '),char(9),' '),
                    ip, coalesce(uid,''), (time >= $SINCE)
             FROM logs WHERE $WHERE ORDER BY id DESC LIMIT $limit;" 2>/dev/null |
          jq -R -s -c 'split("\n") | map(select(length>0) | split("\u001f")
             | {time:.[0], service:.[1], username:.[2], ip:.[3], uid:.[4], recent:(.[5]|tonumber)})' 2>/dev/null)
        rc=$?
        [[ -z "$rows" ]] && rows="[]"
        if (( rc != 0 )) || { (( total > 0 )) && [[ "$rows" == "[]" ]]; }; then
            echo "Could not read the connection log"
            exit 0
        fi
        # Is each account the log says exists enabled or disabled now?
        # `synouser --get` prints "Expired : [true]" for a disabled account and
        # "Expired : [false]" for an enabled one. One lookup per distinct
        # username (only for entries whose log uid says the account existed);
        # a deleted account (synouser exit 255, synoerr 0x1D00) is "deleted";
        # a name that is not a plain username, or any other result, is
        # "unknown" and the UI falls back to a plain "Yes".
        acc="{}"
        while IFS= read -r u; do
            [[ "$u" =~ ^[A-Za-z0-9_@.][A-Za-z0-9_@.-]*$ ]] || continue
            out=$(synouser --get "$u" 2>&1)
            rc=$?
            exp=$(sed -n 's/^Expired[[:space:]]*:[[:space:]]*\[\(.*\)\].*/\1/p' <<<"$out" | head -n1)
            case "$exp" in
                true)  st="disabled" ;;
                false) st="enabled" ;;
                *)
                    # A deleted account makes synouser exit 255 with
                    # "SYNOUserGet failed. synoerr=[0x1D00]". Anything else
                    # that gives no Expired line stays "unknown".
                    if (( rc == 255 )) && [[ "$out" == *"synoerr=[0x1D00]"* ]]; then
                        st="deleted"
                    else
                        continue
                    fi
                    ;;
            esac
            acc=$(jq -c --arg u "$u" --arg s "$st" '. + {($u): $s}' <<<"$acc" 2>/dev/null) || acc="{}"
        done < <(jq -r '.[] | select(((.uid // "") | tostring) as $x | ($x != "" and $x != "-1")) | .username' <<<"$rows" 2>/dev/null | sort -u)

        jq -cn --argjson rows "$rows" --argjson total "$total" --argjson recent "$recent" --argjson acc "$acc" '
            {total: $total, recent: $recent,
             rows: ($rows | map({
                time, service,
                username: (.username // ""),
                ip: (.ip // ""),
                recent: (.recent == 1),
                account: (if (((.uid // "") | tostring) as $u | ($u != "" and $u != "-1"))
                          then ($acc[.username // ""] // "unknown") else "none" end),
                known: (((.uid // "") | tostring) as $u | ($u != "" and $u != "-1"))
             }))}' 2>/dev/null || echo "Could not read the connection log"
        ;;
    *)
        echo "Usage: failed_logins.sh summary|list [100-500]|count"
        ;;
esac

exit 0
