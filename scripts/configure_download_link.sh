#!/bin/bash
# Fill the README's direct download link after this project has a GitHub origin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$ROOT/README.md"
REMOTE_URL="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"

if [ -z "$REMOTE_URL" ]; then
  echo "No Git remote named origin found. Create/connect the GitHub repository, then run this script again."
  exit 1
fi

case "$REMOTE_URL" in
  https://github.com/*) REPO_PATH="${REMOTE_URL#https://github.com/}" ;;
  http://github.com/*) REPO_PATH="${REMOTE_URL#http://github.com/}" ;;
  ssh://git@github.com/*) REPO_PATH="${REMOTE_URL#ssh://git@github.com/}" ;;
  git@github.com:*) REPO_PATH="${REMOTE_URL#git@github.com:}" ;;
  *) echo "The origin remote is not a GitHub URL: $REMOTE_URL"; exit 1 ;;
esac

REPO_PATH="${REPO_PATH%.git}"
if [[ "$REPO_PATH" != */* || "$REPO_PATH" == */*/* ]]; then
  echo "Could not read a GitHub owner/repository from origin: $REMOTE_URL"
  exit 1
fi

DOWNLOAD_URL="https://github.com/$REPO_PATH/releases/latest/download/AMG65-macOS.dmg"
python3 - "$README" "$DOWNLOAD_URL" <<'PY'
from pathlib import Path
import sys

readme = Path(sys.argv[1])
url = sys.argv[2]
text = readme.read_text()
start = "<!-- AMG65_DOWNLOAD_LINK_START -->"
end = "<!-- AMG65_DOWNLOAD_LINK_END -->"
if start not in text or end not in text:
    raise SystemExit("README download link markers were not found.")
before, rest = text.split(start, 1)
_, after = rest.split(end, 1)
badge = "https://img.shields.io/badge/Download-macOS%20DMG-007AFF?style=for-the-badge&logo=apple&logoColor=white"
link = f"\n[![Download AMG65 for macOS]({badge})](<{url}>)\n"
readme.write_text(before + start + link + end + after)
print(f"Updated README download link: {url}")
PY
