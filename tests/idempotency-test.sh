#!/usr/bin/env bash
# Program idempotency test (no root needed):
#   run 1 repairs the dirty test images,
#   run 2 must report nothing to fix AND leave every image byte-identical.
# Usage: tests/idempotency-test.sh [workdir]
set -u
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN=$HERE/../usb-dirtybit
W=${1:-$(mktemp -d)}
rm -rf -- "$W/imgs"; mkdir -p "$W"
"$HERE/make-test-images.sh" "$W/imgs" >/dev/null 2>&1
imgs=("$W"/imgs/*.img)
echo "images: ${#imgs[@]}"

"$BIN" --no-color -y "${imgs[@]}" >"$W/run1.log" 2>&1
echo "run 1 exit=$?"; sed -n '/^Summary/,$p' "$W/run1.log"

md5sum "${imgs[@]}" >"$W/before"
"$BIN" --no-color -y "${imgs[@]}" >"$W/run2.log" 2>&1
rc2=$?
md5sum "${imgs[@]}" >"$W/after"
echo "run 2 exit=$rc2"; sed -n '/^Summary/,$p' "$W/run2.log"

fail=0
if [ "$(cat "$W/before")" != "$(cat "$W/after")" ]; then
    echo "FAIL: run 2 modified images:"; comm -3 "$W/before" "$W/after"; fail=1
else
    echo "PASS: run 2 left all ${#imgs[@]} images byte-identical"
fi
if grep -qE '^  (FIXED|ERRORS) ' "$W/run2.log"; then
    echo "FAIL: run 2 reported FIXED/ERRORS"; fail=1
else
    echo "PASS: run 2 found nothing to fix"
fi
n=$(grep -c 'nothing written' "$W/run2.log")
echo "      ($n filesystems took the read-only-only path)"
exit $fail
