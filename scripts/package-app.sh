#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?Usage: package-app.sh VERSION [OUTPUT_DIRECTORY]}"
output_dir="${2:-$repo_root/swift-prototype/dist}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid application version: $version" >&2
  exit 1
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

cd "$repo_root/swift-prototype"
swift build -c release --disable-sandbox
binary_dir="$(swift build -c release --show-bin-path)"
sparkle_framework="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$sparkle_framework"

# Assemble separately so a failed build/sign does not damage a previous app.
staging="$(mktemp -d "$output_dir/.stackhub-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app_path="$staging/StackHub.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Frameworks"
cp "$binary_dir/StackHub" "$app_path/Contents/MacOS/StackHub"
cp Packaging/Info.plist "$app_path/Contents/Info.plist"
ditto Sources/Localization "$app_path/Contents/Resources"
cp Packaging/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
# ditto preserves the framework's versioned symlinks and helper permissions.
ditto "$sparkle_framework" "$app_path/Contents/Frameworks/Sparkle.framework"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app_path/Contents/Info.plist"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"

if [[ -e "$output_dir/StackHub.app" ]]; then
  echo "Output already contains StackHub.app; choose an empty output directory." >&2
  exit 1
fi
mv "$app_path" "$output_dir/StackHub.app"
echo "Packaged: $output_dir/StackHub.app"
