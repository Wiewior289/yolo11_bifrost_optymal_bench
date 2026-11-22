# NCNN backend comparison and profiling

## Compute modes

The selector exposes the existing compute modes plus a bounded same-frame AHB comparison mode:

| Mode | Camera input path | Model execution |
|---|---|---|
| CPU | AHardwareBuffer CPU lockPlanes -> YUV420 to RGB on CPU -> resize / normalize | NCNN CPU |
| GPU Vulkan | Same CPU-mapped YUV and CPU preprocessing as CPU mode | NCNN Vulkan |
| GPU Vulkan + AHB | Import the Camera2 AHardwareBuffer into Vulkan -> GPU YCbCr conversion / rotate / resize / normalize | NCNN Vulkan |
| DIAG: AHB vs CPU YUV + Vulkan | Same Camera2 Image/AHB, sequential AHB GPU preprocessing and CPU YUV preprocessing | Same loaded Net and Vulkan inference for both paths |

The CPU and GPU Vulkan baselines intentionally share the same input conversion and preprocessing code. Their model backend is the controlled variable. The AHB mode remains the direct-import implementation.

The CPU conversion currently assumes BT.601 limited-range YUV420. The Vulkan YCbCr sampler path can use a driver-selected conversion. The diagnostic mode compares both preprocessing paths from the same acquired Camera2 Image: AHB preprocessing first, then CPU plane locking/conversion, followed by Vulkan inference through the same loaded Net. It samples every 30th app frame, at most 10 samples per model initialization. RGB and normalized FP32 inputs are compared separately; AHB FP16 input statistics are logged on their own so dtype conversion is not confused with preprocessing error.

Every mode retains the high-level, known-good output path:
```cpp
ex.extract("out0", out);
```
Do not replace it with manual VkMat output conversion/download unless the tensor layout is independently validated.

## Layer capability inventory

At model load, the app logs one `NCNN_LAYER` record per network layer with:
- layer index, type and name
- `support_vulkan`
- `support_packing`
- `support_vulkan_packing`

This is a capability inventory, not measured execution placement. A layer that supports Vulkan may still use a CPU path under some runtime/configuration conditions.

## Per-layer arithmetic and convolution route

Layer indices are NCNN network indices, not convolution names. The app applies these settings after `net.load_param()` and before `net.load_model()`, so the feature mask is visible while NCNN creates layer pipelines.

```sh
adb shell su -c 'setprop debug.yolo11.fp32_layers 9,11'
# Replace 9,11 below with actual Convolution layer indices from the NCNN_LAYER inventory.
adb shell su -c 'setprop debug.yolo11.direct_layers 9,11'
adb shell su -c 'setprop debug.yolo11.layer_benchmark 1'
```

The two lists are independent and may overlap. This gives four useful combinations: FP16+SGEMM, FP32+SGEMM, FP16+Direct and FP32+Direct.

- `fp32_layers` sets `featmask bit 0`, inhibiting FP16 arithmetic for those layers.
- `direct_layers` sets `featmask bits 5 and 6`, inhibiting SGEMM and Winograd for those Convolution layers. The remaining eligible route is generic Direct.
- Neither setting changes FP16 storage or the channel `elempack` layout. Packing is a separate experiment; `featmask bit 1` disables FP16 packed/storage and is not a general pack4-to-pack1 switch.

Expected diagnostics:
- `FP32_LAYER_CONFIG`: accepted FP32 layer indices and resulting feature masks.
- `DIRECT_LAYER_CONFIG`: accepted Direct layer indices and resulting feature masks.
- `[CONV_ROUTE_CREATE]`: route selected at pipeline creation, plus effective FP16 arithmetic/storage flags and convolution dimensions.

The NCNN route diagnostic uses the per-layer masked `Option`. There is no longer a hardcoded list of `conv_7`, `conv_12` and `conv_22`; those layers are selected through `debug.yolo11.direct_layers` like any other convolution.

Clear a property by setting it to an empty value or rebooting the device. Capture the configuration and route logs with each benchmark so results remain attributable to the exact layer settings.

Route/configuration log capture:

```sh
adb logcat -c
adb logcat -v threadtime -s Yolo11_AHB_MaliG72:I ncnn:V '*:S'
```

## Mali hardware-counter interface discovery

Before selecting a counter backend, enumerate what this Android kernel and Mali driver actually expose. The probe mounts debugfs if possible and lists candidate Mali/HWCNT/PRFCNT nodes; it does not write to driver controls or assume that PMU access is enabled.

```sh
./scripts/probe_mali_hwcnt.sh | tee mali_hwcnt_probe.txt
```

The output determines whether the device exposes a usable kbase counter interface, a vendor-specific debugfs interface, or no userspace PMU interface. A missing node is not evidence that the GPU has no counters; it means this kernel/driver does not expose that path to this probe.

## Enabling actual per-layer timings

NCNN's CPU and Vulkan per-layer timers are compiled into the NCNN library behind `NCNN_BENCHMARK`. The repository builder configures `-DNCNN_BENCHMARK=ON`; defining the macro only for the Android app does not change an already-built `libncnn`.

Rebuild the NCNN Android arm64 package used by this project with at least:

```sh
-DNCNN_VULKAN=ON
-DNCNN_BENCHMARK=ON
-DNCNN_STRING=ON
```

Keep the same Android ABI, Android API level, NDK toolchain and Vulkan configuration as the package currently linked by the app. Point `ncnn_DIR` in the app build at the rebuilt package. Do not mix headers from one NCNN version with a library from another.

With the benchmark-enabled library:
- CPU-fallback layer durations are measured with host timing.
- Vulkan layer durations are measured with Vulkan timestamp queries.
- NCNN emits its own per-layer timing logs while the extractor runs.

The app cannot turn this facility on at runtime when the linked NCNN binary was built without it.

## What the current wall-clock measurements mean

- `preprocess_cpu`: CPU lock, plane conversion, rotation, resize and normalization for CPU / GPU Vulkan modes.
- `preprocess_record` and `preprocess_wait`: CPU command recording and the explicit preprocess queue wait for Vulkan+AHB.
- `infer_extract_wall`: wall time around `Extractor::extract("out0", out)`. For Vulkan this includes whatever graph work, internal queue submissions/waits, input upload (CPU-input Vulkan mode), output download and synchronization NCNN performs internally.
- `post`: DFL decode and NMS.
- `frame_total`: end-to-end native frame wall time.

The public Extractor API does not expose separate graph, queue-wait and output-readback durations. Splitting those accurately requires instrumentation inside the exact NCNN source version linked by the APK. NCNN's existing layer timestamps provide GPU layer execution time, but not a standalone readback duration. The app therefore reports `infer_extract_wall` and does not fabricate separate graph/wait/readback values.

A deeper Extractor instrumentation pass should place timers around:
1. graph evaluation into the GPU output VkMat,
2. output-download command recording,
3. final queue submit/wait,
4. GPU timestamp interval around the download command.

The build script checks out the exact upstream commit in `ncnn.commit`, then applies the repository-owned NCNN patchset before building. The upstream source SHA and local patchset SHA are emitted by the script and embedded in the app build markers. The same-frame AHB/CPU comparison is implemented in the app layer. Deeper Extractor or queue instrumentation still requires changes inside that exact pinned NCNN source and a rebuild of the patched library.
