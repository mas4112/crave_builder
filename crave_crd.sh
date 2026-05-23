#!/bin/bash
# ============================================================================
# crDroid 16.0 | Motorola rtwo (Snapdragon 8 Gen 2 / sm8550)
# ============================================================================
set -eo pipefail
IFS=$'\n\t'

# ── Logging ──────────────────────────────────────────────────────────────────
mkdir -p "${PWD}/build_logs"
BUILD_TS=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${PWD}/build_logs/rtwo_${BUILD_TS}.log"
echo "Build log: ${LOG_FILE}"

# ── STEP 1: Targeted Cleanup ─────────────────────────────────────────────────
echo "[1/7] Cleaning device-specific directories..."
rm -rf .repo/local_manifests

rm -rf device/motorola/rtwo
rm -rf device/motorola/sm8550-common
rm -rf vendor/motorola/rtwo
rm -rf vendor/motorola/sm8550-common
rm -rf kernel/motorola/sm8550
rm -rf kernel/motorola/sm8550-devicetrees
rm -rf kernel/motorola/sm8550-modules
rm -rf hardware/motorola

# Clear only the device output
# rm -rf out/target/product/rtwo

# ── STEP 2: Repo Init ────────────────────────────────────────────────────────
echo "[2/7] Initializing crDroid 16.0 manifest over LOS 22.1 base..."
repo init \
  -u https://github.com/crdroidandroid/android.git \
  -b 16.0 \
  --depth=1 \
  --git-lfs

# ── STEP 3: Sync Base Sources ────────────────────────────────────────────────
echo "[3/7] Syncing platform sources..."
if [ -f /opt/crave/resync.sh ]; then
  /opt/crave/resync.sh
else
  repo sync -c --force-sync --no-clone-bundle --no-tags -j$(nproc --all)
fi

# ── STEP 4: Force Clang Toolchain Replacement ────────────────────────────────
echo "[4/7] Replacing Clang toolchain with pinned android-16.0.0_r4 snapshot..."
rm -rf prebuilts/clang/host/linux-x86
git clone https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
  -b android-16.0.0_r4 \
  --depth=1 \
  prebuilts/clang/host/linux-x86

CLANG_LATEST=$(ls -dt prebuilts/clang/host/linux-x86/clang-r* 2>/dev/null | head -1)
echo "Active toolchain: $(basename "${CLANG_LATEST:-not found}")"

# ── STEP 5: Clone Device Sources ─────────────────────────────────────────────
echo "[5/7] Cloning device trees and vendor blobs..."
git clone https://github.com/mas4112/android_device_motorola_rtwo \
  -b lineage-23.2 --depth=1 device/motorola/rtwo

git clone https://github.com/LineageOS/android_device_motorola_sm8550-common \
  -b lineage-23.2 --depth=1 device/motorola/sm8550-common

git clone https://github.com/LineageOS/android_kernel_motorola_sm8550 \
  -b lineage-23.2 --depth=1 kernel/motorola/sm8550

git clone https://github.com/LineageOS/android_kernel_motorola_sm8550-devicetrees \
  -b lineage-23.2 --depth=1 kernel/motorola/sm8550-devicetrees

git clone https://github.com/LineageOS/android_kernel_motorola_sm8550-modules \
  -b lineage-23.2 --depth=1 kernel/motorola/sm8550-modules

git clone https://github.com/TheMuppets/proprietary_vendor_motorola_sm8550-common \
  -b lineage-23.2 --depth=1 vendor/motorola/sm8550-common

git clone https://github.com/TheMuppets/proprietary_vendor_motorola_rtwo \
  -b lineage-23.2 --depth=1 vendor/motorola/rtwo

git clone https://github.com/LineageOS/android_hardware_motorola \
  -b lineage-23.2 --depth=1 hardware/motorola

# ── STEP 6: Build Environment ────────────────────────────────────────────────
echo "[6/7] Configuring build environment..."
export USE_CCACHE=0
export CCACHE_EXEC=""
export TARGET_ENABLE_BLUR=false
export WITH_ADB_INSECURE=true
export SELINUX_IGNORE_NEVERALLOWS=true
export WITH_GMS=false
export BUILD_HOSTNAME="crave"

# shellcheck source=/dev/null
source build/envsetup.sh
lunch lineage_rtwo-bp4a-userdebug

mka installclean || true

# ── STEP 7: Build ────────────────────────────────────────────────────────────
echo "[7/7] Starting compilation... (log: ${LOG_FILE})"
set +e
mka bacon 2>&1 | tee "${LOG_FILE}"
BUILD_EXIT="${PIPESTATUS[0]}"
set -e

# ── Output Verification ──────────────────────────────────────────────────────
ZIP=$(ls -t out/target/product/rtwo/*.zip 2>/dev/null | head -1)
if [ -n "$ZIP" ] && [ "${BUILD_EXIT:-0}" -eq 0 ]; then
  echo ""
  echo "✅ Build successful: $(basename "$ZIP") ($(du -h "$ZIP" | cut -f1))"
else
  echo "❌ Build failed or no output ZIP found — check ${LOG_FILE}"
  exit 1
fi
