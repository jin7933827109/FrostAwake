#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(uname -m)" != arm64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" != 1 ]; then
    echo "FrostAwake requires an Apple silicon Mac." >&2
    exit 1
fi
os_version="$(sw_vers -productVersion)"
if [ "${os_version%%.*}" -lt 14 ]; then
    echo "FrostAwake requires macOS 14 or later." >&2
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Install Apple's Command Line Tools for Xcode (xcode-select --install), then run this installer again." >&2
    exit 1
fi

app_dir="${1:-$HOME/Applications}"
mkdir -p "$app_dir"
app_dir="$(cd "$app_dir" && pwd)"
target="$app_dir/FrostAwake.app"
lock_dir="$app_dir/.frostawake-install.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "Another FrostAwake installation is in progress in $app_dir." >&2
    exit 1
fi
staging=''
cleanup() {
    if [ -n "$staging" ]; then rm -rf "$staging"; fi
    rmdir "$lock_dir"
}
trap cleanup EXIT

if [ -e "$target" ] || [ -L "$target" ]; then
    echo "FrostAwake already exists at $target. Use that copy, or move it aside before installing a new build." >&2
    exit 1
fi

bash build.sh
staging="$(mktemp -d "$app_dir/.frostawake-install.XXXXXXXX")"
ditto build/FrostAwake.app "$staging/FrostAwake.app"
codesign --verify --deep --strict "$staging/FrostAwake.app"
mv "$staging/FrostAwake.app" "$target"
printf 'Installed: %s\n' "$target"
