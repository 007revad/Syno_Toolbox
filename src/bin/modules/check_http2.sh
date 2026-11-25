#!/usr/bin/env bash
# shellcheck disable=SC2034
# Warn if HTTP/2 is enabled in DSM's nginx (nginx2root)
#
# Reads the config nginx has actually loaded (nginx -T), not the compiled-in modules.
# DSM 7.4.1: HTTP/2 enabled shows
#     http2_max_client_body_buffer_size 8m;
#     default_listen_option ssl_http2;
# and after disabling HTTP/2 only
#     http2_max_client_body_buffer_size 8m;
# remains, which is just a buffer size and must NOT count as enabled.
#
# DSM 6.2.4: HTTP/2 enabled shows
#     listen 5071 default_server ssl http2;
#     listen [::]:5071 default_server ssl http2;
# and after disabling HTTP/2 shows nothing.

scriptver="1.0.0-toolbox"

nginx=/usr/bin/nginx
sgkv=/usr/syno/bin/synogetkeyvalue

dsm="$("$sgkv" /etc.defaults/VERSION majorversion 2>/dev/null)"
if ! [[ $dsm =~ ^[0-9]+$ ]] || [[ $dsm -lt 6 ]]; then
    echo "Not supported: requires DSM 6 or later"
    exit 0
fi

if [[ ! -x $nginx ]]; then
    echo "Could not find nginx"
    exit 0
fi

# nginx -T tests the config and dumps it. It does not change anything.
if ! conf="$("$nginx" -T 2>&1)"; then
    echo "Could not read the nginx configuration"
    exit 0
fi

# Ignore commented-out lines, then look for an HTTP/2 enabling directive:
#   ssl_http2                       (default_listen_option ssl_http2;) - seen on DSM 7.4.1
#   listen ... http2;               (older nginx syntax)  - seen on DSM 6.2.4
#   http2 on;                       (newer nginx syntax)  - not yet seen on DSM
# http2_max_client_body_buffer_size etc. don't match any of these.
if grep -vE '^[[:space:]]*#' <<< "$conf" | grep -qE \
    -e '(^|[^[:alnum:]_])ssl_http2([^[:alnum:]_]|$)' \
    -e '^[[:space:]]*listen[^;]*[[:space:]]http2([[:space:]]|;)' \
    -e '^[[:space:]]*http2[[:space:]]+on[[:space:]]*;'
then
    echo "WARNING: HTTP/2 is enabled in DSM's nginx"
    if [[ $dsm -ge 7 ]]; then
        echo "Untick 'Enable HTTP/2' in Control Panel > Network > Connectivity"
    elif [[ $dsm -eq 6 ]]; then
        echo "Untick 'Enable HTTP/2' in Control Panel > Network > DSM Settings"
    fi
else
    echo "HTTP/2 is disabled in DSM's nginx"
fi

exit 0
