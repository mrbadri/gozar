#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/fetch-xray.sh
swift build -c release
bin="$(swift build -c release --show-bin-path)"
case "$(uname -m)" in
    arm64) other_arch=x86_64 ;;
    x86_64) other_arch=arm64 ;;
    *) printf 'Unsupported build architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
other_build=(--arch "$other_arch" --scratch-path "$PWD/.build/$other_arch-app" -c release)
swift build "${other_build[@]}"
other_bin="$(swift build "${other_build[@]}" --show-bin-path)"

mkdir -p build
stage="$(mktemp -d "$PWD/build/.gozar.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$PWD/build/Gozar.app"
bundle="$stage/Gozar.app/Contents"
iconset="$stage/AppIcon.iconset"
resources="$bundle/Resources"
cli="$resources/cli"
mkdir -p "$bundle/MacOS" "$cli/laptop-vpn.d" "$cli/docs" "$resources/xray" "$resources/fonts" "$iconset"

for product in Gozar vpn-router gozarctl; do
    /usr/bin/lipo -create "$bin/$product" "$other_bin/$product" -output "$bundle/MacOS/$product"
    chmod 755 "$bundle/MacOS/$product"
done
/usr/bin/install -m 755 Resources/gozar-askpass "$resources"
/usr/bin/install -m 644 Resources/Info.plist "$bundle/Info.plist"
/usr/bin/install -m 755 cli/laptop-vpn.sh "$cli"
/usr/bin/install -m 644 cli/laptop-vpn.d/{*.json,_vpn} "$cli/laptop-vpn.d"
/usr/bin/install -m 644 docs/LAPTOP-VPN.md "$cli/docs"
doc_renderer="$PWD/cli/laptop-vpn.d/docs.py"
(cd "$cli/docs" && /usr/bin/python3 -I - "$doc_renderer" <<'PY'
import runpy
import sys
from pathlib import Path

build = runpy.run_path(sys.argv[1])["build"]
build.__globals__["font_face"] = lambda: """
@font-face { font-family: "Vazirmatn Local"; font-weight: 400; src: url("../../fonts/Vazirmatn-Regular.ttf"); }
@font-face { font-family: "Vazirmatn Local"; font-weight: 700; src: url("../../fonts/Vazirmatn-Bold.ttf"); }
"""
build(Path("LAPTOP-VPN.md"), Path("LAPTOP-VPN.html"))
PY
)
/usr/bin/install -m 755 .build/xray/xray "$resources/xray"
/usr/bin/install -m 644 .build/xray/{geoip.dat,geosite.dat,LICENSE} "$resources/xray"
/usr/bin/install -m 644 Resources/fonts/{Vazirmatn-*.ttf,OFL.txt} "$resources/fonts"

for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        suffix=""
        [[ "$scale" == 1 ]] || suffix="@2x"
        /usr/bin/sips -z "$pixels" "$pixels" Resources/icon-1024.png \
            --out "$iconset/icon_${size}x${size}${suffix}.png" >/dev/null
    done
done
/usr/bin/iconutil --convert icns --output "$resources/AppIcon.icns" "$iconset"
/usr/bin/codesign --force -s - "$resources/xray/xray"
/usr/bin/codesign --force --deep -s - "$stage/Gozar.app"
/usr/bin/codesign --verify --deep --strict "$stage/Gozar.app"

if [[ -e "$app" || -L "$app" ]]; then
    mv "$app" "$stage/previous.app"
fi
if ! mv "$stage/Gozar.app" "$app"; then
    if [[ -e "$stage/previous.app" || -L "$stage/previous.app" ]]; then
        mv "$stage/previous.app" "$app"
    fi
    exit 1
fi
printf 'Built %s (%s)\n' "$app" "$(du -sh "$app" | cut -f1)"
