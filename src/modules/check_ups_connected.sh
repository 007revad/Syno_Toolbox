#!/usr/bin/env bash
# Check UPS client connection to UPS server
# Exit 1 = problem (Task Scheduler sends email), Exit 0 = OK

DSM_VER="$(synogetkeyvalue /etc.defaults/VERSION majorversion)"

# Get UPS server's IP address
if [[ "$DSM_VER" -ge "7" ]]; then
    # DSM 7
    # Get UPS mode
    UPS_MODE="$(synogetkeyvalue /usr/syno/etc/ups/synoups.conf ups_mode)"
    if [[ "$UPS_MODE" == "slave" ]]; then
        # Is UPS client so get UPS server IP address
        UPS_SERVER="ups@$(synogetkeyvalue /usr/syno/etc/ups/synoups.conf upsslave_server)"
    elif [[ "$UPS_MODE" ]]; then
        # Local UPS connected via USB or Serial
        UPS_SERVER="ups"
    else
        echo "UPS not configured!"
        exit 3
    fi
else
    # DSM 6
    # MONITOR ups@192.168.20.180 1 monuser secret master
    # MONITOR ups@192.168.20.200 1 monuser secret slave
    UPS_MODE="$(grep -E '^MONITOR ' /usr/syno/etc/ups/upsmon.conf | awk '{print $NF}')"
    if [[ "$UPS_MODE" == "slave" ]]; then
        # Is UPS client so get UPS server IP address
        UPS_SERVER="ups@$(grep -E '^MONITOR ' /usr/syno/etc/ups/upsmon.conf | cut -d'@' -f2 | cut -d' ' -f1)"
    elif [[ "$UPS_MODE" ]]; then
        # Local UPS connected via USB or Serial
        UPS_SERVER="ups"
    else
        echo "UPS not configured!"
        exit 3
    fi
fi
if [[ -z "$UPS_SERVER" ]]; then
    echo "Failed to get UPS server's IP address!"
    exit 2
fi

raw_result=$(/usr/bin/upsc "$UPS_SERVER" ups.status 2>/dev/null)

case "$raw_result" in
    OL)              result="Online";                                     status="ok" ;;
    OB)              result="On Battery";                                 status="ok" ;;
    LB)              result="Low Battery";                                status="ok" ;;
    CHRG)            result="Charging";                                   status="ok" ;;
    DISCHRG)         result="Discharging";                                status="ok" ;;
    "OL CHRG")       result="Online and Charging";                        status="ok" ;;
    "OL DISCHRG")    result="Online and Discharging";                     status="ok" ;;  # Rare, usually test in progress
    "OL BOOST")      result="Online and Boosting input low voltage";      status="ok" ;;
    "OL OVER")       result="Online and Reducing input over voltage";     status="ok" ;;
    "OL TRIM")       result="Online Trimming input extreme over voltage"; status="ok" ;;
    "OB DISCHRG")    result="On Battery and Discharging";                 status="ok" ;;
    "OB LB DISCHRG") result="Low Battery, Shutdown Impending";            status="ok" ;;
    FSD|"OB LB")     result="Forced Shutdown";                            status="error" ;;  # FSD is equivalent to OB LB
    RB)              result="Replace Battery";                            status="ok" ;;
    BYPASS)          result="UPS is in bypass mode";                      status="ok" ;;  # Load fed by raw AC, not inverter
    CAL)             result="Calibration in progress";                    status="ok" ;;
    TEST)            result="Self-test in progress";                      status="ok" ;;
    OFF)             result="UPS is off";                                 status="warn" ;;
    "")              result="No response from UPS";                       status="error" ;;
    *)               result="Unknown status: $raw_result";                status="error" ;;
esac

if [[ "$status" == "ok" ]]; then
    if [[ "$UPS_MODE" == "slave" ]]; then
        echo "UPS server connection OK: $result"
    else
        echo "UPS connection OK: $result"
    fi
    exit 0
elif [[ "$status" == "warn" ]]; then
    echo "WARNING: $result"
    exit 1
else
    echo "ERROR: UPS connection to $UPS_SERVER failed!"
    echo "ERROR: Response: $result"
    grep -i 'upsmon' /var/log/messages | tail -2
    exit 1
fi

