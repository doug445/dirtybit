#!/usr/bin/env bash
# dirtybit installer — Linux Mint / Ubuntu / Debian, Fedora (incl. Fedora Asahi
# Remix), Asahi ALARM / Arch Linux, openSUSE (Tumbleweed / Leap / Slowroll).
#
#   sudo ./install.sh              install program + alias + every missing FS tool
#   sudo ./install.sh --no-deps    program + alias only
#   sudo ./install.sh --no-aur     (Arch) don't use paru/yay for AUR-only tools
#   sudo ./install.sh --uninstall  remove program + alias (packages are kept)
#   ./install.sh --check           just print the filesystem support table
#
# Free and open source software. See README.md.
set -u

PREFIX=/usr/local
NO_DEPS=0 UNINSTALL=0 CHECK_ONLY=0 USE_AUR=1
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export LC_ALL=C

for a in "$@"; do
    case $a in
        --no-deps)    NO_DEPS=1 ;;
        --no-aur)     USE_AUR=0 ;;
        --uninstall)  UNINSTALL=1 ;;
        --check)      CHECK_ONLY=1 ;;
        --prefix=*)   PREFIX=${a#*=} ;;
        -h|--help)    sed -n '2,12p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "unknown option: $a (see --help)" >&2; exit 2 ;;
    esac
done

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' B=$'\e[1m' D=$'\e[2m' N=$'\e[0m'
else G='' Y='' R='' B='' D='' N=''; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '  %s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { type -P "$1" >/dev/null 2>&1; }

BIN=$PREFIX/bin/usb-dirtybit
LINK=$PREFIX/bin/dirtybit
DOC=$PREFIX/share/doc/dirtybit
PROFILE=/etc/profile.d/dirtybit.sh
FISH=/etc/fish/conf.d/dirtybit.fish
MARK_BEGIN='# >>> dirtybit alias >>>'
MARK_END='# <<< dirtybit alias <<<'

# ── filesystem support table ───────────────────────────────────────────────
kernel_has() { # fs-module… → 0 if the running kernel can mount any of them
    local m
    for m in "$@"; do
        grep -qw -- "$m" /proc/filesystems 2>/dev/null && return 0
        modinfo -n "$m" >/dev/null 2>&1 && return 0
    done
    return 1
}
support_table() {
    local row fs tools mods t tool_ok k
    printf '\n  %s%-10s %-26s %-8s%s\n' "$B" "FS" "checker" "kernel" "$N"
    for row in \
        "vfat|fsck.fat|vfat" "exfat|fsck.exfat|exfat" "ntfs|ntfsfix|ntfs3 ntfs fuse" \
        "ext2/3/4|e2fsck|ext4" "btrfs|btrfs|btrfs" "xfs|xfs_repair|xfs" "f2fs|fsck.f2fs|f2fs" \
        "hfs/hfs+|fsck.hfsplus fsck.hfs|hfsplus" "jfs|fsck.jfs|jfs" "bcachefs|bcachefs|bcachefs" \
        "apfs|fsck.apfs apfsck|apfs" "erofs|fsck.erofs|erofs" "reiserfs|reiserfsck|reiserfs" \
        "udf|udfinfo|udf" "nilfs2|(none needed)|nilfs2" "LUKS/BitLk|cryptsetup|dm_crypt"; do
        IFS='|' read -r fs tools mods <<<"$row"
        tool_ok=""
        for t in $tools; do have "$t" && { tool_ok=$t; break; }; done
        [[ $tools == "(none needed)" ]] && tool_ok="(none needed)"
        # shellcheck disable=SC2086
        if kernel_has $mods; then k="${G}yes${N}"; else k="${D}no${N}"; fi
        if [[ -n $tool_ok ]]; then
            printf '  %-10s %s%-26s%s %s\n' "$fs" "$G" "$tool_ok" "$N" "$k"
        else
            printf '  %-10s %s%-26s%s %s\n' "$fs" "$R" "missing" "$N" "$k"
        fi
    done
    printf '  %s"kernel" = can this kernel mount it (only needed for log replay + remount;\n   fsck itself is pure userspace). page size: %s%s\n' "$D" "$(getconf PAGESIZE)" "$N"
}

if ((CHECK_ONLY)); then support_table; exit 0; fi

# ── root ───────────────────────────────────────────────────────────────────
if ((EUID != 0)); then
    for e in sudo doas run0; do
        have "$e" && exec "$e" "$(readlink -f -- "${BASH_SOURCE[0]}")" "$@"
    done
    die "run as root"
fi

# ── distro ─────────────────────────────────────────────────────────────────
ID="" ID_LIKE="" NAME="" PRETTY_NAME=""
# shellcheck disable=SC1091
[[ -r /etc/os-release ]] && . /etc/os-release
FAMILY=unknown
for t in $ID $ID_LIKE; do
    case $t in
        debian|ubuntu|linuxmint|pop|elementary|zorin|neon) FAMILY=debian; break ;;
        fedora|fedora-asahi-remix|rhel|centos|rocky|almalinux|nobara|ultramarine) FAMILY=fedora; break ;;
        arch|archarm|archlinuxarm|manjaro|endeavouros|cachyos|garuda) FAMILY=arch; break ;;
        suse|opensuse|opensuse-*|sles|sled) FAMILY=suse; break ;;
    esac
done
ASAHI=""
if [[ $ID == *asahi* || $NAME == *Asahi* || -e /proc/device-tree/compatible && $(tr -d '\0' </proc/device-tree/compatible 2>/dev/null) == *apple* ]]; then
    ASAHI=" (Apple Silicon / Asahi, $(getconf PAGESIZE)-byte pages)"
fi

# ── uninstall ──────────────────────────────────────────────────────────────
strip_block() { [[ -f $1 ]] && grep -qF "$MARK_BEGIN" "$1" && sed -i "/^$MARK_BEGIN\$/,/^$MARK_END\$/d" "$1" && ok "removed alias hook from $1"; }
if ((UNINSTALL)); then
    say "Uninstalling dirtybit"
    rm -f -- "$BIN" "$LINK" "$PROFILE" "$FISH" && ok "removed $BIN, $LINK, $PROFILE"
    rm -rf -- "$DOC"
    for f in /etc/bash.bashrc /etc/bash.bashrc.local /etc/bashrc /etc/zshrc /etc/zsh/zshrc; do strip_block "$f"; done
    ok "done (filesystem tool packages and /var/log/dirtybit.log were left in place)"
    exit 0
fi

say "dirtybit installer — ${PRETTY_NAME:-unknown distro}$ASAHI · family: $FAMILY · $(uname -m)"
[[ -f $HERE/usb-dirtybit ]] || die "usb-dirtybit not found next to install.sh"

# ── packages: every filesystem checker + helpers ───────────────────────────
COMMON=(util-linux dosfstools exfatprogs e2fsprogs xfsprogs f2fs-tools jfsutils
        erofs-utils udftools cryptsetup psmisc udisks2)
AUR=()
case $FAMILY in
    debian) PKGS=("${COMMON[@]}" ntfs-3g btrfs-progs hfsprogs bcachefs-tools nilfs-tools reiserfsprogs apfsprogs) ;;
    fedora) PKGS=("${COMMON[@]}" ntfs-3g ntfsprogs btrfs-progs hfsplus-tools bcachefs-tools nilfs-utils reiserfs-utils) ;;
    arch)   PKGS=("${COMMON[@]}" ntfs-3g ntfsprogs btrfs-progs bcachefs-tools nilfs-utils reiserfsprogs)
            AUR=(hfsprogs apfsprogs-git reiserfsprogs) ;;
    suse)   PKGS=("${COMMON[@]}" ntfs-3g ntfsprogs btrfsprogs bcachefs-tools nilfs-utils hfsplus-tools reiserfs apfsprogs) ;;
    *)      PKGS=() ;;
esac

is_installed() {
    case $FAMILY in
        debian) [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == *"ok installed"* ]] ;;
        fedora|suse) rpm -q --whatprovides "$1" >/dev/null 2>&1 ;;
        arch)   pacman -Qq "$1" >/dev/null 2>&1 ;;
    esac
}
is_available() {
    local c
    case $FAMILY in
        debian) c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}'); [[ -n $c && $c != "(none)" ]] ;;
        fedora) return 0 ;;  # dnf skips unavailable names itself
        suse)   zypper --non-interactive --quiet search --match-exact --type package "$1" >/dev/null 2>&1 ;;
        arch)   pacman -Si "$1" >/dev/null 2>&1 ;;
    esac
}

install_deps() {
    local p missing=() avail=() unavail=() rc=0
    if [[ $FAMILY == unknown ]]; then
        warn "unrecognised distro — install the filesystem tools yourself (see README); continuing"
        return 0
    fi
    if [[ -e /run/ostree-booted ]]; then
        warn "image-based (ostree) system detected — layer the tools with:"
        warn "  rpm-ostree install --idempotent ${PKGS[*]}   (then reboot)"
        return 0
    fi
    if have transactional-update && [[ $(findmnt -no OPTIONS / 2>/dev/null) == ro,* ]]; then
        warn "transactional (read-only root) openSUSE detected — install the tools with:"
        warn "  transactional-update pkg install ${PKGS[*]}   (then reboot)"
        return 0
    fi

    say "Checking filesystem tool packages"
    [[ $FAMILY == debian ]] && { apt-get update -qq || warn "apt-get update failed — using cached package lists"; }
    for p in "${PKGS[@]}"; do
        if is_installed "$p"; then printf '  %s✔ %s%s\n' "$D" "$p" "$N"
        else missing+=("$p"); fi
    done
    if ((${#missing[@]} == 0)); then ok "all filesystem tools already present"; return 0; fi

    for p in "${missing[@]}"; do
        if is_available "$p"; then avail+=("$p"); else unavail+=("$p"); fi
    done
    if ((${#avail[@]})); then
        say "Installing missing: ${avail[*]}"
        case $FAMILY in
            debian) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${avail[@]}" || rc=$? ;;
            fedora)
                if dnf --version 2>/dev/null | grep -q '^dnf5'; then
                    dnf install -y --skip-unavailable --setopt=install_weak_deps=False "${avail[@]}" || rc=$?
                else
                    dnf install -y --setopt=strict=0 --setopt=install_weak_deps=False "${avail[@]}" || rc=$?
                fi ;;
            arch)   pacman -S --needed --noconfirm "${avail[@]}" || {
                        rc=$?; warn "pacman failed — if it was a 404, run 'pacman -Syu' first and re-run"; } ;;
            suse)   zypper --non-interactive install --no-recommends "${avail[@]}" || rc=$? ;;
        esac
        ((rc)) && warn "package manager exited $rc — some tools may be missing (see table below)"
        for p in "${avail[@]}"; do is_installed "$p" || unavail+=("$p"); done
    fi
    # Arch: AUR-only tools through the invoking user's AUR helper
    if [[ $FAMILY == arch ]] && ((USE_AUR)); then
        local helper="" user=${SUDO_USER:-${DOAS_USER:-}} want=()
        for p in "${AUR[@]}"; do
            [[ $p == reiserfsprogs ]] && is_installed reiserfsprogs && continue
            is_installed "$p" || is_installed "${p%-git}" || want+=("$p")
        done
        if ((${#want[@]})); then
            helper=$(type -P paru || type -P yay || true)
            if [[ -n $helper && -n $user && $user != root ]]; then
                say "Installing AUR packages as $user via $(basename "$helper"): ${want[*]}"
                runuser -u "$user" -- "$helper" -S --needed --noconfirm "${want[@]}" ||
                    warn "AUR install failed for some of: ${want[*]}"
            else
                warn "AUR-only (install with an AUR helper): ${want[*]}"
            fi
        fi
    fi
    for p in "${unavail[@]+"${unavail[@]}"}"; do warn "not available for this release: $p (optional)"; done
    if [[ $FAMILY == fedora ]] && ! have fsck.apfs; then
        warn "APFS checker (apfsprogs) isn't in Fedora — build it from https://github.com/linux-apfs/apfsprogs if you need APFS"
    fi
    return 0
}

((NO_DEPS)) || install_deps

# ── program + alias ────────────────────────────────────────────────────────
say "Installing program"
install -D -m 0755 "$HERE/usb-dirtybit" "$BIN" && ok "$BIN"
ln -sfn usb-dirtybit "$LINK" && ok "$LINK → usb-dirtybit (works from sudo, scripts, any shell)"
install -D -m 0644 "$HERE/README.md" "$DOC/README.md" 2>/dev/null && ok "$DOC/README.md"

say "Installing the 'dirtybit' alias"
cat >"$PROFILE" <<EOF
# dirtybit — fsck removable USB drives + clear dirty bits (installed by dirtybit/install.sh)
alias dirtybit='$BIN'
EOF
chmod 0644 "$PROFILE" && ok "$PROFILE"

add_hook() { # rc-file — source the profile.d alias from interactive non-login shells
    local f=$1
    [[ -f $f ]] || return 0
    grep -qF "$MARK_BEGIN" "$f" && { ok "$f already hooked"; return 0; }
    printf '\n%s\n[ -r %s ] && . %s\n%s\n' "$MARK_BEGIN" "$PROFILE" "$PROFILE" "$MARK_END" >>"$f"
    ok "hooked $f"
}
# bash: Fedora's /etc/bashrc already sources profile.d for interactive shells
case $FAMILY in
    suse) touch /etc/bash.bashrc.local; add_hook /etc/bash.bashrc.local ;;
    fedora) grep -q 'profile.d' /etc/bashrc 2>/dev/null || add_hook /etc/bashrc ;;
    *) add_hook /etc/bash.bashrc ;;
esac
# zsh (system-wide rc for interactive shells). Arch's zsh ships no /etc/zsh/zshrc
# but reads it, so create one there when zsh is installed.
if have zsh && [[ $FAMILY == arch && ! -e /etc/zsh/zshrc && ! -e /etc/zshrc ]]; then
    mkdir -p /etc/zsh && touch /etc/zsh/zshrc
fi
add_hook /etc/zshrc
add_hook /etc/zsh/zshrc
# fish
if [[ -d /etc/fish ]]; then
    mkdir -p /etc/fish/conf.d
    printf "# dirtybit (installed by dirtybit/install.sh)\nalias dirtybit '%s'\n" "$BIN" >"$FISH" && ok "$FISH"
fi

say "Verifying"
"$BIN" --version >/dev/null && ok "$("$BIN" --version) installed"
support_table
for m in apfs bcachefs; do
    if ! kernel_has "$m"; then
        case $m in
            apfs)     printf '  %sAPFS kernel driver (optional, for mounting): out-of-tree linux-apfs-rw (DKMS)%s\n' "$D" "$N" ;;
            bcachefs) printf '  %sbcachefs kernel driver (optional): out of mainline since 6.18 — bcachefs-dkms%s\n' "$D" "$N" ;;
        esac
    fi
done
echo
ok "open a new terminal (or run: . $PROFILE) and type: ${B}dirtybit${N}   (dirtybit --help for options)"
