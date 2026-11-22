#!/usr/bin/env bash
set -euo pipefail

ADB_BIN="${ADB:-adb}"
if ! command -v "${ADB_BIN}" >/dev/null 2>&1; then
    echo "ERROR: adb not found. Set ADB=/path/to/adb or add platform-tools to PATH." >&2
    exit 2
fi

if ! "${ADB_BIN}" get-state >/dev/null 2>&1; then
    echo "ERROR: no authorized Android device is available through adb." >&2
    exit 3
fi

REMOTE_SCRIPT=$(cat <<'REMOTE'
set +e

echo "=== DEVICE / KERNEL ==="
uname -a
cat /proc/version 2>/dev/null

echo "=== MALI DEVICE NODES ==="
for p in /sys/class/misc/mali0 /sys/class/misc/mali /sys/devices/platform/*mali* /sys/devices/platform/*gpu*; do
    if [ -e "$p" ]; then
        ls -ld "$p"
        readlink -f "$p" 2>/dev/null
    fi
done

echo "=== DEBUGFS ==="
if [ -d /sys/kernel/debug ]; then
    if ! grep -q ' /sys/kernel/debug debugfs ' /proc/mounts 2>/dev/null; then
        mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
    fi
    grep ' /sys/kernel/debug ' /proc/mounts 2>/dev/null
    find /sys/kernel/debug -maxdepth 7 -type f 2>/dev/null |
        grep -Ei '(mali|hwcnt|prfcnt|counter|instrument|gpu)' |
        sort | head -300
else
    echo "/sys/kernel/debug is absent"
fi

echo "=== SYSFS COUNTER / INSTRUMENTATION NODES ==="
find /sys/devices /sys/class -maxdepth 8 \( -iname '*mali*' -o -iname '*hwcnt*' -o -iname '*prfcnt*' -o -iname '*counter*' \) -print 2>/dev/null |
    sort | head -300

echo "=== RELEVANT KERNEL CONFIG ==="
if [ -r /proc/config.gz ]; then
    zcat /proc/config.gz 2>/dev/null |
        grep -Ei 'CONFIG_(MALI|DEBUG_FS|TRACE|PERF|PRFCNT|HWCNT)' |
        sort
else
    echo "/proc/config.gz is not exposed"
fi

echo "=== ACCESS CHECK ==="
id
REMOTE
)

"${ADB_BIN}" shell su -c "${REMOTE_SCRIPT}"
