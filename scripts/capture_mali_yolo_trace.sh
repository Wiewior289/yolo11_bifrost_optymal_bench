#!/usr/bin/env bash
set -euo pipefail

ADB_BIN="${ADB:-adb}"
OUT_DIR="${1:-mali_trace_capture}"
DURATION="${DURATION:-15}"
APP_PKG="${APP_PKG:-com.tencent.yolo11ncnn}"

if ! command -v "${ADB_BIN}" >/dev/null 2>&1; then
    echo "ERROR: adb not found. Set ADB=/path/to/adb or add platform-tools to PATH." >&2
    exit 2
fi
if ! "${ADB_BIN}" get-state >/dev/null 2>&1; then
    echo "ERROR: no authorized Android device is available through adb." >&2
    exit 3
fi
if [[ ! "${DURATION}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: DURATION must be a positive integer number of seconds." >&2
    exit 2
fi

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
TRACE_FILE="${OUT_DIR}/mali_yolo_trace.txt"
ATRACE_FILE="${OUT_DIR}/atrace_yolo.txt"
LOGCAT_FILE="${OUT_DIR}/yolo_trace_logcat.txt"
META_FILE="${OUT_DIR}/capture_meta.txt"

echo "=== Host capture ==="
{
    date -Is
    echo "duration_s=${DURATION}"
    echo "package=${APP_PKG}"
    "${ADB_BIN}" shell getprop ro.product.model
    "${ADB_BIN}" shell getprop ro.build.fingerprint
} | tee "${META_FILE}"

# Tracefs needs root for event setup and trace extraction. Use a quoted remote
# script via stdin, avoiding su -c argument parsing differences across Magisk.
REMOTE_SCRIPT=$(cat <<'REMOTE'
set -eu
TRACE=/sys/kernel/debug/tracing
if [ ! -d "$TRACE" ]; then
    mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
fi
if [ ! -d "$TRACE/events/gpu" ]; then
    echo "ERROR: tracefs GPU events are unavailable at $TRACE" >&2
    exit 10
fi

echo "=== identity ==="
id
echo "=== enabled event availability ==="
for e in gpu/gpu_job_enqueue gpu/gpu_sched_switch mali/mali_job_slots_event mali/mali_pm_status; do
    if [ -e "$TRACE/events/$e/enable" ]; then
        echo "$e: $(cat "$TRACE/events/$e/enable")"
    else
        echo "$e: MISSING"
    fi
done

echo 0 > "$TRACE/tracing_on"
echo nop > "$TRACE/current_tracer"
echo > "$TRACE/trace"
echo 1 > "$TRACE/events/gpu/gpu_job_enqueue/enable"
echo 1 > "$TRACE/events/gpu/gpu_sched_switch/enable"
[ ! -e "$TRACE/events/mali/mali_job_slots_event/enable" ] || echo 1 > "$TRACE/events/mali/mali_job_slots_event/enable"
[ ! -e "$TRACE/events/mali/mali_pm_status/enable" ] || echo 1 > "$TRACE/events/mali/mali_pm_status/enable"

# Also capture trace_marker boundaries from this script. ATrace slices are
# collected separately by the Android tracing service.
echo "YOLO_TRACE_CAPTURE_START" > "$TRACE/trace_marker"
echo 1 > "$TRACE/tracing_on"
sleep __DURATION__
echo 0 > "$TRACE/tracing_on"
echo "YOLO_TRACE_CAPTURE_END" > "$TRACE/trace_marker"
cat "$TRACE/trace"
echo "=== trace statistics ==="
cat "$TRACE/per_cpu/cpu0/stats" 2>/dev/null || true
REMOTE
)
REMOTE_SCRIPT="${REMOTE_SCRIPT//__DURATION__/${DURATION}}"
printf '%s\n' "${REMOTE_SCRIPT}" | "${ADB_BIN}" shell su

# ATrace/Perfetto userspace trace. This includes the YOLO_* slices added to
# Kotlin and native code. It is intentionally separate from kernel tracefs.
"${ADB_BIN}" shell atrace --async_start -b 4096 -a "${APP_PKG}" gfx view sched freq idle >/dev/null 2>&1 || true
sleep "${DURATION}"
"${ADB_BIN}" shell atrace --async_stop > "${ATRACE_FILE}" 2>&1 || true

# Keep app log timing records for frame IDs and native stage values.
"${ADB_BIN}" logcat -d -v threadtime -s MainActivity:I Yolo11_AHB_MaliG72:I Yolo11Ncnn_JNI:I ncnn:V > "${LOGCAT_FILE}" || true

echo "Capture files:"
printf '  %s\n  %s\n  %s\n  %s\n' "${TRACE_FILE}" "${ATRACE_FILE}" "${LOGCAT_FILE}" "${META_FILE}"
