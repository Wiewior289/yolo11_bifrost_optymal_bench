#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXPECTED_SHA="$(tr -d '[:space:]' < "${REPO_ROOT}/ncnn.commit")"
NCNN_URL="https://github.com/Tencent/ncnn.git"

if [[ ! "${EXPECTED_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: ncnn.commit must contain one 40-character lowercase Git SHA." >&2
    exit 2
fi

NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${1:-}}}"
if [[ -z "${NDK_ROOT}" || ! -f "${NDK_ROOT}/build/cmake/android.toolchain.cmake" ]]; then
    echo "ERROR: set ANDROID_NDK_HOME / ANDROID_NDK_ROOT or pass the Android NDK path as argument 1." >&2
    exit 2
fi
NDK_ROOT="$(cd "${NDK_ROOT}" && pwd)"

ABI="${ANDROID_ABI:-arm64-v8a}"
API="${ANDROID_API:-29}"

# Optional fixed local size for the packed generic Direct Convolution pipeline.
# Set all three variables or leave all three unset to preserve NCNN defaults.
DIRECT_X="${NCNN_CONV_DIRECT_LOCAL_SIZE_X:-}"
DIRECT_Y="${NCNN_CONV_DIRECT_LOCAL_SIZE_Y:-}"
DIRECT_Z="${NCNN_CONV_DIRECT_LOCAL_SIZE_Z:-}"
DIRECT_LOCAL_SIZE_CMAKE_ARGS=()
DIRECT_SET_COUNT=0
for value in "${DIRECT_X}" "${DIRECT_Y}" "${DIRECT_Z}"; do
    if [[ -n "${value}" ]]; then
        DIRECT_SET_COUNT=$((DIRECT_SET_COUNT + 1))
    fi
done
if [[ "${DIRECT_SET_COUNT}" -ne 0 && "${DIRECT_SET_COUNT}" -ne 3 ]]; then
    echo "ERROR: set all of NCNN_CONV_DIRECT_LOCAL_SIZE_X/Y/Z, or none of them." >&2
    exit 2
fi
if [[ "${DIRECT_SET_COUNT}" -eq 3 ]]; then
    for value in "${DIRECT_X}" "${DIRECT_Y}" "${DIRECT_Z}"; do
        if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: Direct Conv local-size dimensions must be positive integers." >&2
            exit 2
        fi
    done
    DIRECT_LOCAL_SIZE_CXX_FLAGS="-DNCNN_CONV_DIRECT_LOCAL_SIZE_X=${DIRECT_X} -DNCNN_CONV_DIRECT_LOCAL_SIZE_Y=${DIRECT_Y} -DNCNN_CONV_DIRECT_LOCAL_SIZE_Z=${DIRECT_Z}"
    DIRECT_LOCAL_SIZE_CMAKE_ARGS+=("-DCMAKE_CXX_FLAGS=${DIRECT_LOCAL_SIZE_CXX_FLAGS}")
    echo "DIRECT_CONV_LOCAL_SIZE_REQUESTED=${DIRECT_X}x${DIRECT_Y}x${DIRECT_Z}"
else
    echo "DIRECT_CONV_LOCAL_SIZE_REQUESTED=NCNN_OPTIMAL_DEFAULT"
fi
SOURCE_DIR="${REPO_ROOT}/.deps/ncnn-${EXPECTED_SHA}"
BUILD_DIR="${REPO_ROOT}/.build/ncnn-${ABI}-${EXPECTED_SHA}"
INSTALL_PREFIX="${REPO_ROOT}/app/src/main/cpp/ncnn-android-vulkan/${ABI}"

case "${ABI}" in
    arm64-v8a) ;;
    *) echo "ERROR: this app currently packages arm64-v8a only; got ABI=${ABI}." >&2; exit 2 ;;
esac

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
    mkdir -p "$(dirname "${SOURCE_DIR}")"
    git clone --filter=blob:none --no-checkout "${NCNN_URL}" "${SOURCE_DIR}"
fi

REMOTE_URL="$(git -C "${SOURCE_DIR}" remote get-url origin)"
case "${REMOTE_URL}" in
    *github.com/Tencent/ncnn*|*github.com:tencent/ncnn*) ;;
    *)
        echo "ERROR: managed source directory has unexpected origin: ${REMOTE_URL}" >&2
        exit 3
        ;;
esac

# Reset only the dedicated .deps checkout used by this script.
git -C "${SOURCE_DIR}" fetch --no-tags origin "${EXPECTED_SHA}"
git -C "${SOURCE_DIR}" checkout --detach "${EXPECTED_SHA}"
git -C "${SOURCE_DIR}" reset --hard "${EXPECTED_SHA}"
git -C "${SOURCE_DIR}" clean -fdx

ACTUAL_SHA="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
    echo "ERROR: NCNN checkout mismatch. expected=${EXPECTED_SHA} actual=${ACTUAL_SHA}" >&2
    exit 4
fi
if [[ -n "$(git -C "${SOURCE_DIR}" status --porcelain)" ]]; then
    echo "ERROR: NCNN checkout is not clean after reset." >&2
    git -C "${SOURCE_DIR}" status --short >&2
    exit 4
fi

# Apply the repository-owned MatMul Vulkan extension after every pristine checkout.
# The upstream NCNN SHA remains pinned; the local patchset is identified separately.
PATCH_DIR="${REPO_ROOT}/patches/ncnn"
PATCH_HEADER="${PATCH_DIR}/matmul_vulkan.h"
PATCH_SOURCE="${PATCH_DIR}/matmul_vulkan.cpp"
PATCH_SHADER="${PATCH_DIR}/matmul.comp"
PATCH_BENCHMARK="${PATCH_DIR}/benchmark_timestamp_safety.patch"
PATCH_BENCHMARK_RUNTIME="${PATCH_DIR}/benchmark_runtime_gating.patch"
PATCH_SYNC="${PATCH_DIR}/runtime_sync_timing.patch"
PATCH_ASYNC="${PATCH_DIR}/async_vk_submit.patch"
PATCH_ROUTE="${PATCH_DIR}/convolution_route_test.patch"
PATCH_DISPATCH="${PATCH_DIR}/convolution_dispatch_diagnostics.patch"
PATCH_DIRECT_LOCAL_SIZE="${PATCH_DIR}/direct_conv_local_size_override.patch"
PATCH_SPIRV_DUMP="${PATCH_DIR}/spirv_dump_before_vk_create.patch"

for patch_file in "${PATCH_HEADER}" "${PATCH_SOURCE}" "${PATCH_SHADER}" "${PATCH_BENCHMARK}" "${PATCH_BENCHMARK_RUNTIME}" "${PATCH_SYNC}" "${PATCH_ASYNC}" "${PATCH_ROUTE}" "${PATCH_DISPATCH}" "${PATCH_DIRECT_LOCAL_SIZE}" "${PATCH_SPIRV_DUMP}"; do
    if [[ ! -s "${patch_file}" ]]; then
        echo "ERROR: required NCNN patch file is missing or empty: ${patch_file}" >&2
        exit 4
    fi
done

install -D -m 0644 "${PATCH_HEADER}" "${SOURCE_DIR}/src/layer/vulkan/matmul_vulkan.h"
install -D -m 0644 "${PATCH_SOURCE}" "${SOURCE_DIR}/src/layer/vulkan/matmul_vulkan.cpp"
install -D -m 0644 "${PATCH_SHADER}" "${SOURCE_DIR}/src/layer/vulkan/shader/matmul.comp"

# Apply NCNN runtime instrumentation only to the pristine pinned source. The patch
# defers query reads until the final fence, preserves query IDs across partial
# submits, validates query handles/ranges, and emits MatMul CPU/Vulkan route logs.
git -C "${SOURCE_DIR}" apply --check "${PATCH_BENCHMARK}"
git -C "${SOURCE_DIR}" apply "${PATCH_BENCHMARK}"
git -C "${SOURCE_DIR}" apply --check "${PATCH_BENCHMARK_RUNTIME}"
git -C "${SOURCE_DIR}" apply "${PATCH_BENCHMARK_RUNTIME}"
git -C "${SOURCE_DIR}" apply --check "${PATCH_SYNC}"
git -C "${SOURCE_DIR}" apply "${PATCH_SYNC}"
git -C "${SOURCE_DIR}" apply --unidiff-zero --check "${PATCH_ASYNC}"
git -C "${SOURCE_DIR}" apply --unidiff-zero "${PATCH_ASYNC}"
echo "[NCNN_PATCH] applying convolution route + route-detail diagnostics"
if ! git -C "${SOURCE_DIR}" apply --check "${PATCH_ROUTE}"; then
    echo "ERROR: convolution route patch does not match pinned NCNN source." >&2
    exit 4
fi
git -C "${SOURCE_DIR}" apply "${PATCH_ROUTE}"
if ! grep -Fq '[CONV_ROUTE_DETAIL]' "${SOURCE_DIR}/src/layer/vulkan/convolution_vulkan.cpp"; then
    echo "ERROR: route patch applied without CONV_ROUTE_DETAIL marker." >&2
    exit 4
fi
echo "[NCNN_PATCH] applying per-layer Vulkan dispatch diagnostics"
if ! git -C "${SOURCE_DIR}" apply --check "${PATCH_DISPATCH}"; then
    echo "ERROR: dispatch diagnostics patch does not match the post-route NCNN source." >&2
    echo "Context around create_pipeline() after the route patch:" >&2
    sed -n '160,210p' "${SOURCE_DIR}/src/layer/vulkan/convolution_vulkan.cpp" >&2
    exit 4
fi
git -C "${SOURCE_DIR}" apply "${PATCH_DISPATCH}"
echo "[NCNN_PATCH] applying opt-in Direct Convolution local-size override"
if ! git -C "${SOURCE_DIR}" apply --unidiff-zero --check "${PATCH_DIRECT_LOCAL_SIZE}"; then
    echo "ERROR: Direct Convolution local-size patch does not match the post-diagnostics pinned NCNN source." >&2
    exit 4
fi
git -C "${SOURCE_DIR}" apply --unidiff-zero "${PATCH_DIRECT_LOCAL_SIZE}"
echo "[NCNN_PATCH] applying opt-in final SPIR-V dump hook"
if ! git -C "${SOURCE_DIR}" apply --check "${PATCH_SPIRV_DUMP}"; then
    echo "ERROR: SPIR-V dump patch does not match the post-local-size pinned NCNN source." >&2
    exit 4
fi
git -C "${SOURCE_DIR}" apply "${PATCH_SPIRV_DUMP}"

PATCHSET_SHA="$(cat "${PATCH_HEADER}" "${PATCH_SOURCE}" "${PATCH_SHADER}" "${PATCH_BENCHMARK}" "${PATCH_BENCHMARK_RUNTIME}" "${PATCH_SYNC}" "${PATCH_ASYNC}" "${PATCH_ROUTE}" "${PATCH_DISPATCH}" "${PATCH_DIRECT_LOCAL_SIZE}" "${PATCH_SPIRV_DUMP}" | sha256sum | awk '{print $1}')"
if [[ ! "${PATCHSET_SHA}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: failed to calculate NCNN patchset SHA." >&2
    exit 4
fi

echo "NCNN_SOURCE=${SOURCE_DIR}"
echo "NCNN_SOURCE_SHA=${ACTUAL_SHA}"
echo "NCNN_SOURCE_STATUS=PINNED_BASE_WITH_LOCAL_PATCHSET"
echo "NCNN_PATCHES=MATMUL_VULKAN_FP32_ACCUMULATE+BENCHMARK_TIMESTAMP_SAFETY+RUNTIME_BENCHMARK_GATING+RUNTIME_SYNC_TIMING+ASYNC_VK_SUBMIT+PER_LAYER_DIRECT_ROUTE_DIAGNOSTIC+PER_LAYER_DISPATCH_DIAGNOSTICS+DIRECT_CONV_LOCAL_SIZE_OVERRIDE+OPT_IN_FINAL_SPIRV_DUMP"
echo "NCNN_DIRECT_CONV_LOCAL_SIZE=${DIRECT_X:-optimal}x${DIRECT_Y:-optimal}x${DIRECT_Z:-optimal}"
echo "NCNN_PATCHSET_SHA=${PATCHSET_SHA}"

# Remove previous generated outputs so no old library can survive the reset.
rm -rf "${BUILD_DIR}" "${INSTALL_PREFIX}"
mkdir -p "${BUILD_DIR}" "$(dirname "${INSTALL_PREFIX}")"

cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE="${NDK_ROOT}/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="${ABI}" \
    -DANDROID_PLATFORM="android-${API}" \
    -DANDROID_STL=c++_shared \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DNCNN_VULKAN=ON \
    -DNCNN_BATCH=ON \
    -DNCNN_BENCHMARK=ON \
    -DNCNN_BUILD_BENCHMARK=OFF \
    -DNCNN_BUILD_TESTS=OFF \
    -DNCNN_BUILD_TOOLS=OFF \
    -DNCNN_BUILD_EXAMPLES=OFF \
    -DNCNN_INSTALL_SDK=ON \
    "${DIRECT_LOCAL_SIZE_CMAKE_ARGS[@]}"

cmake --build "${BUILD_DIR}" --parallel 5
cmake --install "${BUILD_DIR}"

NCNN_CONFIG_DIR="${INSTALL_PREFIX}/lib/cmake/ncnn"
if [[ ! -f "${NCNN_CONFIG_DIR}/ncnnConfig.cmake" ]]; then
    echo "ERROR: NCNN CMake package was not installed at ${NCNN_CONFIG_DIR}." >&2
    exit 5
fi

printf '%s\n' "${EXPECTED_SHA}" > "${NCNN_CONFIG_DIR}/ncnn-source-sha.txt"
INSTALLED_SHA="$(tr -d '[:space:]' < "${NCNN_CONFIG_DIR}/ncnn-source-sha.txt")"
if [[ "${INSTALLED_SHA}" != "${EXPECTED_SHA}" ]]; then
    echo "ERROR: installed NCNN marker mismatch." >&2
    exit 6
fi

printf '%s\n' "${PATCHSET_SHA}" > "${NCNN_CONFIG_DIR}/ncnn-patchset-sha.txt"
INSTALLED_PATCHSET_SHA="$(tr -d '[:space:]' < "${NCNN_CONFIG_DIR}/ncnn-patchset-sha.txt")"
if [[ "${INSTALLED_PATCHSET_SHA}" != "${PATCHSET_SHA}" ]]; then
    echo "ERROR: installed NCNN patchset marker mismatch." >&2
    exit 6
fi

# Discard Gradle/CMake caches that could still point at an older NCNN package.
rm -rf "${REPO_ROOT}/app/.cxx" "${REPO_ROOT}/app/build"

echo "OK: pinned NCNN base + MatMul Vulkan patchset installed."
echo "NCNN_SOURCE_SHA=${INSTALLED_SHA}"
echo "NCNN_PATCHSET_SHA=${INSTALLED_PATCHSET_SHA}"
echo "ncnn_DIR=${NCNN_CONFIG_DIR}"
echo "Next:"
echo "  rm -rf app/.cxx app/build"
echo "  ./gradlew clean assembleDebug --no-configuration-cache"
