# Direct Convolution local-size experiment

This experiment changes only the local workgroup dimensions of the packed generic
Vulkan Direct Convolution pipeline in `Convolution_vulkan::create_pipeline()`.
The shader and dispatch dimensions are unchanged. SGEMM, Winograd, the dedicated
1x1 path, and the int8 convolution pipeline are not modified by this patch.

## Default behavior

Leave all three environment variables unset. The builder then compiles without
the override macros and NCNN continues to call
`set_optimal_local_size_xyz(local_size_xyz)`, exactly as before.

## Selecting a fixed local size

Set all three variables when invoking the pinned NCNN builder:

```bash
NCNN_CONV_DIRECT_LOCAL_SIZE_X=8 \
NCNN_CONV_DIRECT_LOCAL_SIZE_Y=8 \
NCNN_CONV_DIRECT_LOCAL_SIZE_Z=1 \
./scripts/build_pinned_ncnn_android.sh
```

The builder rejects partial configurations and non-positive/non-integer values.
The three dimensions are passed as C++ compile definitions. The patch checks
each dimension and the total invocation count against the active Vulkan device
limits before applying the override. If the requested size is unsupported, it
logs the reason and falls back to NCNN's optimal size instead of attempting to
create an invalid pipeline.

## Suggested test matrix

| Variant | X | Y | Z | Requested invocations/workgroup |
|---|---:|---:|---:|---:|
| A | 8 | 8 | 1 | 64 |
| B | 8 | 8 | 2 | 128 |
| C | 8 | 8 | 4 | 256 |

Variant C is attempted only if the device reports sufficient limits. The
`Pipeline::set_local_size_xyz()` implementation may adjust dimensions to satisfy
the device subgroup size; therefore the applied dimensions in the runtime log,
not just the requested values, are authoritative.

## Runtime verification

At model/pipeline creation, inspect:

- `[CONV_DIRECT_LOCAL_SIZE]`: requested and applied dimensions, or an explicit
  Vulkan-limit fallback.
- `[CONV_DISPATCH]`: per-layer dispatcher dimensions and the local dimensions
  actually used by that pipeline.

For each benchmark, retain the same model, input resolution, precision, route
selection, clocks, thermal state, and frame sequence. Change only X/Y/Z between
runs. Confirm that the target layer is logged as `direct_generic`; otherwise
the experiment is not exercising this pipeline.

## Patchset identity

The Direct Convolution patch is included in the builder's
`NCNN_PATCHSET_SHA`. The upstream NCNN revision remains pinned independently
by `ncnn.commit`; this experiment does not change that file.
