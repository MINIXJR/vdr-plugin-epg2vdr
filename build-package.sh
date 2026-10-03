#!/bin/bash
# Build script with automatic version management and changelog prompts
# for vdr-plugin-epg2vdr (forked from horchi/vdr-plugin-epg2vdr).
#
# Produces two binary packages:
#   vdr-plugin-epg2vdr      (the plugin itself, amd64)
#   vdr-plugin-epg2vdr-dbg  (debug symbols, amd64)
#
# Version scheme: ${HISTORY.h _VERSION}+git${date}-${count}-${hash}
#                 -1minixjr0~noble+local-N
#
# The 1minixjr0 revision keeps fork builds distinguishable from upstream
# yavdr packages in dpkg -l. It does NOT protect against yavdr upgrades:
# dpkg compares the upstream part (+git<date>-...) first, so any newer
# yavdr snapshot replaces the fork build on "apt full-upgrade" (happened
# 2026-09-12). Pin the installed fork build with
#   sudo apt-mark hold vdr-plugin-epg2vdr
set -e

PROJECT_NAME="vdr-plugin-epg2vdr"
SOURCE_DIR="/usr/local/src/user/vdr-plugin-epg2vdr"
BUILD_BASE_DIR="/usr/local/src/user"
DISTRO="noble"

PACKAGES=(
    "vdr-plugin-epg2vdr"
    "vdr-plugin-epg2vdr-dbg"
)

cd "$SOURCE_DIR"

# Extract version from HISTORY.h (#define _VERSION "1.2.17")
BASE_VERSION=$(grep 'define _VERSION ' HISTORY.h | awk '{ print $3 }' | sed -e 's/[";]//g')
GIT_DATE=$(git log -1 --format=%cd --date=format:%Y%m%d)
GIT_HASH=$(git rev-parse --short HEAD)
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
GIT_COMMIT_COUNT=$(git rev-list --count HEAD)

echo "==> Building version: ${BASE_VERSION}+git${GIT_DATE}-${GIT_COMMIT_COUNT}-${GIT_HASH}"
echo "==> Git branch: $GIT_BRANCH (commit $GIT_HASH)"
echo "==> Packages to build: ${PACKAGES[*]}"
echo ""

read -p "Enter changelog description: " CHANGELOG_MSG

if [ -z "$CHANGELOG_MSG" ]; then
    echo "ERROR: Changelog description cannot be empty"
    exit 1
fi

BUILD_VERSION="${BASE_VERSION}+git${GIT_DATE}-${GIT_COMMIT_COUNT}-${GIT_HASH}"
DEBIAN_REVISION="1minixjr0~${DISTRO}"
BUILD_DIR="${BUILD_BASE_DIR}/${PROJECT_NAME}-${BUILD_VERSION}-${DEBIAN_REVISION}"

# Auto-increment +local-N if we already built this exact BUILD_VERSION
LAST_VERSION=$(head -1 debian/changelog | sed -n 's/.*(\([^)]*\)).*/\1/p')
BUILD_VERSION_ESCAPED=$(echo "$BUILD_VERSION" | sed 's/[+.]/\\&/g')
DEBIAN_REVISION_ESCAPED=$(echo "$DEBIAN_REVISION" | sed 's/[~]/\\&/g')
if [[ "$LAST_VERSION" =~ ^${BUILD_VERSION_ESCAPED}-${DEBIAN_REVISION_ESCAPED}\+local-([0-9]+)$ ]]; then
    LOCAL_NUM=$((${BASH_REMATCH[1]} + 1))
else
    LOCAL_NUM=1
fi

PACKAGE_VERSION="${BUILD_VERSION}-${DEBIAN_REVISION}+local-${LOCAL_NUM}"

echo "==> Creating changelog entry for version: $PACKAGE_VERSION"

DEBFULLNAME="VDR Builder" DEBEMAIL="builder@localhost" \
    dch --newversion "$PACKAGE_VERSION" --distribution "$DISTRO" \
    "$CHANGELOG_MSG"

# Clean up build artifacts
make clean 2>/dev/null || true
rm -f *.o *.so .dependencies

[ -d "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"

# Copy source including updated debian/ directory from source tree
rsync -a \
    --exclude='.git' \
    --exclude='*.o' \
    --exclude='*.so' \
    --exclude='.dependencies' \
    --exclude='/*.patch' \
    --exclude='.claude' \
    --exclude='CLAUDE.md' \
    --exclude='build-package.sh' \
    "$SOURCE_DIR/" "$BUILD_DIR/"

cd "$BUILD_DIR"

echo "==> Package version: $PACKAGE_VERSION"
echo "==> Building packages..."
dpkg-buildpackage -b -uc -us -j$(nproc) 2>&1 | grep -v "warning:"

echo ""
echo "==> Build complete. Checking generated packages:"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

for PKG in "${PACKAGES[@]}"; do
    DEB_FILE="${BUILD_BASE_DIR}/${PKG}_${PACKAGE_VERSION}_amd64.deb"

    if [ -f "$DEB_FILE" ]; then
        SIZE=$(ls -lh "$DEB_FILE" | awk '{print $5}')
        echo "  [OK] $PKG ($SIZE)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  [FAIL] $PKG - not found"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo ""
echo "==> Summary: $SUCCESS_COUNT packages built successfully, $FAIL_COUNT failed"

if [ $FAIL_COUNT -eq 0 ]; then
    echo ""
    echo "==> All packages in: $BUILD_BASE_DIR/"
    ls -lh "${BUILD_BASE_DIR}"/*_${PACKAGE_VERSION}_*.deb 2>/dev/null
else
    echo ""
    echo "==> ERROR: Some packages failed to build"
    exit 1
fi
