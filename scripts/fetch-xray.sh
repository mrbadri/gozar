#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
lock=Resources/xray.lock
version=$(awk '$1 == "version" {print $2}' "$lock")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid Xray release in %s\n' "$lock" >&2; exit 1; }
release="https://github.com/XTLS/Xray-core/releases/download/v$version"
cache="$PWD/.build/xray"
archives="$cache/v$version"
arm=Xray-macos-arm64-v8a.zip
intel=Xray-macos-64.zip
mkdir -p "$archives"
stage=$(mktemp -d "$cache/.fetch.XXXXXX")
trap 'rm -rf "$stage"' EXIT

sha256() { LC_ALL=C /usr/bin/shasum -a 256 "$@" | awk '{print $1}'; }
die() { printf 'Xray: %s\n' "$*" >&2; exit 1; }

for zip in "$arm" "$intel"; do
    pinned=$(awk -v asset="$zip" '$1 == asset {print $2}' "$lock")
    [[ "$pinned" =~ ^[0-9a-f]{64}$ ]] || die "missing SHA-256 in $lock for $zip"
    asset="$archives/$zip"
    if [[ ! -e "$asset" ]]; then
        /usr/bin/curl -qfLsS --retry 3 "$release/$zip.dgst" -o "$stage/$zip.dgst"
        published=$(awk '$1 == "SHA2-256=" {print $2}' "$stage/$zip.dgst")
        [[ "$pinned" == "$published" ]] || die "published SHA-256 disagrees with $lock for $zip"
        /usr/bin/curl -qfLsS --retry 3 "$release/$zip" -o "$stage/$zip"
        [[ "$(sha256 "$stage/$zip")" == "$pinned" ]] || die "SHA-256 mismatch for $zip"
        mv "$stage/$zip" "$asset"
    fi
    [[ "$(sha256 "$asset")" == "$pinned" ]] || die "cached SHA-256 mismatch for $asset"
done

# Compare the cached payload against the pinned archives before using it again.
if [[ -e "$cache/xray" ]]; then
    case "$(/usr/bin/lipo -archs "$cache/xray")" in
        'x86_64 arm64'|'arm64 x86_64') ;;
        *) die "cached Xray is not an arm64 and x86_64 universal binary" ;;
    esac
fi
for file in geoip.dat geosite.dat LICENSE; do
    /usr/bin/unzip -p "$archives/$arm" "$file" >"$stage/$file"
    if [[ -e "$cache/$file" ]]; then
        cmp -s "$stage/$file" "$cache/$file" || die "cached payload mismatch for $cache/$file"
    fi
done
for arch in arm64 x86_64; do
    zip=$arm
    [[ "$arch" != x86_64 ]] || zip=$intel
    /usr/bin/unzip -p "$archives/$zip" xray >"$stage/$arch"
    if [[ -e "$cache/xray" ]]; then
        /usr/bin/lipo -thin "$arch" "$cache/xray" -output "$stage/cached-$arch"
        cmp -s "$stage/$arch" "$stage/cached-$arch" || die "cached Xray slice mismatch for $arch"
    fi
done
if [[ ! -e "$cache/xray" ]]; then
    /usr/bin/lipo -create "$stage/arm64" "$stage/x86_64" -output "$stage/xray"
    chmod 755 "$stage/xray"
    mv "$stage/xray" "$cache/xray"
fi
for file in geoip.dat geosite.dat LICENSE; do
    [[ -e "$cache/$file" ]] || mv "$stage/$file" "$cache/$file"
done
printf 'Verified Xray %s (arm64, x86_64)\n' "$version"
