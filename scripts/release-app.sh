#!/bin/sh
set -eu

version=${1:-}
if [ -z "$version" ]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi
version=${version#v}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/isnip-release-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

package_arch() {
  arch_tag=$1
  app_bundle="$stage/${arch_tag}/iSnip.app"
  ISNIP_ARCH="$arch_tag" ISNIP_OUT_APP="$app_bundle" ISNIP_VERSION="$version" sh "$root/scripts/build-app.sh" >/dev/null
  codesign --verify --deep --strict "$app_bundle"

  archive="$root/dist/isnip-macos-${arch_tag}-v${version}.zip"
  dmg="$root/dist/isnip-macos-${arch_tag}-v${version}.dmg"
  dmg_src="$stage/dmg-${arch_tag}"
  mkdir -p "$root/dist" "$dmg_src"

  rm -f "$archive" "$archive.sha256" "$dmg" "$dmg.sha256"
  ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive"
  ditto "$app_bundle" "$dmg_src/iSnip.app"
  ln -s /Applications "$dmg_src/Applications"
  hdiutil create -ov -volname "iSnip $version ($arch_tag)" -srcfolder "$dmg_src" -format UDZO "$dmg" >/dev/null
  (
    cd "$root/dist"
    shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256"
    shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256"
  )

  printf '%s\n' "$archive" "$dmg"
  cat "$archive.sha256"
  cat "$dmg.sha256"
}

package_arch arm64
package_arch amd64

host_uname=$(uname -m)
if [ "$host_uname" = "x86_64" ]; then
  host_tag=amd64
else
  host_tag=arm64
fi
rm -rf "$root/dist/iSnip.app"
ditto "$stage/${host_tag}/iSnip.app" "$root/dist/iSnip.app"
