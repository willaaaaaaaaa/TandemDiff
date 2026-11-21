#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration=debug
architectures=()
if [[ "${1:-}" == "--universal" ]]; then
    configuration=release
    architectures=(--arch arm64 --arch x86_64)
    shift
fi
bin_dir="$(swift build -c "$configuration" ${architectures[@]+"${architectures[@]}"} --show-bin-path)"
swift build -c "$configuration" ${architectures[@]+"${architectures[@]}"}

bundle="$PWD/dist/TandemDiff.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
asset_dir="$(mktemp -d "${TMPDIR:-/tmp}/tandemdiff-icon.XXXXXX")"
trap 'rm -rf "$asset_dir"' EXIT
iconset="$asset_dir/TandemDiff.iconset"
icon_source="assets/TandemDiff.png"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/TandemDiff.icns"
install -m 0755 "$bin_dir/TandemDiff" "$bundle/Contents/MacOS/TandemDiff"
# Keep the original bundle identifier so macOS reuses existing preferences.
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleDisplayName</key><string>TandemDiff</string>
    <key>CFBundleExecutable</key><string>TandemDiff</string>
    <key>CFBundleIconFile</key><string>TandemDiff</string>
    <key>CFBundleIdentifier</key><string>org.margindiff.app</string>
    <key>CFBundleName</key><string>TandemDiff</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle"

case "${1:-}" in
    --build-only) printf '%s\n' "$bundle" ;;
    --debug) lldb -- "$bundle/Contents/MacOS/TandemDiff" ;;
    ""|--verify|--logs)
        open "$bundle"
        if [[ "${1:-}" == "--verify" ]]; then
            sleep 1
            pgrep -x TandemDiff >/dev/null
        elif [[ "${1:-}" == "--logs" ]]; then
            log stream --info --predicate 'process == "TandemDiff"'
        fi
        ;;
    *) printf 'Usage: %s [--universal] [--build-only|--verify|--debug|--logs]\n' "$0" >&2; exit 2 ;;
esac
