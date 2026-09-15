#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?Usage: generate-update-feed.sh VERSION RELEASE_DIRECTORY}"
release_dir="${2:?Missing release directory}"
release_dir="$(cd "$release_dir" && pwd)"
sparkle_tools="$repo_root/swift-prototype/.build/artifacts/sparkle/Sparkle/bin"
archive_path="$release_dir/StackHub-${version}-macos-arm64.zip"
test -f "$archive_path"

arguments=(
  --download-url-prefix "https://github.com/chenbstack/StackHub/releases/download/v${version}/"
  --maximum-deltas 0
  --link "https://github.com/chenbstack/StackHub/releases/tag/v${version}"
)
if [[ "$version" == *-* ]]; then
  arguments+=(--channel beta)
fi
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  # Pass secrets on stdin, never via process arguments or a checked-in file.
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_tools/generate_appcast" --ed-key-file - "${arguments[@]}" "$release_dir"
else
  "$sparkle_tools/generate_appcast" --account com.stackhub.prototype.updates "${arguments[@]}" "$release_dir"
fi
test -s "$release_dir/appcast.xml"
echo "Generated signed update feed: $release_dir/appcast.xml"
