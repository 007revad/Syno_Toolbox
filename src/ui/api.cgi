#!/bin/bash
#----------------------------------------------------------
# Syno_Toolbox package - API CGI
# Structure ported directly from CPUTemp's api.cgi (verified working
# pattern) - same header block, urldecode/parse_kv, json_response,
# run_privileged. Only the action cases differ.
#----------------------------------------------------------

# --------- 1. Common variables and path calculations -------------

PKG_NAME="Syno_Toolbox"
PKG_ROOT="/var/packages/${PKG_NAME}"
TARGET_DIR="${PKG_ROOT}/target"
BIN_DIR="${TARGET_DIR}/bin"

dsm=$(/usr/syno/bin/synogetkeyvalue /etc.defaults/VERSION majorversion)
if [[ $dsm -ge 7 ]]; then
    VAR_DIR="${PKG_ROOT}/var"
else
    VAR_DIR="${PKG_ROOT}/etc"
fi

LOG_FILE="${VAR_DIR}/api.log"

API_SCRIPT="${BIN_DIR}/synotoolbox_api.sh"

touch "${LOG_FILE}"
chmod 644 "${LOG_FILE}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

# --------- 2. HTTP header output --------------------------------

echo "Content-Type: application/json; charset=utf-8"
echo "Access-Control-Allow-Origin: *"
echo "Access-Control-Allow-Methods: GET, POST"
echo "Access-Control-Allow-Headers: Content-Type"
echo ""

# --------- 3. Parsing URL-encoded parameters --------------------

urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }
declare -A PARAM
parse_kv() {
    local kv_pair key val
    IFS='&' read -ra kv_pair <<< "$1"
    for pair in "${kv_pair[@]}"; do
        IFS='=' read -r key val <<< "${pair}"
        key="$(urldecode "${key}")"
        val="$(urldecode "${val}")"
        PARAM["${key}"]="${val}"
    done
}

case "$REQUEST_METHOD" in
POST)
    CONTENT_LENGTH=${CONTENT_LENGTH:-0}
    if [ "$CONTENT_LENGTH" -gt 0 ]; then
        read -r -n "$CONTENT_LENGTH" POST_DATA
    else
        POST_DATA=""
    fi
    parse_kv "${POST_DATA}"
    ;;
GET)
    parse_kv "${QUERY_STRING}"
    ;;
*)
    log "Unsupported METHOD: ${REQUEST_METHOD}"
    echo '{"success":false,"message":"Unsupported METHOD","result":null}'
    exit 0
    ;;
esac

ACTION="${PARAM[action]}"
log "Request: ACTION=${ACTION}"

# --------- 4. JSON utility functions -----------------------------

json_response() {
    local ok="$1" msg="$2" data="$3"
    local msg_json
    msg_json=$(echo "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')
    if [ -z "$data" ]; then
        echo "{\"success\":$ok, \"message\":$msg_json, \"result\":null}"
    else
        echo "{\"success\":$ok, \"message\":$msg_json, \"result\":$data}"
    fi
}

HELPER="${BIN_DIR}/helper/synotoolbox-helper"

run_privileged() {
    # DSM 7's package CGI runs sandboxed enough to need real escalation
    # (setuid helper); DSM 6 doesn't - confirmed against Drive Info's
    # existing dsm-version branch (sudo on >=7, plain bash on 6, for its
    # SMART script). Same split applied here, minus the helper on DSM 6
    # since it was never built/installed for that version.
    if [[ "$dsm" -ge 7 ]]; then
        RUN_OUT=$("$HELPER" "$@" 2>>"${LOG_FILE}")
    else
        RUN_OUT=$(bash "$API_SCRIPT" "$@" 2>>"${LOG_FILE}")
    fi
    RUN_RC=$?
}

# --------- 5. Action processing ---------------------------------

case "${ACTION}" in
init)
    log "----------------------------------------"
    log "Web UI opened/refreshed"
    echo '{"success":true,"message":"init"}'
    ;;

getstate)
    run_privileged getstate
    if [ "$RUN_RC" -ne 0 ] || [ -z "$RUN_OUT" ]; then
        log "[ERROR] getstate failed (rc=${RUN_RC}): ${RUN_OUT}"
        json_response false "Could not read module state" ""
    else
        json_response true "" "${RUN_OUT}"
    fi
    ;;

listvolumes)
    run_privileged listvolumes
    if [ "$RUN_RC" -ne 0 ]; then
        log "[ERROR] listvolumes failed (rc=${RUN_RC}): ${RUN_OUT}"
        json_response false "Could not list volumes" ""
    else
        json_response true "" "${RUN_OUT}"
    fi
    ;;

listwoldevices)
    run_privileged listwoldevices
    if [ "$RUN_RC" -ne 0 ]; then
        log "[ERROR] listwoldevices failed (rc=${RUN_RC}): ${RUN_OUT}"
        json_response false "Could not list WOL devices" ""
    else
        json_response true "" "${RUN_OUT}"
    fi
    ;;

discoverwol)
    run_privileged discoverwol
    if [ "$RUN_RC" -ne 0 ]; then
        log "[ERROR] discoverwol failed (rc=${RUN_RC}): ${RUN_OUT}"
        json_response false "Could not start WOL device discovery" ""
    else
        json_response true "" "${RUN_OUT}"
    fi
    ;;

listshares)
    run_privileged listshares
    if [ "$RUN_RC" -ne 0 ]; then
        log "[ERROR] listshares failed (rc=${RUN_RC}): ${RUN_OUT}"
        json_response false "Could not list shared folders" ""
    else
        json_response true "" "${RUN_OUT}"
    fi
    ;;

listfolder)
    FOLDER_PATH="${PARAM[path]}"
    run_privileged listfolder "$FOLDER_PATH"
    if [ "$RUN_RC" -ne 0 ]; then
        log "[ERROR] listfolder ${FOLDER_PATH} failed (rc=${RUN_RC}): ${RUN_OUT}"
        json_response false "Could not list folder" ""
    else
        json_response true "" "${RUN_OUT}"
    fi
    ;;

discovernas)
    run_privileged discovernas
    if [ "$RUN_RC" -ne 0 ] || [ -z "$RUN_OUT" ]; then
        log "[ERROR] discovernas failed (rc=${RUN_RC}): ${RUN_OUT}"
        json_response false "Discovery failed" ""
    else
        echo "$RUN_OUT"
    fi
    ;;

run)
    MODULE_ID="${PARAM[module_id]}"
    run_privileged run "$MODULE_ID"
    if [ "$RUN_RC" -ne 0 ] || [ -z "$RUN_OUT" ]; then
        log "[ERROR] run ${MODULE_ID} failed (rc=${RUN_RC}): ${RUN_OUT}"
        json_response false "Failed to run ${MODULE_ID}" ""
    else
        echo "$RUN_OUT"
    fi
    ;;

check)
    MODULE_ID="${PARAM[module_id]}"
    run_privileged check "$MODULE_ID"
    if [ "$RUN_RC" -ne 0 ] || [ -z "$RUN_OUT" ]; then
        log "[ERROR] check ${MODULE_ID} failed (rc=${RUN_RC}): ${RUN_OUT}"
        json_response false "Failed to check ${MODULE_ID}" ""
    else
        echo "$RUN_OUT"
    fi
    ;;

save)
    # PARAM[form_json] is a JSON object string built client-side by
    # main.js from every toggle/field in the panel, e.g.
    #   {"fix_size_units_enabled":"yes","seq_io_enabled":"yes","seq_io_kb":"2048"}
    FORM_JSON="${PARAM[form_json]}"
    if [ -z "$FORM_JSON" ]; then
        json_response false "No form data submitted" ""
    else
        run_privileged save "$FORM_JSON"
        if [ "$RUN_RC" -ne 0 ] || [ -z "$RUN_OUT" ]; then
            log "[ERROR] save failed (rc=${RUN_RC}): ${RUN_OUT}"
            json_response false "${RUN_OUT:-Failed to save settings}" ""
        else
            echo "$RUN_OUT"
        fi
    fi
    ;;

*)
    log "[ERROR] Invalid action: ${ACTION}"
    json_response false "Invalid action: ${ACTION}" ""
    ;;
esac

exit 0
