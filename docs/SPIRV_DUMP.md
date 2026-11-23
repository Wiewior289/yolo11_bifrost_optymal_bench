# Capturing the final NCNN SPIR-V modules

This is an opt-in diagnostic patch for the pinned Tencent/ncnn revision in `ncnn.commit`.
It does not alter shader source, dispatch dimensions, workgroup selection, pipeline cache
keys, command recording or inference scheduling.

## Capture point

The hook is called at the start of the two-argument
`VulkanDevice::compile_shader_module(const uint32_t*, size_t)`, immediately before
`VkShaderModuleCreateInfo` is populated and `vkCreateShaderModule()` is called.

The three-argument overload first applies `inject_local_size_xyz()` and then calls this
two-argument overload. Therefore the captured bytes include the final injected
`LocalSize` values. PipelineCache hits and misses converge on this module-creation path;
the independent `Pipeline::create()` path also reaches it.

The hook records every module that reaches this point, not just YOLO convolution shaders.
This is intentional for an initial inventory. The low-level API does not carry the NCNN
shader registry index/name, so files are identified by capture sequence and FNV-1a 64-bit
content hash. Each SPIR-V file has a sidecar text file with byte count, hash and parsed
`OpExecutionMode LocalSize` (when present). Correlate sequence numbers with NCNN/Vulkan
pipeline creation logs if a specific operator must be identified.

## Enable on Android

The app package is `com.tencent.yolo11ncnn`. Create an app-writable external-files
directory and set the Android system property before the model creates its Vulkan
pipelines:

```sh
adb shell mkdir -p /sdcard/Android/data/com.tencent.yolo11ncnn/files/ncnn_spirv
adb shell setprop debug.ncnn.spirv_dump_dir /sdcard/Android/data/com.tencent.yolo11ncnn/files/ncnn_spirv
adb shell am force-stop com.tencent.yolo11ncnn
# Start the app normally, then load/run the model once.
```

The property is read when each shader module is created. The output directory must
already exist and be writable by the app UID. No directory is created by NCNN.

Capture the files to the host:

```sh
adb pull /sdcard/Android/data/com.tencent.yolo11ncnn/files/ncnn_spirv ./ncnn_spirv_dump
```

Disable capture after the run:

```sh
adb shell setprop debug.ncnn.spirv_dump_dir ""
```

On non-Android platforms, set `NCNN_SPIRV_DUMP_DIR=/path/to/existing/directory`
in the process environment before NCNN creates its Vulkan pipelines.

## Output format

- `ncnn_spv_000000_<fnv1a64>.spv`: exact bytes passed to `vkCreateShaderModule`.
- `ncnn_spv_000000_<fnv1a64>.spv.txt`: sequence, byte count, FNV-1a64 and LocalSize.

The sequence starts at zero for each process. Use a fresh/empty directory for each run
to avoid confusing captures from separate process launches.

## Reproducibility markers

The pinned builder applies this patch after the existing repository-owned NCNN patchset
and includes its contents in `NCNN_PATCHSET_SHA`. The app CMake configuration independently
recomputes the same patchset fingerprint and rejects a library built from a different
patchset. The upstream source SHA remains the value in `ncnn.commit`.

## Scope and limitations

- Capture is passive with respect to shader bytes and Vulkan dispatch; it adds file I/O
  during shader-module creation and can lengthen model/pipeline initialization.
- Do not use a capture run for FPS, latency, power or thermal benchmarking.
- The low-level dump does not currently encode a semantic shader name or layer index.
- The LocalSize parser records literal `OpExecutionMode LocalSize`; modules using
  `OpExecutionModeId` may report `0,0,0`.
- The SPIR-V is the module supplied to Vulkan, not the proprietary machine code emitted
  internally by the Mali Bifrost driver.
- Run `spirv-val` on the captured files before passing them to Arm Mali Offline Compiler.
