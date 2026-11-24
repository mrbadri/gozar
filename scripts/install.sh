#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
app="$HOME/Applications/Gozar.app"
router_link="$HOME/.local/bin/vpn-router"
if [[ -d "$router_link" && ! -L "$router_link" ]]; then
    printf 'Cannot install vpn-router over a directory: %s\n' "$router_link" >&2
    exit 1
fi

scripts/build-app.sh
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
stage="$(mktemp -d "$HOME/Applications/.gozar.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto build/Gozar.app "$stage/Gozar.app"

if [[ -e "$app" || -L "$app" ]]; then
    mv "$app" "$stage/previous.app"
fi
if ! mv "$stage/Gozar.app" "$app"; then
    if [[ -e "$stage/previous.app" || -L "$stage/previous.app" ]]; then
        mv "$stage/previous.app" "$app"
    fi
    exit 1
fi
ln -sfn "$app/Contents/MacOS/vpn-router" "$router_link"

printf 'نصب شد: %s\n' "$app"
printf 'مسیریاب: %s\n' "$router_link"
printf '%s\n' 'گذر رو از Applications باز کن و مراحل «راه‌اندازی» رو دنبال کن. نصب دستور vpn برای ترمینال اختیاریه.'
