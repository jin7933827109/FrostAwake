#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app_path="build/FrostAwake.app"
mkdir -p build/module-cache
INPUT_HASH=$(shasum -a 256 Sources/*.swift Info.plist build.sh Resources/AppIcon.icns | shasum -a 256 | cut -d ' ' -f 1)
SIGNING_ID=${HINGEFROST_SIGN_ID:-}
if [ -z "$SIGNING_ID" ] && [ -f .local-signing-identity ]; then
    SIGNING_ID=$(cat .local-signing-identity)
    if [ -z "$SIGNING_ID" ]; then
        echo "The local signing identity file is empty." >&2
        exit 1
    fi
fi
SIGNING_ID=${SIGNING_ID:--}
BUILD_KEY="$INPUT_HASH:$SIGNING_ID"
if [ -f build/build-key ] && [ "$(cat build/build-key)" = "$BUILD_KEY" ] && codesign --verify --deep --strict "$app_path" 2>/dev/null; then
    echo "Inputs unchanged; keeping existing signed app and permission identity."
    exit 0
fi
staging_dir=$(mktemp -d build/.frostawake-build.XXXXXXXX)
staged_app="$staging_dir/FrostAwake.app"
previous_app="$staging_dir/previous.app"
cleanup_staging() {
    if [ -e "$previous_app" ] && [ ! -e "$app_path" ]; then
        if ! mv "$previous_app" "$app_path"; then
            printf 'Previous app preserved at %s\n' "$previous_app" >&2
            return
        fi
    fi
    rm -rf "$staging_dir"
}
trap cleanup_staging EXIT
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
xcrun swiftc -target arm64-apple-macos14.0 -swift-version 5 -O -module-cache-path build/module-cache Sources/*.swift -o "$staged_app/Contents/MacOS/HingeFrost" -framework AppKit -framework IOKit -framework Carbon -framework ServiceManagement
cp Info.plist "$staged_app/Contents/Info.plist"
cp Resources/AppIcon.icns "$staged_app/Contents/Resources/"
codesign --force --sign "$SIGNING_ID" --identifier local.hingefrost.prototype "$staged_app"
codesign --verify --deep --strict "$staged_app"
if [ -e "$app_path" ]; then mv "$app_path" "$previous_app"; fi
mv "$staged_app" "$app_path"
printf '%s' "$BUILD_KEY" > build/build-key
if [ "$SIGNING_ID" = "-" ]; then
    echo "Native material build: no screen capture permission required."
fi
echo "Built: $(pwd)/$app_path"
