#!/usr/bin/env bash
# Prepare an OpenWrt source tree for build:
#   - apply patches from $BUILDER_REPO/patches/*.patch (if any)
#   - append custom feeds from FEEDS_LINES
#   - run feeds update/install + apply feed fixes
#   - copy device .config and run defconfig
#   - disable bundling of custom feeds into the image
#
# Required env:
#   OPENWRT_DIR    path to checked-out OpenWrt source (working dir is set here)
#   BUILDER_REPO   path to this repo
#   DEVICE_DIR     path to devices/<id>/  (relative to BUILDER_REPO)
#   FEEDS_LINES    newline-separated `src-git <name> <url>` lines
#
# Optional env:
#   COMMON_FILES   path to common/files (default: $BUILDER_REPO/common/files)

set -euo pipefail

# shellcheck source=scripts/lib/log.sh
source "$(dirname -- "$0")/lib/log.sh"

: "${OPENWRT_DIR:?OPENWRT_DIR required}"
: "${BUILDER_REPO:?BUILDER_REPO required}"
: "${DEVICE_DIR:?DEVICE_DIR required}"
: "${FEEDS_LINES:?FEEDS_LINES required}"

COMMON_FILES="${COMMON_FILES:-$BUILDER_REPO/common/files}"

cd "$OPENWRT_DIR"

# 1. Apply patches to OpenWrt tree.
patches_dir="$BUILDER_REPO/patches"
if compgen -G "$patches_dir/*.patch" >/dev/null; then
  log::info "Applying patches from $patches_dir"
  while IFS= read -r patch; do
    log::info "  $patch"
    git apply --verbose "$patch"
  done < <(find "$patches_dir" -maxdepth 1 -type f -name '*.patch' | sort)
else
  log::info "No tree patches to apply."
fi

# 2. Configure feeds.
[[ -f feeds.conf ]] || cp feeds.conf.default feeds.conf

log::info "Disabling broken third-party feeds (video) to prevent Kconfig recursion"
sed -i '/video/d' feeds.conf || true

log::info "Appending custom feeds:"
while IFS= read -r line; do
  line="${line%$'\r'}"
  [[ -z "$line" ]] && continue
  log::info "  $line"
  grep -qxF "$line" feeds.conf || echo "$line" >>feeds.conf
done <<<"$FEEDS_LINES"

log::info "Updating all feeds"
./scripts/feeds update -a

# 2a. Remove broken packages causing Kconfig recursive dependency errors
log::info "Removing recursive dependency packages (squeezelite, qt5base)"
rm -rf feeds/obsy/squeezelite package/feeds/obsy/squeezelite
rm -rf feeds/video/frameworks/qt5/qt5base package/feeds/video/qt5base

# 2b. Ensure libffi exists (moved from feeds/packages to core in newer OpenWrt)
if [[ ! -d "package/libs/libffi" && ! -d "feeds/packages/libs/libffi" ]]; then
  log::info "Restoring missing package/libs/libffi from upstream openwrt/main"
  tmp_libffi="$(mktemp -d)"
  git clone --depth 1 --filter=blob:none --sparse https://github.com/openwrt/openwrt.git "$tmp_libffi"
  git -C "$tmp_libffi" sparse-checkout set package/libs/libffi
  cp -a "$tmp_libffi/package/libs/libffi" package/libs/libffi
  rm -rf "$tmp_libffi"
fi

# 2c. Patch glib2-gobject Makefile for explicit +libffi dependency
if [[ -f "feeds/packages/libs/glib2/Makefile" ]]; then
  log::info "Ensuring glib2-gobject has +libffi dependency"
  sed -i '/^define Package\/glib2-gobject$/,/^endef$/ { /DEPENDS:=/ { /+libffi/! s/DEPENDS:=.*/& +libffi/ } }' \
    feeds/packages/libs/glib2/Makefile
fi

# Detect active kernel version in target/linux/qualcommax/Makefile (e.g. 6.12 vs 6.18)
kver="$(sed -n 's/^KERNEL_PATCHVER:=\([0-9]\+\.[0-9]\+\).*/\1/p' target/linux/qualcommax/Makefile | head -n 1)"
if grep -q '^CONFIG_TESTING_KERNEL=y' "$BUILDER_REPO/$DEVICE_DIR/config" 2>/dev/null; then
  tkver="$(sed -n 's/^KERNEL_TESTING_PATCHVER:=\([0-9]\+\.[0-9]\+\).*/\1/p' target/linux/qualcommax/Makefile | head -n 1)"
  [[ -n "$tkver" ]] && kver="$tkver"
fi
log::info "Detected target kernel version: ${kver:-unknown}"

# 2d. Apply local patches to feed packages (patches/feeds/*/*.patch)
shopt -s nullglob
for p in "$BUILDER_REPO"/patches/feeds/*/*.patch; do
  patch_name="$(basename "$p")"
  feed="feeds/$(basename "$(dirname "$p")")"

  # Apply older-kernel patches (like attr xattr_args) ONLY on kernel 6.12, skip on 6.18+
  if [[ "$patch_name" == *"older-kernels"* && "${kver:-}" != "6.12" ]]; then
    log::info "Skipping $patch_name (not needed for kernel ${kver:-unknown})"
    continue
  fi

  if [[ "$patch_name" == *"attr-fix-xattr_args"* && -f "feeds/packages/utils/attr/Makefile" ]]; then
    sed -i 's/-DXATTR_ARGS_SIZE_VER0=16//g' feeds/packages/utils/attr/Makefile || true
  fi

  if patch -p1 -d "$feed" --dry-run --forward < "$p" >/dev/null 2>&1; then
    log::info "Patching $feed with $patch_name"
    patch -p1 -d "$feed" --forward < "$p"
  elif patch -p1 -d "$feed" --dry-run --reverse < "$p" >/dev/null 2>&1; then
    log::info "Skipping $patch_name (already applied)"
  else
    log::die "$patch_name does not apply to $feed"
  fi
done
shopt -u nullglob

log::info "Installing all feeds"
rm -rf tmp
./scripts/feeds install -a -f

# 3. Drop in device .config and resolve.
log::info "Loading device config: $DEVICE_DIR/config"
cp "$BUILDER_REPO/$DEVICE_DIR/config" .config
make defconfig

# 4. Disable bundling of custom feeds into the image (we declared them as
#    src-git but don't want every package shipped by default).
log::info "Disabling CONFIG_FEED_<custom> entries"
while IFS= read -r line; do
  line="${line%$'\r'}"
  [[ -z "$line" ]] && continue
  feed_name="$(awk '{print $2}' <<<"$line")"
  sed -i "s/^CONFIG_FEED_${feed_name}=.*/# CONFIG_FEED_${feed_name} is not set/" .config || true
done <<<"$FEEDS_LINES"
sed -i 's/^CONFIG_FEED_luci_extra=.*/# CONFIG_FEED_luci_extra is not set/' .config || true

# 5. Copy custom files (common first, then device-specific so device wins).
log::info "Applying overlay files"
mkdir -p files

if [[ -d "$COMMON_FILES" ]]; then
  log::info "  common: $COMMON_FILES"
  rsync -a "$COMMON_FILES/" files/
fi

if [[ -d "$BUILDER_REPO/$DEVICE_DIR/files" ]]; then
  log::info "  device: $BUILDER_REPO/$DEVICE_DIR/files"
  rsync -a "$BUILDER_REPO/$DEVICE_DIR/files/" files/
fi

# Lock down sshd_config if shipped.
if [[ -f files/etc/ssh/sshd_config ]]; then
  chmod 0600 files/etc/ssh/sshd_config
fi

log::info "Build environment ready."