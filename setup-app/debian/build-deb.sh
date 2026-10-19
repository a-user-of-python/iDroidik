#!/bin/bash
# Builds the .deb from a compiled .app.
# Usage: ./build-deb.sh /path/to/iDroidikSetup.app
set -e
cd "$(dirname "$0")"
APP_SRC="${1:?usage: build-deb.sh /path/to/iDroidikSetup.app}"

PKGDIR="$(mktemp -d)"
trap "rm -rf $PKGDIR" EXIT

mkdir -p "$PKGDIR/DEBIAN" "$PKGDIR/Applications"
cp DEBIAN/control DEBIAN/postinst "$PKGDIR/DEBIAN/"
chmod 755 "$PKGDIR/DEBIAN/postinst"
cp -R "$APP_SRC" "$PKGDIR/Applications/"

# dpkg-deb if available, else fall back to manual ar/tar
if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -b "$PKGDIR" "com.idroidik.setup_1.0_iphoneos-arm.deb"
else
    echo "dpkg-deb not found — install dpkg to build the .deb" >&2
    exit 1
fi
echo "Built: com.idroidik.setup_1.0_iphoneos-arm.deb"
ls -lh com.idroidik.setup_1.0_iphoneos-arm.deb
