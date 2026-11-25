#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Synology security advisory monitor
#
# Checks https://www.synology.com/en-global/security/advisory for:
#   - new advisories
#   - existing advisories whose "Last Updated" date has changed
#
# Exit codes (for DSM Task Scheduler "send run details by email"):
#   0 = nothing changed (or first run, baseline saved)
#   1 = new/updated advisories found, OR the check itself failed
#   2 = bad command line options
#
# State is kept in synology_advisories.state next to this script.
# The state file is only updated after a successful fetch and parse.
#
# Every NEW/UPDATED advisory found is also appended to synology_advisories.history
# (same folder as the state file) and kept for HISTORY_DAYS days. When run
# outside Task Scheduler the recent history is shown, so changes found earlier
# are still listed when someone comes back later. Every advisory the page lists
# as Ongoing is always shown (and kept in the history) until it is no longer
# Ongoing. When run from Task Scheduler only the changes found by that run are
# printed (and the email sent).
#
# Only the first page of the advisory list (the latest 20) is read. Checked
# against all 200 advisories: the only Ongoing one was the latest.
#
# The list page is read from several regional sites (en-global, en-au, en-us)
# and merged, keeping the newest "Last Updated" per advisory. Synology's CDN can
# serve a stale copy of the list page on one site while another is up to date, so
# a single source can miss new or updated advisories for hours.
#
# Links in the reports point at the regional site that had the newest "Last
# Updated" for that advisory (e.g. .../en-au/security/advisory/Synology_SA_26_21),
# because the generic https://www.synology.com/security/advisory/... link
# redirects to en-global, which may still be serving the stale page.
#------------------------------------------------------------------------------

URL="https://www.synology.com/en-global/security/advisory"   # shown in reports
# Every one of these is fetched and merged. At least one must work.
# Order matters on a tie (same "Last Updated" on several sites): the first wins.
URLS=(
    "https://www.synology.com/en-au/security/advisory"
    "https://www.synology.com/en-uk/security/advisory"
    "https://www.synology.com/en-global/security/advisory"
    "https://www.synology.com/en-us/security/advisory"
)
SITE_BASE="https://www.synology.com"
# Fallback only, for advisories whose source site is unknown (redirects to en-global)
LINK_BASE="https://www.synology.com/security/advisory"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_ROWS=5        # fewer parsed rows than this = page layout probably changed
HISTORY_DAYS=14   # how long new/updated advisories stay listed
STATE_KEEP=30     # advisories remembered in the state file
UA="Mozilla/5.0 (compatible; synology-advisory-check)"

if [[ "$SCRIPT_DIR" =~ Syno_Toolbox ]]; then
    dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
    if [[ $dsm -ge 7 ]]; then
        STATE_FILE="/var/packages/Syno_Toolbox/var/synology_advisories.state"
    else
        STATE_FILE="/var/packages/Syno_Toolbox/etc/synology_advisories.state"
    fi
else
    STATE_FILE="$SCRIPT_DIR/synology_advisories.state"
fi

debug=""
html_files=()

usage(){
    cat <<EOF
Usage: ${0##*/} [--debug] [--file page.html ...] [--state state_file]

  --debug        Print the parsed advisory list and keep the downloaded HTML
                 (saved next to the script as synology_advisory_page_<site>.html)
  --file FILE    Parse a local HTML file instead of downloading (for testing).
                 Repeat to merge several files, as the script does with the sites
  --state FILE   Use a different state file
  --help         Show this help
EOF
}

fail(){
    echo "ERROR: $*"
    exit 1
}

is_schedule_running(){ 
    # $1 is script's filename. e.g. syno_hdd_db.sh etc
    local file="/usr/syno/etc/esynoscheduler/esynoscheduler.db"
    local rows offset task status pid result

    # Get number of rows in database
    rows=$(sqlite3 "${file}" <<ECNT
SELECT COUNT(*) from task;
.quit
ECNT
)
    # Check if script is running from task scheduler
    offset="0"
    while [[ $rows != "$offset" ]]; do
        task=$(sqlite3 "$file" "SELECT operation FROM task WHERE rowid = (SELECT rowid FROM task LIMIT 1 OFFSET ${offset});")
        if echo "$task" | grep -q "$1"; then
            status=$(sqlite3 "$file" "SELECT status FROM task WHERE rowid = (SELECT rowid FROM task LIMIT 1 OFFSET ${offset});")
            pid=$(echo "$status" | cut -d"[" -f2 | cut -d"]" -f1)
            if [[ $pid -gt "0" ]]; then
                result=$((result +pid))
            fi
        fi
        offset=$((offset +1))
    done
    [ -n "$result" ] || return 1
}

# Always pass -o with the full alphabet/digits so long options parse reliably
if ! opts=$(getopt -o abcdefghijklmnopqrstuvwxyz0123456789 \
        -l debug,file:,state:,help -n "${0##*/}" -- "$@"); then
    usage
    exit 2
fi
eval set -- "$opts"
while true; do
    case "$1" in
        --debug) debug="yes"; shift ;;
        --file)  html_files+=("$2"); shift 2 ;;
        --state) STATE_FILE="$2"; shift 2 ;;
        --help)  usage; exit 0 ;;
        --)      shift; break ;;
        *)       usage; exit 2 ;;
    esac
done

HISTORY_FILE="${STATE_FILE%.state}.history"

set_perms(){
    if [[ "$SCRIPT_DIR" =~ Syno_Toolbox ]]; then
        chmod 0644 "$1"
    else
        chmod 0666 "$1"
    fi
}

# Prints the history file newest first, in the same layout as a change report.
# $1 = history file, $2 = current advisory list (to know which are still Ongoing),
# $3 = "html" to make the links clickable in Syno_Toolbox.
show_history(){
    awk -F'\t' -v base="$LINK_BASE" -v sbase="$SITE_BASE" -v days="$HISTORY_DAYS" -v html="$3" '
    # Link to the site that has the newest copy: the current list says which,
    # else the site saved with the history entry, else the generic link
    function link(adv, hsite,   s, u, st) {
        s = adv; gsub(/[-:]/, "_", s)
        st = ((adv in site) && site[adv] != "") ? site[adv] : hsite
        if (st != "" && st != "-") { u = sbase "/" st "/security/advisory/" s } else { u = base "/" s }
        return (html == "html") ? "<a href=\"" u "\">" u "</a>" : u
    }
    # Current severity (Critical / Important ...) and status (Resolved / Accepted /
    # Ongoing ...) as shown on the page
    function stline(a) {
        if ((a in sev) && sev[a] != "" && sev[a] != "-") { printf "         Severity: %s\n", sev[a] }
        if ((a in lab) && lab[a] != "" && lab[a] != "-") { printf "         Status: %s\n", lab[a] }
    }
    function emit(k) {
        shown[ad[k]] = 1
        if (ty[k] == "NEW") {
            printf "NEW:     %s\n", ti[k]; stline(ad[k])
            printf "         Last Updated: %s\n", lu[k]
        } else {
            printf "UPDATED: %s\n", ti[k]; stline(ad[k])
            printf "         Last Updated: %s (was %s)\n", lu[k], pv[k]
        }
        printf "         Detected: %s\n         %s\n \n", dd[k], link(ad[k], hs[k])
    }
    # first file = current advisory list: id, last updated, title, icon status, status text, severity, site
    NR == FNR {
        lab[$1] = $5
        sev[$1] = $6
        site[$1] = $7
        if ($4 == "ongoing") { mo++; oid[mo] = $1; oti[mo] = $3; olu[mo] = $2 }
        next
    }
    { n++; ep[n] = $1; dd[n] = $2; ty[n] = $3; ad[n] = $4; lu[n] = $5; pv[n] = $6; ti[n] = $7; hs[n] = $8 }
    END {
        if (n == 0 && mo == 0) { exit }
        printf "Synology security advisory changes in the last %s days, and any still Ongoing:\n \n", days
        # newest detection first, entries found in the same run keep page order.
        # Each advisory is shown once, using its newest entry, so a NEW that was
        # later UPDATED (e.g. to Resolved) only appears as the UPDATED one.
        i = n
        while (i >= 1) {
            j = i
            while (j > 1 && ep[j-1] == ep[i]) { j-- }
            for (k = j; k <= i; k++) {
                if (!(ad[k] in shown)) { emit(k) }
            }
            i = j - 1
        }
        # Ongoing advisories with no history entry (e.g. already Ongoing before the first run)
        for (q = 1; q <= mo; q++) {
            if (oid[q] in shown) { continue }
            printf "ONGOING: %s\n", oti[q]; stline(oid[q])
            printf "         Last Updated: %s\n         %s\n \n", olu[q], link(oid[q], "")
        }
    }' "$2" "$1"
}

# ---- Parse one list page ----------------------------------------------------
# parse_page <html file> <output tsv>
# Layout-agnostic: strip tags to plain text lines, then pair each advisory
# title line ("Synology-SA-26:14 PHP2Shell") with the first date line after it
# ("2026-10-22 19:51:04 UTC+8"), which is the Last Updated column.
# Output (tab separated): id <TAB> last updated <TAB> title <TAB> icon status (ongoing/resolved/-)
#                         <TAB> status text (Resolved, Accepted, Ongoing...; "Resolved" if missing)
#                         <TAB> severity (Critical, Important, Moderate, Low, Not Affected; "-" if not found)
# The caller appends a 7th column: the site the row came from (en-au, en-uk ...).
parse_page(){
    awk '
    BEGIN { RS = "<" }
    {
        i = index($0, ">")
        # The Status column is an icon: <i class="icon_status icon_status_ongoing">
        # (or icon_status_resolved). Emit it as a marker line so the status does not
        # depend on the page language.
        if (i > 0 && match(substr($0, 1, i - 1), /icon_status_[a-z]+/)) {
            print "@@STATUS@@" substr(substr($0, 1, i - 1), RSTART + 12, RLENGTH - 12)
        }
        t = (i > 0) ? substr($0, i + 1) : $0
        gsub(/&nbsp;/, " ", t); gsub(/&lt;/, "<", t); gsub(/&gt;/, ">", t)
        gsub(/&quot;/, "\"", t); gsub(/&#39;/, "\047", t); gsub(/&amp;/, "\\&", t)
        gsub(/[ \t\r\n]+/, " ", t)
        sub(/^ /, "", t); sub(/ $/, "", t)
        if (t != "") print t
    }' "$1" \
    | awk '
    # The page renders the date as: <time>2026-10-30 08:42:40</time> UTC+8
    # so the date and the UTC offset arrive as two separate text lines.
    function emit(   lab) {
        if (pend) {
            # st  = icon class: "ongoing" or "resolved" (language independent)
            # lbl = the status text next to the icon (Resolved, Accepted, Ongoing...)
            lab = lbl
            if (lab == "") { lab = (st == "ongoing") ? "Ongoing" : ((st != "") ? "Resolved" : "-") }
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, dt, title, (st == "" ? "-" : st), lab, (sev == "" ? "-" : sev)
            pend = 0
            title = ""
        }
    }
    /^Synology-SA-[0-9][0-9]:[0-9][0-9]/ {
        emit()
        title = $0
        st = ""; lbl = ""; sev = ""; want = 0
        split($0, a, " ")
        id = a[1]
        next
    }
    /^@@STATUS@@/ {
        if (title != "" && !pend) { st = substr($0, 11); want = 1 }
        next
    }
    # the line right after the icon is its text; anything with digits, ":" or "@" is not a label
    want {
        want = 0
        if (title != "" && !pend && $0 !~ /[0-9:@]/ && length($0) <= 30) { lbl = $0; next }
    }
    # the Severity column is plain text between the title and the status icon
    # (matched case-insensitively: the page may say "Not affected" or "Not Affected")
    title != "" && !pend && sev == "" && tolower($0) ~ /^(critical|important|moderate|low|not affected)$/ {
        sev = $0
        next
    }
    pend {
        if ($0 ~ /^UTC[+-][0-9]+/) {
            split($0, z, " ")
            dt = dt " " z[1]
        }
        emit()
        next
    }
    title != "" && match($0, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
        if (id in seen) {
            title = ""
            next
        }
        seen[id] = 1
        dt = substr($0, RSTART, RLENGTH)
        rest = substr($0, RLENGTH + 1)
        if (rest ~ /^ UTC[+-][0-9]+/) {
            split(rest, z, " ")
            dt = dt " " z[1]
        }
        pend = 1
    }
    END { emit() }' > "$2"
}

# Merge advisory lists (tab separated, same layout as the state file): keeps the
# newest "Last Updated" per advisory ID, so a stale copy of the page can never
# hide a change or roll a date back. On a tie the first file wins. Newest ID first.
merge_lists(){
    awk -F'\t' '
    { d = substr($2, 1, 19)
      if (!($1 in best) || d > bd[$1]) { best[$1] = $0; bd[$1] = d } }
    END { for (k in best) print best[k] }' "$@" | LC_ALL=C sort -t"$(printf '\t')" -k1,1r
}

tmp_dir="$(mktemp -d)" || fail "Could not create temp directory"
trap 'rm -rf "$tmp_dir"' EXIT

new_list="$tmp_dir/new.tsv"

# ---- Get and parse every source ---------------------------------------------
sources=()
if [[ ${#html_files[@]} -gt 0 ]]; then
    for f in "${html_files[@]}"; do
        [[ -r $f ]] || fail "Cannot read $f"
        sources+=("$f")
    done
else
    sources=("${URLS[@]}")
fi

parts=()
src_errors=""
maxrows=0
n=0
for src in "${sources[@]}"; do
    n=$((n + 1))
    page="$tmp_dir/page_$n.html"
    part="$tmp_dir/part_$n.tsv"
    if [[ ${#html_files[@]} -gt 0 ]]; then
        label="$(basename -- "$src")"
        cp -- "$src" "$page" || { src_errors+="$label: could not copy; "; continue; }
    else
        label="${src#*synology.com/}"; label="${label%%/*}"
        curl -fsSL --max-time 60 -A "$UA" "$src" -o "$page"
        rc=$?
        if [[ $rc -ne 0 ]]; then
            src_errors+="$label: download failed (curl exit code $rc); "
            continue
        fi
    fi

    if [[ $debug == "yes" ]]; then
        cp -- "$page" "$SCRIPT_DIR/synology_advisory_page_${label//[^A-Za-z0-9._-]/_}.html"
    fi

    parse_page "$page" "$part"
    # Remember which site each row came from, so reports can link to the newest copy
    # (not for local --file tests, where the label is a file name)
    if [[ ${#html_files[@]} -eq 0 ]]; then
        awk -F'\t' -v OFS='\t' -v s="$label" '{ print $0, s }' "$part" > "$part.site" \
            && mv -- "$part.site" "$part"
    fi
    prows=$(wc -l < "$part")
    [[ $debug == "yes" ]] && echo "Source $label: parsed $prows advisories"
    if [[ $prows -lt $MIN_ROWS ]]; then
        src_errors+="$label: only $prows advisories parsed; "
        continue
    fi
    parts+=("$part")
    [[ $prows -gt $maxrows ]] && maxrows=$prows
done

if [[ ${#parts[@]} -eq 0 ]]; then
    fail "No usable advisory source (expected at least $MIN_ROWS advisories). ${src_errors}If the pages did download, the layout may have changed: run with --debug and check the synology_advisory_page_*.html files"
fi
[[ $debug == "yes" && -n $src_errors ]] && echo "Skipped: $src_errors"

# Merge, then keep only the newest $maxrows so a source with an older window
# can't add advisories that have scrolled off the other pages.
merge_lists "${parts[@]}" | head -n "$maxrows" > "$new_list"
rows=$(wc -l < "$new_list")

if [[ $debug == "yes" ]]; then
    echo "Merged $rows advisories:"
    cat "$new_list"
    echo
fi

# ---- First run: save baseline ----------------------------------------------
if [[ ! -f $STATE_FILE ]]; then
    cp -- "$new_list" "$STATE_FILE" || fail "Could not write $STATE_FILE"
    if [[ "$SCRIPT_DIR" =~ Syno_Toolbox ]]; then
        chmod 0644 "$STATE_FILE"
    else
        chmod 0666 "$STATE_FILE"
    fi
    if is_schedule_running "$(basename -- "$0")" && [[ ! "$SCRIPT_DIR" =~ Syno_Toolbox ]]; then
        echo "First run: saved baseline of $rows advisories to $STATE_FILE"
    else
        echo "First run: saved baseline of $rows advisories"
    fi
    exit 0
fi

# ---- Compare ----------------------------------------------------------------
# Besides the printable report, the awk also writes one line per change to
# events.tsv for the history file (tab separated):
#   detected epoch, detected date, NEW|UPDATED, id, last updated, previous last updated (or -), title, site
now="$(date +%s)"
today="$(date '+%Y-%m-%d')"
events="$tmp_dir/events.tsv"
: > "$events"

changes="$(awk -F'\t' -v base="$LINK_BASE" -v sbase="$SITE_BASE" -v now="$now" -v today="$today" -v ev="$events" '
# Link to the site that had the newest copy of the advisory; generic link if unknown
function link(id, st,   s) {
    s = id; gsub(/[-:]/, "_", s)
    if (st != "" && st != "-") { return sbase "/" st "/security/advisory/" s }
    return base "/" s
}
function stl(l, s,   o) {
    o = ""
    if (s != "" && s != "-") { o = "         Severity: " s "\n" }
    if (l != "" && l != "-") { o = o "         Status: " l "\n" }
    return o
}
NR == FNR { old[$1] = $2; if (minid == "" || $1 < minid) { minid = $1 }; next }
{
    if (!($1 in old)) {
        # older than anything already tracked = the list window moved, not a new advisory
        if (minid != "" && $1 < minid) { next }
        printf "NEW:     %s\n%s         Last Updated: %s\n         %s\n \n", $3, stl($5, $6), $2, link($1, $7)
        printf "%s\t%s\tNEW\t%s\t%s\t-\t%s\t%s\n", now, today, $1, $2, $3, $7 >> ev
    } else if (substr($2, 1, 19) > substr(old[$1], 1, 19)) {   # only a newer date counts as updated
        printf "UPDATED: %s\n%s         Last Updated: %s (was %s)\n         %s\n \n", $3, stl($5, $6), $2, old[$1], link($1, $7)
        printf "%s\t%s\tUPDATED\t%s\t%s\t%s\t%s\t%s\n", now, today, $1, $2, old[$1], $3, $7 >> ev
    }
}' "$STATE_FILE" "$new_list")"

# Save the new state so each change is only reported once
state_saved="yes"
if [[ -n $changes ]]; then
    # Merge with the old state so a stale fetch can't roll a Last Updated date back
    # (which would report the same update again on the next fresh fetch)
    state_new="$tmp_dir/state.tsv"
    merge_lists "$new_list" "$STATE_FILE" | head -n "$STATE_KEEP" > "$state_new"
    if ! cp -- "$state_new" "$STATE_FILE"; then
        state_saved=""
        echo "WARNING: could not update $STATE_FILE, these changes will be reported again next run"
    fi
fi

# History = old history + this run's changes, minus anything older than HISTORY_DAYS,
# except advisories the page currently lists as Ongoing: those stay until they are
# Resolved. For an Ongoing advisory with nothing newer than HISTORY_DAYS only its
# latest entry is kept, so repeated updates don't pile up.
# Only written when it differs, so a plain Refresh doesn't touch the disk.
cutoff=$(( now - HISTORY_DAYS * 86400 ))
history_new="$tmp_dir/history.tsv"
{
    [[ -f $HISTORY_FILE ]] && cat -- "$HISTORY_FILE"
    [[ -n $state_saved ]] && cat -- "$events"
} | awk -F'\t' -v cutoff="$cutoff" '
NR == FNR { if ($4 == "ongoing") { og[$1] = 1 } next }
{ n++; l[n] = $0; ep[n] = $1; ad[n] = $4 }
END {
    for (i = 1; i <= n; i++) {
        if (ep[i] + 0 >= cutoff) { recent[ad[i]] = 1 } else { lastold[ad[i]] = i }
    }
    for (i = 1; i <= n; i++) {
        if (ep[i] + 0 >= cutoff) { print l[i] }
        else if ((ad[i] in og) && !(ad[i] in recent) && lastold[ad[i]] == i) { print l[i] }
    }
}' "$new_list" - > "$history_new"

if [[ -f $HISTORY_FILE || -s $history_new ]]; then
    if [[ "$(cat -- "$history_new")" != "$(cat -- "$HISTORY_FILE" 2>/dev/null)" ]]; then
        if cp -- "$history_new" "$HISTORY_FILE"; then
            set_perms "$HISTORY_FILE"
        else
            echo "WARNING: could not update $HISTORY_FILE"
        fi
    fi
fi

# ---- Report -----------------------------------------------------------------
if [[ -z $changes ]]; then
    # Nothing new, so nothing to email (exit 0). Show what changed recently and
    # anything still Ongoing, if there is any.
    report="$(show_history "$history_new" "$new_list" html)"
    if [[ -n $report ]]; then
        echo "$report"
        echo "Latest $rows advisories checked."
        echo "Advisory list: <a href=\"${URL}\">${URL}</a>"
    else
        echo "No new or updated Synology advisories (latest $rows checked)"
    fi
    exit 0
fi

if is_schedule_running "$(basename -- "$0")"; then
    # Task Scheduler email: only what this run found, plain text (no HTML links)
    echo "Synology security advisory changes found:"
    echo " "  # " " needed for Task Scheduler email formatting
    echo "$changes"
    echo "Advisory list: $URL"
    exit 1  # So Task Scheduler sends an email
fi

# Run from Syno_Toolbox: everything from the last HISTORY_DAYS days, links clickable
show_history "$history_new" "$new_list" html
echo "Latest $rows advisories checked."
echo "Advisory list: <a href=\"${URL}\">${URL}</a>"
