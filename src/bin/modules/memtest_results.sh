#!/bin/bash

# 2021-07-22T13:26:01-07:00 SYN-NAS-A findhostd: util_fhost.c:1378 Memtest passed!
# 2021-07-22T13:26:01-07:00 SYN-NAS-A findhostd: util_fhost.c:1378 Memtest passed!
# 2021-07-22T13:26:01-07:00 SYN-NAS-A findhostd: util_fhost.c:1378 Memtest passed!

# 2022-02-27T22:38:52-05:00 NASMV findhostd[16713]: ucil_fhost.c:1207 Memtest; passed
# 2022-02-27T22:38:52-05:00 NASMV findhosrd[16804]: ucil_fhost.c:1207 Memtest; passed
# 2022-02-27T22:38:52-05:00 NASMV findhostd[16732]: ucil_fhost.c:1207 Memtest; passed
# 2022-02-28T16:59:05-05:00 NASMV findhostd[13678]: útil_fhost.c:1207 Memtest; passed

# root@DS218:~# cat /var/log/memtester.log
# cat: /var/log/memtester.log: No such file or directory
# root@DS218:~# grep -i 'memtest' /var/log/messages
# 2026-09-15T12:59:08+10:00 DS218 findhostd[8055]: util_fhost.c:1195 Memtest passed!

result="$(grep -i 'memtest' /var/log/messages | tail -1)"
if [[ -n "$result" ]]; then
    #echo "$result" | cut -d" " -f1,2,5-
    echo "$result" | sed -E 's/ findhostd(\[[0-9]+\])?: [a-z]+_fhost\.c:[0-9]+ / /i'
elif [[ -f /var/log/bios/memtest86p.log ]]; then
    cat /var/log/bios/memtest86p.log
elif [[ -f /var/log/memtester.log ]]; then
    # DSM 6.1.2 and older 
    cat /var/log/memtester.log
else
    echo "No recent memory test results found"
    #echo "or the results were not saved"
fi

exit


# Diagnostic only (synoboot models)
last_logged="$(grep -i 'memtest' /var/log/logrotate.status | cut -d" " -f2)"
if [[ -f /var/log/logrotate.status ]]; then
    if [[ -n "$last_logged" ]]; then
        echo "Last rotated memory test log: $last_logged"
    else
        echo "No last rotated memory test log"
    fi
fi


# memtest86p success sample
# 2026-09-14T02:15:22+02:00 SynologyNAS memtest86p: [INFO] MemTest86+ v6.10 Core Initialized.
# 2026-09-14T02:15:23+02:00 SynologyNAS memtest86p: [INFO] CPU Gen: Intel Celeron J4125 @ 2.00GHz
# 2026-09-14T02:15:23+02:00 SynologyNAS memtest86p: [INFO] Detecting Memory Topology...
# 2026-09-14T02:15:24+02:00 SynologyNAS memtest86p: [INFO] Slot 0: 4096 MB DDR4 (Synology Onboard)
# 2026-09-14T02:15:24+02:00 SynologyNAS memtest86p: [INFO] Slot 1: 4096 MB DDR4 (Crucial Technology)
# 2026-09-14T02:15:25+02:00 SynologyNAS memtest86p: [INFO] Total Testing Memory Range: 0x000000000 - 0x200000000 (8192 MB)
# 2026-09-14T02:15:25+02:00 SynologyNAS memtest86p: [INFO] Starting Test Pass #1 (All Patterns)...
# 2026-09-14T02:48:11+02:00 SynologyNAS memtest86p: [INFO] Pass 1 Completed. Errors: 0
# 2026-09-14T03:22:04+02:00 SynologyNAS memtest86p: [INFO] Pass 2 Completed. Errors: 0
# 2026-09-14T03:22:05+02:00 SynologyNAS memtest86p: [INFO] Memory test iteration finished successfully.
# 2026-09-14T03:22:05+02:00 SynologyNAS memtest86p: Status: MEMTEST_SUCCESS

# memtest86p failed sample
# 2026-08-10T14:05:01+01:00 DiskStation memtest86p: [INFO] MemTest86+ v6.10 Core Initialized.
# 2026-08-10T14:05:02+01:00 DiskStation memtest86p: [INFO] Total Testing Memory Range: 16384 MB
# 2026-08-10T14:05:03+01:00 DiskStation memtest86p: [INFO] Starting Test Pass #1...
# 2026-08-10T14:22:15+01:00 DiskStation memtest86p: [ERROR] Test #4 [Moving inversions, 8 bit pattern] Failed.
# 2026-08-10T14:22:15+01:00 DiskStation memtest86p: [ERROR] Address: 0x002FA4E10 - Expected: 0x55555555, Actual: 0x55555545 (Bits Face: 00000010)
# 2026-08-10T14:22:16+01:00 DiskStation memtest86p: [ERROR] Address: 0x002FA4E18 - Expected: 0x55555555, Actual: 0x55555545 (Bits Face: 00000010)
# 2026-08-10T14:41:30+01:00 DiskStation memtest86p: [WARNING] Pass 1 finished with 2 errors.
# 2026-08-10T14:41:31+01:00 DiskStation memtest86p: [FATAL] Hardware diagnostic failed. Defective RAM module suspected.
# 2026-08-10T14:41:31+01:00 DiskStation memtest86p: Status: MEMTEST_FAILED (Count: 2)


# root@Senna:~# /var/packages/Syno_Toolbox/target/bin/modules/memtest_results.sh
# No recent memory tests

# root@Senna:~# cat /var/log/memtester.log
# cat: /var/log/memtester.log: No such file or directory

# root@Senna:~# cat /var/log/bios/memtest86p.log
# cat: /var/log/bios/memtest86p.log: No such file or directory

# root@Senna:~# grep -i 'memtest' /var/log/messages

# root@Senna:~# grep -i 'memtest' /var/log/logrotate.status
# "/var/log/bios/memtest86p.log" 2026-6-25-17:0:0

