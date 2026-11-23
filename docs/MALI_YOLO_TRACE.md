# Mali GPU scheduler + YOLO ATrace capture

This capture combines two clock-correlated views:

- **Kernel tracefs**: Mali job enqueue, GPU scheduler switches, job-slot events and PM status.
- **Android ATrace**: app/native trace slices named `YOLO_*`, visible in the atrace/Perfetto output.

The instrumentation does not modify Vulkan queue count, NCNN dispatch thresholds, frame slots, command submission, shader code or synchronization.

## Instrumented slices

- `YOLO_GPU_SUBMIT_<frame>`: host interval around `FullGpuFrame` / `PrefixFrame` call. In full-GPU mode this ends after `vkQueueSubmit`, not after GPU completion.
- `YOLO_GPU_FENCE_WAIT_<frame>`: host interval around `WaitGpuFrame` in Kotlin.
- `YOLO_NATIVE_GPU_FRAME_<frame>`: native `detect_ahb()` lifetime. For mode 8 this covers command recording and submit; it does not extend to the deferred fence wait.
- `YOLO_GPU_WAIT_FRAME_<frame>`: native interval around `VkCompute::wait()`.
- `YOLO_POSTPROCESS_<frame>`: Kotlin CPU postprocess call (mode 8 DFL/NMS wrapper).
- `YOLO_DFL_DECODE_FRAME_<frame>`: native DFL decode interval in the full-GPU mode.
- `YOLO_JNI_DETECT_<frame>` and `YOLO_DETECT_FRAME_<frame>`: synchronous JNI and Kotlin detection scopes for non-async path.

The Java/Kotlin and C++ tracing APIs use Android ATrace. ATrace markers are not written into ftrace's `trace_marker`; collect them with atrace/Perfetto separately. Both traces use the device monotonic clock domain, so frame IDs and the existing `*_ns` log fields can be used to correlate the captures. Confirm offset/clock behavior on the device when combining exports from different trace tools.

## Capture

Build/install the app from this branch first. Then run:

```sh
chmod +x scripts/capture_mali_yolo_trace.sh
DURATION=15 scripts/capture_mali_yolo_trace.sh
```

Optional arguments:

```sh
DURATION=30 APP_PKG=com.tencent.yolo11ncnn scripts/capture_mali_yolo_trace.sh /tmp/yolo-trace
```

The script asks `adb shell su` for an interactive-root shell and streams a remote script over stdin, avoiding the Magisk `su -c` parsing issue observed on this device. It captures:
- `mali_yolo_trace.txt`: tracefs GPU/Mali events.
- `atrace_yolo.txt`: Android userspace/system slices.
- `yolo_trace_logcat.txt`: app/native timing logs.
- `capture_meta.txt`: device/build and capture settings.

## Important limitations

- The kernel event stream is not a hardware counter stream. It does not expose ALU/FP16 utilization, texture utilization or external-memory bandwidth.
- `gpu_sched_switch` indicates scheduler context/job changes; it does not directly prove simultaneous shader execution or occupancy.
- `gpu_job_enqueue` can be attributed to a process by matching context IDs and task IDs against `ps -A -T`; do not classify every `mali-cmar-backe` thread as belonging to the app.
- Kernel `tracefs` and Android `atrace` are captured in separate operations by this helper. They are aligned by monotonic timestamps and application frame IDs, not exported as one atomic trace. For strict single-session Perfetto capture, use a Perfetto config with ftrace and atrace data sources enabled together.
- The script enables only the known events. Missing event nodes are reported rather than treated as fatal. If root access is denied or tracefs is elsewhere, the capture fails rather than silently claiming a kernel trace was collected.

## First validation

After capture:

```sh
grep -E 'YOLO_TRACE_CAPTURE|gpu_job_enqueue|gpu_sched_switch|mali_job_slots_event|mali_pm_status' /tmp/yolo-trace/mali_yolo_trace.txt | head -80
grep -E 'YOLO_(GPU|NATIVE|POSTPROCESS|DFL|JNI|DETECT)' /tmp/yolo-trace/atrace_yolo.txt | head -80
```

Verify that the same frame number appears in trace slice names and the app log records. A trace slice is a host-side interval; it is not a GPU execution timestamp.
