#!/bin/bash

set -o pipefail
IFS=$'\n\t'

# ── Configuration ──────────────────────────────────────────────────────────────
ROM_NAME="${ROM_NAME:-crDroid}"
ROM_MANIFEST="${ROM_MANIFEST:-https://github.com/crdroidandroid/android.git}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-16.0}"

DEVICE="rtwo"
BUILD_TYPE="userdebug"
LUNCH_TARGET="lineage_rtwo-bp4a-userdebug"

LOCAL_MANIFEST_REPO="https://github.com/mas4112/local_manifests"
LOCAL_MANIFEST_BRANCH="lineage-23.2"

BUILD_HOSTNAME="${BUILD_HOSTNAME:-crave}"
OUT_DIR="out/target/product/${DEVICE}"
START_TIME=$(date +%s)

# ── Logging ────────────────────────────────────────────────────────────────────
BUILD_LOG_DIR="${PWD}/build_logs"
mkdir -p "$BUILD_LOG_DIR"
TS="$(date +%s)"
BUILD_LOG="${BUILD_LOG_DIR}/build_${DEVICE}_${TS}.log"
ERROR_LOG="${BUILD_LOG_DIR}/error_${DEVICE}_${TS}.log"
SYNC_LOG="${BUILD_LOG_DIR}/sync_${DEVICE}_${TS}.log"

log()     { echo "[$(date '+%F %T')] $*"          | tee -a "$BUILD_LOG"; }
warn()    { echo "[$(date '+%F %T')] WARN: $*"    | tee -a "$BUILD_LOG"; }
err()     { echo "[$(date '+%F %T')] ERROR: $*"   | tee -a "$ERROR_LOG" >&2; }
success() { echo "[$(date '+%F %T')] SUCCESS: $*" | tee -a "$BUILD_LOG"; }

# Fail handler
on_fail() {
  err "Pipeline encountered an unrecoverable crash point. Halting."
  exit 1
}

# ==============================================================================
# PHASE 1 — Cleanup device-scoped artifacts
# ==============================================================================
phase_cleanup() {
  log "[1/5] Cleaning device-scoped artifacts for ${DEVICE}"

  local paths=(
    ".repo/local_manifests"
    "${OUT_DIR}"
    "device/motorola/${DEVICE}"
    "vendor/motorola/${DEVICE}"
    "kernel/motorola/sm8550"
    "frameworks/base"
  )

  for p in "${paths[@]}"; do
    if [ -e "$p" ]; then
      log "  Removing: $p"
      rm -rf "$p"
    fi
  done

  success "Cleanup complete"
}

# ==============================================================================
# PHASE 2 — Manifest init + local manifests injection
# ==============================================================================
phase_manifest_init() {
  log "[2/5] Manifest initialization"

  if [ ! -d ".repo" ]; then
    log "  .repo not found — running repo init"
    if ! repo init -u "${ROM_MANIFEST}" -b "${MANIFEST_BRANCH}" --git-lfs --depth=1 \
         2>&1 | tee -a "$SYNC_LOG"; then
      err "repo init failed"
      on_fail
    fi
  else
    log "  .repo present — skipping repo init"
  fi

  log "  Cloning local manifests: ${LOCAL_MANIFEST_REPO} (${LOCAL_MANIFEST_BRANCH})"
  rm -rf .repo/local_manifests
  if ! git clone -b "${LOCAL_MANIFEST_BRANCH}" --depth 1 \
       "${LOCAL_MANIFEST_REPO}" .repo/local_manifests 2>&1 | tee -a "$SYNC_LOG"; then
    err "Local manifests clone failed"
    on_fail
  fi

  success "Manifest ready"
}

# ==============================================================================
# PHASE 3 — Source sync + targeted clang force-sync
# ==============================================================================
phase_sync() {
  log "[3/5] Syncing source"
  local SYNC_START SYNC_END SYNC_DIFF SYNC_TIME

  SYNC_START=$(date +%s)

  if [ -x /opt/crave/resync.sh ]; then
    log "  Using Crave resync wrapper"
    if ! /opt/crave/resync.sh 2>&1 | tee -a "$SYNC_LOG"; then
      err "Crave resync wrapper failed"
      on_fail
    fi
  else
    log "  Using standard repo sync"
    repo sync -c --no-tags --no-clone-bundle 2>&1 | tee -a "$SYNC_LOG" || \
      warn "repo sync reported warnings — continuing"
  fi

  # Force-sync clang to fix stale-version toolchain failures
  log "  Force-syncing prebuilts/clang/host/linux-x86"
  if ! repo sync -c --force-sync --no-tags --no-clone-bundle \
       prebuilts/clang/host/linux-x86 2>&1 | tee -a "$SYNC_LOG"; then
    warn "Clang force-sync had issues — build may still succeed"
  else
    local CLANG_VER
    CLANG_VER=$(ls -dt prebuilts/clang/host/linux-x86/clang-r* 2>/dev/null | head -1 | xargs basename 2>/dev/null)
    [ -n "$CLANG_VER" ] && log "  Toolchain: ${CLANG_VER}"
  fi

  SYNC_END=$(date +%s)
  SYNC_DIFF=$((SYNC_END - SYNC_START))
  if [ "$SYNC_DIFF" -ge 3600 ]; then
    SYNC_TIME="$((SYNC_DIFF/3600))h $(((SYNC_DIFF%3600)/60))min"
  else
    SYNC_TIME="$((SYNC_DIFF/60)) min"
  fi

  success "Sync complete (${SYNC_TIME})"
}

# ==============================================================================
# PHASE 4 — Build environment setup
# ==============================================================================
phase_env_setup() {
  log "[4/5] Setting up build environment"

  if [ ! -f "build/envsetup.sh" ]; then
    err "build/envsetup.sh not found — sync may have failed"
    on_fail
  fi

  export TARGET_ENABLE_BLUR=false
  export WITH_ADB_INSECURE=true
  export SELINUX_IGNORE_NEVERALLOWS=true
  export WITH_GMS=false
  export TARGET_USES_PICO_GAPPS=true
  export BUILD_HOSTNAME="${BUILD_HOSTNAME}"

  # shellcheck source=/dev/null
  source build/envsetup.sh

  log "  Lunching: ${LUNCH_TARGET}"
  if ! lunch "${LUNCH_TARGET}"; then
    err "lunch failed for: ${LUNCH_TARGET}"
    on_fail
  fi

  log "  Running installclean"
  mka installclean 2>&1 | tee -a "$BUILD_LOG" || warn "installclean reported issues"

  success "Environment ready"
}

# ==============================================================================
# PHASE 5 — Compile
# ==============================================================================
phase_build() {
  log "[5/5] Building ${ROM_NAME} for ${DEVICE}"

  local BUILD_START
  BUILD_START=$(date +%s)

  if ! mka bacon 2>&1 | tee -a "$BUILD_LOG"; then
    err "mka bacon failed"
    on_fail
  fi

  if grep -q -E "ninja failed|failed to build some targets" "$BUILD_LOG"; then
    err "Ninja reported failures in build log"
    on_fail
  fi

  local BUILD_END DUR BUILD_TIME
  BUILD_END=$(date +%s)
  DUR=$((BUILD_END - BUILD_START))
  if [ "$DUR" -ge 3600 ]; then
    BUILD_TIME="$((DUR/3600))h $(((DUR%3600)/60))min"
  else
    BUILD_TIME="$((DUR/60)) min"
  fi

  success "Build completed in ${BUILD_TIME}"
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
  log "=========================================="
  log " CRAVE FOSS ROM BUILD — ${ROM_NAME} / ${DEVICE}"
  log " Manifest : ${ROM_MANIFEST} (${MANIFEST_BRANCH})"
  log " Target   : ${LUNCH_TARGET}"
  log "=========================================="

  phase_cleanup
  phase_manifest_init
  phase_sync
  phase_env_setup
  phase_build
}

main "$@"
exit $?
