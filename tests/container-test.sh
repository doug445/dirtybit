#!/usr/bin/env bash
# Run install.sh → alias check → --uninstall inside distro containers (podman).
# Usage: tests/container-test.sh [mint|arch|suse|fedora|debian ...]   (default: all)
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
targets=("$@"); ((${#targets[@]})) || targets=(mint arch suse fedora)
fail=0
for t in "${targets[@]}"; do
    echo "################ $t (${IMG[$t]})"
    podman run --rm -v "$SRC:/src:ro,Z" "${IMG[$t]}" bash -c "
        set -u
        ${PRE[$t]} || echo 'PRE step failed'
        /src/install.sh --no-aur 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
        echo '--- alias checks'
        bash -ic 'type dirtybit' 2>/dev/null | head -1
        zsh -ic 'whence -v dirtybit' 2>/dev/null | head -1
        fish -c 'type dirtybit' 2>/dev/null | head -1
        dirtybit --version && usb-dirtybit -l --no-color; echo \"list exit=\$? (3 = no USB, expected)\"
        echo '--- uninstall'
        /src/install.sh --uninstall | sed 's/\x1b\[[0-9;]*m//g'
        bash -ic 'type dirtybit' >/dev/null 2>&1 && echo 'ALIAS STILL PRESENT' || echo 'alias gone'
        ls /usr/local/bin
    " || { echo "!!! $t container failed"; fail=1; }
done
exit $fail
