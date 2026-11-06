#!/usr/bin/env bash
# Download a release's build artifacts. Defaults to the latest tag.
#   ./tools/fetch-release.sh                    # latest -> ./dist/<tag>/
#   ./tools/fetch-release.sh v0.9.3-cc.4 ~/dl
set -euo pipefail

TAG="${1:-latest}"
REPO="YallonGao/FClashCC"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-$ROOT/dist}"

if [ "$TAG" = "latest" ]; then
  API="https://api.github.com/repos/$REPO/releases/latest"
else
  API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
fi

AUTH=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

TAG_NAME="$(curl -fsSL "${AUTH[@]}" "$API" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
TARGET="$OUT/$TAG_NAME"
mkdir -p "$TARGET"

curl -fsSL "${AUTH[@]}" "$API" |
  python3 -c 'import json,sys
for a in json.load(sys.stdin)["assets"]:
    print(a["browser_download_url"], a["name"], a["size"])' |
  while read -r url name size; do
    if [ -f "$TARGET/$name" ]; then
      echo "skip  $name"
      continue
    fi
    echo "get   $name  $((size / 1048576)) MB"
    curl -fL --retry 3 "${AUTH[@]}" -o "$TARGET/$name" "$url"
  done

if [ -f "$TARGET/SHA256SUMS" ]; then
  (cd "$TARGET" && sha256sum -c SHA256SUMS --ignore-missing --quiet && echo "checksums ok")
fi

echo
echo "saved to $TARGET"
ls -lh "$TARGET"
