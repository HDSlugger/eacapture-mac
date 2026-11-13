#!/bin/bash
# Downloads Silicondust's official eacapture.php, verifies it, and applies the
# local patch (60-second retry, --preserve-dir). Result: src/eacapture.php
set -euo pipefail
cd "$(dirname "$0")"
URL="https://download.silicondust.com/EACapture/eacapture.php.txt"
UPSTREAM_SHA256="1b993ce49847d24a535724dba32f776e62e69cae69a980cbcc5e228a13068592"
mkdir -p src
curl -fsSL "$URL" -o src/eacapture.upstream.php
GOT="$(shasum -a 256 src/eacapture.upstream.php | awk '{print $1}')"
if [ "$GOT" != "$UPSTREAM_SHA256" ]; then
  echo "Upstream script differs from the version this patch was made for." >&2
  echo "  expected $UPSTREAM_SHA256" >&2
  echo "  got      $GOT" >&2
  echo "Review the new script, then update UPSTREAM_SHA256 and the patch." >&2
  exit 1
fi
cp src/eacapture.upstream.php src/eacapture.php
patch src/eacapture.php < patches/local-changes.patch
rm -f src/eacapture.upstream.php
echo "Ready: src/eacapture.php"
