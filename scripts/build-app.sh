#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

version=${ISNIP_VERSION:-${AIRSNIP_VERSION:-}}
host_uname=$(uname -m)
if [ "$host_uname" = "x86_64" ]; then
  default_arch=amd64
else
  default_arch=arm64
fi
req_arch=${ISNIP_ARCH:-$default_arch}

case "$req_arch" in
  arm64|aarch64)
    target_arch=arm64
    swift_arch=arm64
    helpers_dir="$root/Vendor/Helpers"
    frameworks_dir="$root/Vendor/Frameworks"
    ;;
  amd64|x86_64)
    target_arch=amd64
    swift_arch=x86_64
    helpers_dir="$root/Vendor/amd64/Helpers"
    frameworks_dir="$root/Vendor/amd64/Frameworks"
    ;;
  *)
    echo "Unsupported ISNIP_ARCH: ${req_arch} (expected arm64 or amd64)" >&2
    exit 2
    ;;
esac

swift build -c release --arch "$swift_arch" >&2
bin_dir=$(swift build -c release --arch "$swift_arch" --show-bin-path)

app=${ISNIP_OUT_APP:-"$root/dist/iSnip.app"}
rm -rf "$app" "$root/dist/AirSnip.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers" "$app/Contents/Frameworks"

cp "$bin_dir/iSnip" "$app/Contents/MacOS/iSnip"
cp "$root/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
if [ -f "$root/Assets/dingding-mp-qr.jpg" ]; then
  cp "$root/Assets/dingding-mp-qr.jpg" "$app/Contents/Resources/dingding-mp-qr.jpg"
fi
cp "$root/Info.plist" "$app/Contents/Info.plist"

if [ -d "$helpers_dir" ]; then
  for helper in "$helpers_dir"/*; do
    [ -f "$helper" ] || continue
    cp "$helper" "$app/Contents/Helpers/$(basename "$helper")"
    chmod 755 "$app/Contents/Helpers/$(basename "$helper")"
  done
fi

if [ -d "$frameworks_dir" ]; then
  for dylib in "$frameworks_dir"/*.dylib; do
    [ -f "$dylib" ] || continue
    cp "$dylib" "$app/Contents/Frameworks/$(basename "$dylib")"
    chmod 755 "$app/Contents/Frameworks/$(basename "$dylib")"
  done
fi

if [ -n "$version" ]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
fi

find "$app" -name .DS_Store -delete
find "$app" -name '._*' -delete
xattr -cr "$app"

sign_identity=${ISNIP_SIGN_IDENTITY:-${AIRSNIP_SIGN_IDENTITY:-}}
if [ -z "$sign_identity" ]; then
  sign_identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Developer ID Application: /{print $2; exit}')
fi
if [ -z "$sign_identity" ]; then
  sign_identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development: /{id=$2} END{if (id) print id}')
fi
if [ -z "$sign_identity" ]; then
  sign_identity=-
fi

echo "Signing iSnip.app [${target_arch}] (inside-out) with identity: ${sign_identity}" >&2
for dylib in "$app/Contents/Frameworks"/*.dylib; do
  [ -f "$dylib" ] || continue
  codesign --force --sign "$sign_identity" "$dylib"
done
for helper in "$app/Contents/Helpers"/*; do
  [ -f "$helper" ] || continue
  codesign --force --sign "$sign_identity" "$helper"
done
codesign --force --sign "$sign_identity" "$app"
printf '%s\n' "$app"
