#!/bin/sh
# generate_cpu_chart.sh
#
# Builds a static, self-contained cpu_chart.html from one or more
# Syno_Toolbox cpu_usage.log files (local or already-copied-in from
# another NAS — this script does not do any network fetching itself).
#
# Usage:
#   ./generate_cpu_chart.sh "Oscar:/var/packages/Syno_Toolbox/var/cpu_usage.log" \
#                           "Webber:/tmp/webber_cpu_usage.log" \
#                           > /path/to/output/cpu_chart.html
#
# Each argument is "Label:/path/to/log", log lines expected as:
#   2026-09-12 10:04:56 2.6

TEMPLATE="/var/packages/Syno_Toolbox/target/ui/cpu_chart_template.html"

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 \"Label:/path/to/log\" [\"Label2:/path/to/log2\" ...]" >&2
    exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
    echo "Template not found: $TEMPLATE" >&2
    exit 1
fi

json="["
first_series=1

for pair in "$@"; do
    name="${pair%%:*}"
    path="${pair#*:}"

    if [ ! -f "$path" ]; then
        echo "Warning: log not found for $name ($path), skipping" >&2
        continue
    fi

    # Turn "2026-09-12 10:04:56 2.6" lines into {"t":"2026-09-12T10:04:56","v":2.6}
    # joined with commas. awk builds the whole points array for this series.
    #
    # IMPORTANT: the log file lives in DSM's package var/ directory, which
    # Synology creates world-writable (0777) regardless of package settings.
    # That means any local account can append or replace lines in this log.
    # Every field is therefore validated against a strict pattern before
    # being embedded in the generated page's inline <script> block; any
    # line that doesn't match exactly is silently skipped. Without this,
    # a crafted "value" field could break out of the JS array literal
    # (and even out of the <script> tag itself) and inject arbitrary
    # JavaScript into every future run's output.
    points=$(awk '
        {
            if (NF != 3) next
            if ($1 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) next
            if ($2 !~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) next
            if ($3 !~ /^[0-9]+(\.[0-9]+)?$/) next
            if (n++ > 0) printf ","
            printf "{\"t\":\"%sT%s\",\"v\":%s}", $1, $2, $3
        }
    ' "$path")

    [ "$first_series" -eq 0 ] && json="${json},"
    json="${json}{\"name\":\"${name}\",\"points\":[${points}]}"
    first_series=0
done

json="${json}]"

# Substitute the placeholder. Using awk instead of sed here because the
# JSON blob can be arbitrarily long and contain characters (/, &) that
# sed's s|||  delimiter can trip over.
awk -v data="$json" '{ gsub(/__CPU_DATA__/, data); print }' "$TEMPLATE"
