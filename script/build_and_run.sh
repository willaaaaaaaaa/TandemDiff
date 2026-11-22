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

# Stage the bundle in the system temp folder, which launchers do not index,
# so the only app copy left on disk is the installed one.
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/tandemdiff-bundle.XXXXXX")"
asset_dir="$(mktemp -d "${TMPDIR:-/tmp}/tandemdiff-icon.XXXXXX")"
trap 'rm -rf "$stage_dir" "$asset_dir"' EXIT
bundle="$stage_dir/TandemDiff.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
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

dest=/Applications/TandemDiff.app

install_app() {
    if [[ ! -d "$bundle" ]]; then
        printf 'The staged bundle is missing: %s\n' "$bundle" >&2
        exit 1
    fi
    replaced="$stage_dir/replaced-TandemDiff.app"
    if [[ -d "$dest" ]] && ! mv "$dest" "$replaced"; then
        printf 'Cannot replace %s. Remove it manually and rerun.\n' "$dest" >&2
        exit 1
    fi
    if ! mv "$bundle" "$dest"; then
        if [[ -d "$replaced" ]]; then mv "$replaced" "$dest"; fi
        printf 'Cannot install to %s. The previous app was kept.\n' "$dest" >&2
        exit 1
    fi
    rm -rf -- "${PWD}/dist/TandemDiff.app"
    printf 'Installed %s\n' "$dest"
}

case "${1:-}" in
    --build-only)
        out="${PWD}/dist/TandemDiff.app"
        mkdir -p "${PWD}/dist"
        rm -rf -- "$out"
        mv "$bundle" "$out"
        printf '%s\n' "$out"
        ;;
    --debug)
        install_app
        lldb -- "$dest/Contents/MacOS/TandemDiff"
        ;;
    ""|--verify|--logs)
        install_app
        open "$dest"
        if [[ "${1:-}" == "--verify" ]]; then
            sleep 1
            pgrep -x TandemDiff >/dev/null
        elif [[ "${1:-}" == "--logs" ]]; then
            log stream --info --predicate 'process == "TandemDiff"'
        fi
        ;;
    *) printf 'Usage: %s [--universal] [--build-only|--verify|--debug|--logs]\n' "$0" >&2; exit 2 ;;
esac
