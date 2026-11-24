#!/usr/bin/env bash
# Installer idempotency test inside distro containers (podman):
#   warm-up install + uninstall (dependency packages stay, by design) → S0 snapshot
#   → install → S1 → install again → S2 (must == S1, no package-manager run)
#   → alias checks → uninstall → S3 (must == S0) → uninstall again → S4 (must == S0)
# Usage: tests/container-test.sh [mint|debian|arch|suse|fedora ...]   (default: mint arch suse fedora)
set -u
SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
declare -A IMG=(
    [mint]=docker.io/linuxmintd/mint22-amd64
    [debian]=docker.io/library/debian:trixie
    [arch]=docker.io/library/archlinux:latest
    [suse]=registry.opensuse.org/opensuse/tumbleweed:latest
    [fedora]=registry.fedoraproject.org/fedora:45
)
declare -A PRE=(
    [mint]="apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh fish >/dev/null"
    [debian]="apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh fish >/dev/null"
    [arch]="pacman -Syu --noconfirm --needed zsh fish >/dev/null"
    [suse]="zypper -n -q install zsh fish >/dev/null"
    [fedora]="dnf -y -q install zsh fish >/dev/null"
)
read -r -d '' INNER <<'EOS'
set -u
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
snap() {
    find /usr/local /etc/profile.d /etc/fish /etc/zsh /var/lib/dirtybit \
         /etc/bash.bashrc /etc/bash.bashrc.local /etc/bashrc /etc/zshrc \
         -xdev 2>/dev/null | sort | while IFS= read -r p; do
        if [ -L "$p" ]; then echo "L $p -> $(readlink "$p")"
        elif [ -f "$p" ]; then echo "F $(stat -c %a "$p") $(sha256sum <"$p" | cut -c1-16) $p"
        else echo "D $p"; fi
    done
}
fail=0
# minimal images lack diffutils: compare in bash, show differences with comm (coreutils)
check() {
    if [ "$(cat "$1")" = "$(cat "$2")" ]; then echo "PASS: $3"
    else echo "FAIL: $3 (- only before / + only after)"
         sort "$1" >/tmp/a; sort "$2" >/tmp/b
         comm -3 /tmp/a /tmp/b | sed 's/^\t/+ /; t; s/^/- /'; fail=1; fi
}

# warm-up: pull in the dependency packages (uninstall keeps them by design), then
# take the baseline, so S0..S4 measure only what install.sh itself owns
/src/install.sh --no-aur >/tmp/warm 2>&1 && /src/install.sh --uninstall >/dev/null 2>&1
grep -E 'Installing missing|not available' /tmp/warm | strip
snap >/tmp/S0
/src/install.sh --no-aur 2>&1 | strip >/tmp/i1;  echo "install #1 exit=${PIPESTATUS[0]}"
grep -E 'Installing missing|not available|hooked|✘' /tmp/i1
snap >/tmp/S1
/src/install.sh --no-aur 2>&1 | strip >/tmp/i2;  echo "install #2 exit=${PIPESTATUS[0]}"
snap >/tmp/S2
check /tmp/S1 /tmp/S2 "second install changed nothing"
if grep -q 'package manager not touched' /tmp/i2 && ! grep -qE '^  ✔ (hooked|updated|/)' /tmp/i2; then
    echo "PASS: second install wrote nothing and skipped the package manager"
else
    echo "FAIL: second install did work:"; grep -E 'Installing|✔' /tmp/i2; fail=1
fi
echo "--- alias"
bash -ic 'type dirtybit' 2>/dev/null | head -1
zsh  -ic 'whence -v dirtybit' 2>/dev/null | head -1
fish -c  'type -t dirtybit' 2>/dev/null | head -1
dirtybit --version
/src/install.sh --uninstall 2>&1 | strip >/tmp/u1; echo "uninstall #1 exit=${PIPESTATUS[0]}"
snap >/tmp/S3
check /tmp/S0 /tmp/S3 "uninstall restored the pre-install state byte-for-byte"
/src/install.sh --uninstall 2>&1 | strip >/tmp/u2; echo "uninstall #2 exit=${PIPESTATUS[0]}"
snap >/tmp/S4
check /tmp/S0 /tmp/S4 "second uninstall is a no-op"
bash -ic 'type dirtybit' >/dev/null 2>&1 && { echo "FAIL: alias still present"; fail=1; } || echo "PASS: alias gone"
exit $fail
EOS

targets=("$@"); ((${#targets[@]})) || targets=(mint arch suse fedora)
fail=0
for t in "${targets[@]}"; do
    echo "################ $t (${IMG[$t]})"
    podman run --rm -v "$SRC:/src:ro,Z" "${IMG[$t]}" bash -c "${PRE[$t]} || echo 'PRE step failed'; $INNER" ||
        { echo "!!! $t: FAILED"; fail=1; }
done
exit $fail
