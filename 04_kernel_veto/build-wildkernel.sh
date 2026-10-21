#!/usr/bin/env bash
# Build GKI 5.15 kernel with WildKernels patches (KernelSU-Next + SUSFS) + dexp_veto
# Runs in Docker (Ubuntu 22.04). Output: AnyKernel3 flashable zip.
set -euo pipefail

# --- Configuration ---
KERNEL_VERSION="5.15"
ANDROID_VERSION="android13"
OS_PATCH_LEVEL="2024-06"   # SUBLEVEL=149, matches 5.15.149
SUBLEVEL="149"
VERSION="${ANDROID_VERSION}-${KERNEL_VERSION}"
BRAND_NAME="Wild"
ROOT_FLAVOR="next"         # KernelSU-Next

# Paths (host)
HOST_WK="$(cd "$(dirname "$0")/../GKI_KernelSU_SUSFS" && pwd)"
HOST_VETO="$(cd "$(dirname "$0")" && pwd)"
HOST_OUT="${HOST_VETO}/out"
mkdir -p "${HOST_OUT}"

# Container workspace
WK=/workspace/wildkernels   # WildKernels CI repo (actions, configs, pins)
KROOT=/workspace/kernel     # repo-synced kernel tree
SRC="${WK}"

# Resolve dynamic commits --------------------------------------------------
echo "=== Resolving dynamic commits ==="

# KernelSU-Next (with SUSFS): use pershoot's dev-susfs fork
NEXT_COMMIT="$(git ls-remote https://github.com/pershoot/KernelSU-Next.git refs/heads/dev-susfs | awk '{print $1; exit}')"
[ -n "$NEXT_COMMIT" ] && [ "${#NEXT_COMMIT}" -eq 40 ] || { echo "Failed to resolve pershoot/KernelSU-Next dev-susfs commit"; exit 1; }
echo "KernelSU-Next (pershoot/dev-susfs): ${NEXT_COMMIT}"

# SUSFS: latest on gki-android13-5.15 branch
SUSFS_COMMIT="$(git ls-remote https://gitlab.com/simonpunk/susfs4ksu.git refs/heads/gki-${VERSION} | awk '{print $1; exit}')"
[ -n "$SUSFS_COMMIT" ] && [ "${#SUSFS_COMMIT}" -eq 40 ] || { echo "Failed to resolve SUSFS commit"; exit 1; }
echo "SUSFS: ${SUSFS_COMMIT}"

# Build Docker command prefix (no -it since we run non-interactively)
DOCKER_RUN="docker run --rm --platform=linux/amd64 \
  --memory=8g \
  -v ${HOST_WK}:${WK}:ro \
  -v ${HOST_VETO}:${HOST_VETO}:ro \
  -v ${HOST_OUT}:/out \
  -e WK=${WK} \
  -e KROOT=${KROOT} \
  -e VERSION=${VERSION} \
  -e ANDROID_VERSION=${ANDROID_VERSION} \
  -e KERNEL_VERSION=${KERNEL_VERSION} \
  -e SUBLEVEL=${SUBLEVEL} \
  -e OS_PATCH_LEVEL=${OS_PATCH_LEVEL} \
  -e BRAND_NAME=${BRAND_NAME} \
  -e ROOT_FLAVOR=${ROOT_FLAVOR} \
  -e NEXT_COMMIT=${NEXT_COMMIT} \
  -e NEXT_REPO=https://github.com/pershoot/KernelSU-Next.git \
  -e SUSFS_COMMIT=${SUSFS_COMMIT} \
  -e SRC=${SRC} \
  -e HOST_VETO=${HOST_VETO} \
  -e DEBIAN_FRONTEND=noninteractive \
  kernel-builder:latest"

# Build script that runs INSIDE Docker ------------------------------------
read -r -d '' BUILD_SCRIPT << 'INNERSCRIPT' || true
set -euo pipefail

echo "=== [container] Setting up build environment ==="

# Configure git
git config --global user.name "builder"
git config --global user.email "builder@local"

mkdir -p ${KROOT}
echo "=== [container] repo init/sync ==="
cd ${KROOT}
MANIFEST_BRANCH="common-${VERSION}-${OS_PATCH_LEVEL}"
# The kernel source branch inside the manifest, e.g. "android13-5.15-2024-06"
KERNEL_BRANCH="${VERSION}-${OS_PATCH_LEVEL}"

# Try init
repo init -u https://android.googlesource.com/kernel/manifest -b ${MANIFEST_BRANCH} --depth=1 \
  || { echo "repo init failed"; exit 1; }

# Check if the kernel branch common/<rev> is active or deprecated
KERNEL_BRANCH_CHECK=$(git ls-remote --heads https://android.googlesource.com/kernel/common 2>&1 | grep "refs/heads/${KERNEL_BRANCH}$" || true)
echo "Kernel branch check for '${KERNEL_BRANCH}': $(test -n "$KERNEL_BRANCH_CHECK" && echo 'FOUND' || echo 'not found')"
if [ -z "$KERNEL_BRANCH_CHECK" ]; then
  echo "Branch ${KERNEL_BRANCH} not found as active, checking deprecated..."
  DEP_BRANCH="deprecated/${KERNEL_BRANCH}"
  DEP_BRANCH_CHECK=$(git ls-remote --heads https://android.googlesource.com/kernel/common 2>&1 | grep "refs/heads/${DEP_BRANCH}$" || true)
  echo "Deprecated branch check for '${DEP_BRANCH}': $(test -n "$DEP_BRANCH_CHECK" && echo 'FOUND' || echo 'not found')"
  if [ -n "$DEP_BRANCH_CHECK" ]; then
    echo "Kernel branch is deprecated, patching manifest..."
    sed -i "s|\"${KERNEL_BRANCH}\"|\"${DEP_BRANCH}\"|g" .repo/manifests/default.xml
    echo "Manifest now contains:"
    grep 'revision=' .repo/manifests/default.xml
  else
    echo "Neither active nor deprecated found, trying tag fallback..."
    LATEST_TAG=$(git ls-remote https://android.googlesource.com/kernel/common "refs/tags/${KERNEL_BRANCH}_r*" 2>/dev/null \
      | awk '{print $2}' | grep -v '\^{}$' | sed 's|refs/tags/||' | awk -F'_r' '{print $NF+0, $0}' \
      | sort -n | tail -n1 | cut -d' ' -f2- || true)
    if [ -n "$LATEST_TAG" ]; then
      sed -i "/path=\"common\"/ s|revision=\"${KERNEL_BRANCH}\"|revision=\"refs/tags/${LATEST_TAG}\"|" .repo/manifests/default.xml
      echo "Falling back to tag: ${LATEST_TAG}"
    else
      echo "ERROR: cannot resolve kernel source for ${KERNEL_BRANCH}" >&2
      exit 1
    fi
  fi
fi

# Sync (shallow, only what we need)
repo sync -c --current-branch --no-clone-bundle --no-tags --jobs-checkout=4 -j$(nproc)

cd ${KROOT}/common
echo "Kernel commit: $(git log -1 --oneline)"

echo "=== [container] Kernel Fixes ==="
cd ${KROOT}/common
# GLIBC >=2.38 fix for resolve_btfids/Makefile (not needed on 22.04's glibc)
# BUT apply parse-options.c fix if sublevel <= 119 (ours is 149, so skip)
# mmap.c fix for specific version combo - not needed for 5.15.149
echo "Kernel fixes: skipped (not applicable for 5.15.149)"

echo "=== [container] Setup KernelSU-Next ==="
cd ${KROOT}
git clone --no-checkout ${NEXT_REPO}
git -C KernelSU-Next fetch --depth=1 origin ${NEXT_COMMIT}
git -C KernelSU-Next checkout --detach ${NEXT_COMMIT}
# Verify
actual="$(git -C KernelSU-Next rev-parse HEAD)"
[ "${actual}" = "${NEXT_COMMIT}" ] || { echo "KernelSU-Next commit mismatch"; exit 1; }

# Wire into kernel tree (symlink drivers/kernelsu -> KernelSU-Next/kernel)
cd ${KROOT}
ln -s ../../KernelSU-Next/kernel common/drivers/kernelsu
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' common/drivers/Makefile \
  || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> common/drivers/Makefile
grep -q 'source "drivers/kernelsu/Kconfig"' common/drivers/Kconfig \
  || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' common/drivers/Kconfig

# Enable CONFIG_KSU in defconfig
cd ${KROOT}/common
DEF="arch/arm64/configs/gki_defconfig"
grep -q '^CONFIG_KSU=y' ${DEF} || echo 'CONFIG_KSU=y' >> ${DEF}
# Disable BTF to avoid pahole/resolve_btfids toolchain issues
grep -q '^CONFIG_DEBUG_INFO_BTF' ${DEF} && sed -i 's/CONFIG_DEBUG_INFO_BTF=y/CONFIG_DEBUG_INFO_BTF=n/' ${DEF} || echo 'CONFIG_DEBUG_INFO_BTF=n' >> ${DEF}
# Also ensure it's not set to 'is not set' or y (idempotent)
grep -q '^# CONFIG_DEBUG_INFO_BTF is not set' ${DEF} || true

# Soften KernelSU-Next Kbuild guard (error -> warning during mrproper)
for d in drivers/kernelsu; do
  if [ -f "${KROOT}/common/${d}/Kbuild" ] && grep -q 'requires either CONFIG_KPROBES' "${KROOT}/common/${d}/Kbuild"; then
    sed -i 's/$(error "KernelSU requires either CONFIG_KPROBES=y or CONFIG_KSU_SUSFS=y")/$(warning "KernelSU requires either CONFIG_KPROBES=y or CONFIG_KSU_SUSFS=y")/' "${KROOT}/common/${d}/Kbuild"
  fi
done

echo "KernelSU-Next integrated at ${NEXT_COMMIT}"

echo "=== [container] Setup SUSFS ==="
cd ${KROOT}
git clone --no-checkout https://gitlab.com/simonpunk/susfs4ksu.git
git -C susfs4ksu fetch --depth=1 origin ${SUSFS_COMMIT}
git -C susfs4ksu checkout --detach ${SUSFS_COMMIT}

# Apply SUSFS kernel patches
cd ${KROOT}/common
PATCH_DIR="${KROOT}/susfs4ksu/kernel_patches"

# First copy the SUSFS source files into the kernel tree
if [ -d "${KROOT}/susfs4ksu/fs" ]; then
  echo "Copying SUSFS fs/ files..."
  cp -r ${KROOT}/susfs4ksu/fs/* ./fs/ 2>/dev/null || true
fi
if [ -d "${KROOT}/susfs4ksu/include" ]; then
  echo "Copying SUSFS include/ files..."
  cp -r ${KROOT}/susfs4ksu/include/* ./include/ 2>/dev/null || true
fi

# 50_add_susfs_in_gki-${VERSION}.patch
if [ -f "${PATCH_DIR}/50_add_susfs_in_gki-${VERSION}.patch" ]; then
  echo "Applying ${PATCH_DIR}/50_add_susfs_in_gki-${VERSION}.patch"
  patch -p1 < "${PATCH_DIR}/50_add_susfs_in_gki-${VERSION}.patch" || true
else
  echo "WARNING: 50_add_susfs_in_gki-${VERSION}.patch not found"
fi

# Apply SUSFS for KernelSU-Next (Next already ships SUSFS, so 10_enable not needed for next flavor)
# But we do need the fs/susfs entry built: enable configs
DEF="${KROOT}/common/arch/arm64/configs/gki_defconfig"
for cfg in \
  CONFIG_KSU_SUSFS=y \
  CONFIG_KSU_SUSFS_SUS_PATH=y \
  CONFIG_KSU_SUSFS_SUS_MOUNT=y \
  CONFIG_KSU_SUSFS_SUS_KSTAT=y \
  CONFIG_KSU_SUSFS_SPOOF_UNAME=y \
  CONFIG_KSU_SUSFS_ENABLE_LOG=y \
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y \
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y \
  CONFIG_KSU_SUSFS_SUS_MAP=y \
  CONFIG_KSU_SUSFS_OPEN_REDIRECT=y; do
  key="${cfg%%=*}"
  if grep -q "^${key}=" "${DEF}"; then
    sed -i "s|^${key}=.*|${cfg}|" "${DEF}"
  elif grep -q "^# ${key} is not set" "${DEF}"; then
    sed -i "s|^# ${key} is not set|${cfg}|" "${DEF}"
  else
    echo "${cfg}" >> "${DEF}"
  fi
done

echo "SUSFS integrated at ${SUSFS_COMMIT}"

echo "=== [container] Networking Patches ==="
cd ${KROOT}/common
# Apply networking configs
for cfg in \
  CONFIG_IP_NF_SET=y \
  CONFIG_IP_SET=y \
  CONFIG_IP_SET_HASH_IPPORT=y \
  CONFIG_IP_SET_HASH_IPMARK=y \
  CONFIG_NETFILTER_XT_SET=y \
  CONFIG_TCP_CONG_BBR=y \
  CONFIG_NET_SCHED=y \
  CONFIG_NET_SCH_FQ=y \
  CONFIG_NET_SCH_FQ_CODEL=y \
  CONFIG_NET_SCH_CAKE=y \
  CONFIG_WIREGUARD=y; do
  key="${cfg%%=*}"
  if grep -q "^${key}=" "${DEF}"; then
    sed -i "s|^${key}=.*|${cfg}|" "${DEF}"
  elif grep -q "^# ${key} is not set" "${DEF}"; then
    sed -i "s|^# ${key} is not set|${cfg}|" "${DEF}"
  else
    echo "${cfg}" >> "${DEF}"
  fi
done

echo "Networking configs applied"

echo "=== [container] Misc Configs ==="
cd ${KROOT}/common
for cfg in \
  CONFIG_OVERLAY_FS=y \
  CONFIG_TMPFS_XATTR=y \
  CONFIG_TMPFS_POSIX_ACL=y \
  CONFIG_KALLSYMS=y \
  CONFIG_KALLSYMS_ALL=y; do
  key="${cfg%%=*}"
  if grep -q "^${key}=" "${DEF}"; then
    sed -i "s|^${key}=.*|${cfg}|" "${DEF}"
  elif grep -q "^# ${key} is not set" "${DEF}"; then
    sed -i "s|^# ${key} is not set|${cfg}|" "${DEF}"
  else
    echo "${cfg}" >> "${DEF}"
  fi
done

echo "=== [container] Fix net/netfilter case-sensitivity bugs ==="
cd ${KROOT}/common
# macOS-origin filesystem case bugs on Linux
if [ -f "net/netfilter/Makefile" ]; then
  sed -i 's/xt_DSCP/xt_dscp/g' net/netfilter/Makefile
  sed -i 's/xt_HL/xt_hl/g' net/netfilter/Makefile
  sed -i 's/xt_RATEEST/xt_rateest/g' net/netfilter/Makefile
  sed -i 's/xt_TCPMSS/xt_tcpmss/g' net/netfilter/Makefile
  echo "net/netfilter case fixes applied"
fi

echo "=== [container] Inject dexp_veto driver ==="
bash "${HOST_VETO}/fork-patch/inject.sh" "${KROOT}"

echo "=== [container] Kernel Branding ==="
cd ${KROOT}/common
# Apply branding: append -android13-Wild to version
if grep -q 'scm_version}' scripts/setlocalversion; then
  sed -i '$d' scripts/setlocalversion
  echo "echo \"${SUBLEVEL}-${ANDROID_VERSION}-${BRAND_NAME}\"" >> scripts/setlocalversion
else
  sed -i '$d' scripts/setlocalversion
  echo "echo \"-${ANDROID_VERSION}-${BRAND_NAME}\"" >> scripts/setlocalversion
fi
chmod +x scripts/setlocalversion
echo "Branding: $(tail -n1 scripts/setlocalversion)"

echo "=== [container] Clean Dirty Flags ==="
cd ${KROOT}/common
sed -i 's/-dirty//' scripts/setlocalversion 2>/dev/null || true
git add -A 2>/dev/null || true
git commit -m "Wild: pre-build cleanup" 2>/dev/null || true

echo "=== [container] Build Kernel ==="
cd ${KROOT}

# Disable defconfig check (our custom config has CONFIG_DEXP_VETO=y)
sed -i 's/check_defconfig//' common/build.config.gki

export BUILD_GKI_ARTIFACTS=""
export BUILD_GKI_CERTIFICATION_TOOLS=0
export BUILD_SYSTEM_DLKM=0
export SKIP_VENDOR_BOOT=1
export SKIP_EXT_MODULES=1
export SKIP_CP_KERNEL_HDR=1
export OUT_DIR="/out/build"
export LTO=thin
export BUILD_CONFIG=common/build.config.gki.aarch64

# Use ccache
CCACHE=$(which ccache || true)
CC="${CCACHE} clang"
CXX="${CCACHE} clang++"
HOSTCC="${CCACHE} clang"
HOSTCXX="${CCACHE} clang++"

mkdir -p /out/build
# Build kernel Image directly - use LLVM=1 for clang + lld, no headers/modules
cd ${KROOT}/common
# First set up the config from our modified defconfig
make O=/out/build/common ARCH=arm64 LLVM=1 gki_defconfig 2>&1 || true
# Then build just the Image (no headers, no modules, no BTF)
make O=/out/build/common ARCH=arm64 LLVM=1 -j$(nproc) Image 2>&1 || true
cd ${KROOT}
echo "Build finished"

echo "=== [container] Gather Artifacts ==="
if [ -f "/out/build/dist/Image" ]; then
  echo "Build succeeded! Image found at /out/build/dist/Image"
  ls -lh /out/build/dist/Image
  # Copy for packaging
  cp /out/build/dist/Image /out/Image
elif [ -f "/out/build/Image" ]; then
  echo "Build succeeded! Image found at /out/build/Image"
  ls -lh /out/build/Image
  cp /out/build/Image /out/Image
else
  echo "Searching for Image..."
  find /out -name "Image" -type f 2>/dev/null
  # Try wider search
  find ${KROOT} -name "Image" -type f 2>/dev/null | head -5
fi

echo ""
echo "=== Build Complete ==="
INNERSCRIPT

# Execute the build inside Docker
echo "Starting Docker build..."
${DOCKER_RUN} bash -euo pipefail -c "${BUILD_SCRIPT}"

# Check result
if [ -f "${HOST_OUT}/Image" ]; then
  echo ""
  echo "=== SUCCESS ==="
  echo "Kernel Image: ${HOST_OUT}/Image"
  ls -lh "${HOST_OUT}/Image"
  file "${HOST_OUT}/Image"
else
  echo ""
  echo "=== Build completed (check for Image in ${HOST_OUT}) ==="
  ls -la "${HOST_OUT}" 2>/dev/null || echo "(empty)"
fi
