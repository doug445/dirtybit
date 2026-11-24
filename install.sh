#!/usr/bin/env bash
# dirtybit installer — Linux Mint / Ubuntu / Debian, Fedora (incl. Fedora Asahi
# Remix), Asahi ALARM / Arch Linux, openSUSE (Tumbleweed / Leap / Slowroll).
#
#   sudo ./install.sh              install program + alias + every missing FS tool
#   sudo ./install.sh --no-deps    program + alias only
#   sudo ./install.sh --no-aur     (Arch) don't use paru/yay for AUR-only tools
#   sudo ./install.sh --uninstall  remove program + alias (packages are kept)
#   sudo ./install.sh --retry-unavailable   re-query packages a previous run
#                                  found unavailable for this release
#   ./install.sh --check           just print the filesystem support table
#
# Idempotent: re-running changes nothing that is already in place (no package
# manager or network use when nothing is missing, unchanged files are not
# rewritten, shell hooks are replaced rather than duplicated). --uninstall
# removes exactly what was added and restores edited rc files byte-for-byte.
#
# Free and open source software. See README.md.
set -u

PREFIX=/usr/local
NO_DEPS=0 UNINSTALL=0 CHECK_ONLY=0 USE_AUR=1 RETRY_UNAVAIL=0
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export LC_ALL=C

for a in "$@"; do
    case $a in
        --no-deps)    NO_DEPS=1 ;;
        --no-aur)     USE_AUR=0 ;;
        --uninstall)  UNINSTALL=1 ;;
        --check)      CHECK_ONLY=1 ;;
        --retry-unavailable) RETRY_UNAVAIL=1 ;;
        --prefix=*)   PREFIX=${a#*=} ;;
        -h|--help)    sed -n '2,18p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "unknown option: $a (see --help)" >&2; exit 2 ;;
    esac
done

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' B=$'\e[1m' D=$'\e[2m' N=$'\e[0m'
else G='' Y='' R='' B='' D='' N=''; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
same() { printf '  %s= %s%s\n' "$D" "$*" "$N"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '  %s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { type -P "$1" >/dev/null 2>&1; }

BIN=$PREFIX/bin/usb-dirtybit
LINK=$PREFIX/bin/dirtybit
DOC=$PREFIX/share/doc/dirtybit
PROFILE=/etc/profile.d/dirtybit.sh
FISH=/etc/fish/conf.d/dirtybit.fish
STATE=/var/lib/dirtybit
MANIFEST=$STATE/install-manifest      # paths this installer created (files + dirs)
UNAVAIL_FILE=$STATE/unavailable-packages  # not in this release's repos: don't re-query every run
MARK_BEGIN='# >>> dirtybit alias >>>'
MARK_END='# <<< dirtybit alias <<<'
RC_FILES=(/etc/bash.bashrc /etc/bash.bashrc.local /etc/bashrc /etc/zshrc /etc/zsh/zshrc)

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
        "vfat|fsck.fat dosfsck|vfat" "exfat|fsck.exfat|exfat" "ntfs|ntfsfix|ntfs3 ntfs fuse" \
        "ext2/3/4|e2fsck|ext4" "btrfs|btrfs|btrfs" "xfs|xfs_repair|xfs" "f2fs|fsck.f2fs|f2fs" \
        "hfs/hfs+|fsck.hfsplus fsck.hfs|hfsplus" "jfs|fsck.jfs|jfs" "bcachefs|bcachefs|bcachefs" \
        "apfs|fsck.apfs apfsck|apfs" "erofs|fsck.erofs|erofs" "reiserfs|reiserfsck|reiserfs" \
        "udf|udfinfo|udf" "nilfs2|(none needed)|nilfs2"; do
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

# ── manifest: remember what we created so uninstall removes exactly that ────
declare -A CREATED=()
[[ -r $MANIFEST ]] && while IFS= read -r l; do [[ -n $l ]] && CREATED[$l]=1; done <"$MANIFEST"
note_new() { # path — call BEFORE creating it; records it only if it doesn't exist yet
    [[ -e $1 || -L $1 ]] || CREATED[$1]=1
}
note_new_dirs() { # file path → record every missing parent dir
    local d=$1
    while d=$(dirname -- "$d"); [[ $d != / && ! -e $d ]]; do CREATED[$d]=1; done
}
write_state() { # file content — rewrite only when the content changes
    mkdir -p "$STATE"
    if [[ -f $1 ]] && [[ $(<"$1") == "$2" ]]; then return 0; fi
    printf '%s\n' "$2" >"$1.tmp" && mv -f "$1.tmp" "$1"
}
save_manifest() { write_state "$MANIFEST" "$(printf '%s\n' "${!CREATED[@]}" | sed '/^$/d' | sort)"; }

put_file() { # src dest mode — install only if content or mode differ
    local src=$1 dst=$2 mode=$3
    # sha256sum (coreutils) rather than cmp: diffutils is absent from minimal installs
    if [[ -f $dst ]] && [[ $(sha256sum <"$src") == "$(sha256sum <"$dst")" ]] &&
        [[ $(stat -c %a -- "$dst") == "${mode#0}" ]]; then
        same "$dst (unchanged)"; return 0
    fi
    note_new_dirs "$dst"; note_new "$dst"
    install -D -m "$mode" -- "$src" "$dst" && ok "$dst"
}
put_text() { # dest mode text — write only if different
    local dst=$1 mode=$2 txt=$3 tmp
    tmp=$(mktemp) && printf '%s' "$txt" >"$tmp"
    put_file "$tmp" "$dst" "$mode"
    rm -f -- "$tmp"
}

# rc-file hook: a marked block appended after one blank line ------------------
hook_block() { printf '%s\n[ -r %s ] && . %s\n%s\n' "$MARK_BEGIN" "$PROFILE" "$PROFILE" "$MARK_END"; }
strip_block() { # file → print it without our block (and the blank line we added before it)
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { inblk = 1; held = 0; next }
        inblk   { if ($0 == e) inblk = 0; next }
        { if (held) { print ""; held = 0 }
          if ($0 == "") held = 1; else print }
        END { if (held) print "" }' "$1"
}
rewrite_in_place() { # file newcontent-file — keep inode, owner, mode, SELinux label
    cat -- "$2" >"$1"
}
add_hook() { # rc-file [create]
    local f=$1 create=${2:-} tmp cur want
    if [[ ! -f $f ]]; then
        [[ -n $create ]] || return 0
        note_new_dirs "$f"; note_new "$f"
        mkdir -p -- "$(dirname -- "$f")" && : >"$f"
    fi
    want=$(hook_block)
    if grep -qxF "$MARK_BEGIN" "$f"; then
        cur=$(sed -n "/^$MARK_BEGIN\$/,/^$MARK_END\$/p" "$f")
        if [[ $cur == "$want" ]]; then same "$f (hook already present)"; return 0; fi
        tmp=$(mktemp); strip_block "$f" >"$tmp"; rewrite_in_place "$f" "$tmp"; rm -f -- "$tmp"
        printf '\n%s\n' "$want" >>"$f" && ok "updated hook in $f"
        return 0
    fi
    if [[ -s $f ]]; then printf '\n%s\n' "$want" >>"$f"; else printf '%s\n' "$want" >>"$f"; fi
    ok "hooked $f"
}
remove_hook() {
    local f=$1 tmp
    [[ -f $f ]] && grep -qxF "$MARK_BEGIN" "$f" || return 0
    tmp=$(mktemp); strip_block "$f" >"$tmp"
    # a file that held nothing but our block: strip leaves it empty
    if [[ ! -s $tmp ]] || ! grep -q '[^[:space:]]' "$tmp"; then : >"$tmp"; fi
    rewrite_in_place "$f" "$tmp"; rm -f -- "$tmp"
    ok "removed alias hook from $f"
}

# ── uninstall ──────────────────────────────────────────────────────────────
if ((UNINSTALL)); then
    say "Uninstalling dirtybit"
    for f in "${RC_FILES[@]}"; do remove_hook "$f"; done
    for f in "$BIN" "$LINK" "$PROFILE" "$FISH" "$DOC/README.md"; do
        if [[ -e $f || -L $f ]]; then rm -f -- "$f" && ok "removed $f"; fi
    done
    # files we created from nothing (e.g. Arch /etc/zsh/zshrc) go only if still empty
    for p in "${!CREATED[@]}"; do
        [[ -f $p && ! -s $p ]] && rm -f -- "$p" && ok "removed $p (created by installer, empty)"
    done
    # directories we created, deepest first, only if empty
    while IFS= read -r p; do
        [[ -d $p ]] && rmdir -- "$p" 2>/dev/null && ok "removed empty dir $p"
    done < <(printf '%s\n' "${!CREATED[@]}" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)
    rm -rf -- "$STATE"
    ok "done — nothing left to remove on a re-run (filesystem packages and /var/log/dirtybit.log are kept)"
    exit 0
fi

say "dirtybit installer — ${PRETTY_NAME:-unknown distro}$ASAHI · family: $FAMILY · $(uname -m)"
[[ -f $HERE/usb-dirtybit ]] || die "usb-dirtybit not found next to install.sh"

# ── packages: every filesystem checker + helpers ───────────────────────────
COMMON=(util-linux dosfstools exfatprogs e2fsprogs xfsprogs f2fs-tools jfsutils
        erofs-utils udftools psmisc udisks2)
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
        *)      return 1 ;;
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
    local p missing=() avail=() unavail=() known=() rc=0
    declare -A KNOWN_UNAVAIL=()
    if ((!RETRY_UNAVAIL)) && [[ -r $UNAVAIL_FILE ]]; then
        while IFS= read -r p; do [[ -n $p ]] && KNOWN_UNAVAIL[$p]=1; done <"$UNAVAIL_FILE"
    fi
    if [[ $FAMILY == unknown ]]; then
        warn "unrecognised distro — install the filesystem tools yourself (see README); continuing"
        return 0
    fi
    say "Checking filesystem tool packages"
    for p in "${PKGS[@]}"; do
        if is_installed "$p"; then same "$p"
        elif [[ -n ${KNOWN_UNAVAIL[$p]:-} ]]; then known+=("$p")
        else missing+=("$p"); fi
    done
    ((${#known[@]})) && same "not in this release's repos (known): ${known[*]} — --retry-unavailable to re-check"
    # Arch AUR extras count as missing only if neither name is installed
    local want_aur=()
    if [[ $FAMILY == arch ]] && ((USE_AUR)); then
        for p in "${AUR[@]}"; do
            [[ $p == reiserfsprogs ]] && { is_installed reiserfsprogs || [[ " ${missing[*]} " == *" reiserfsprogs "* ]]; } && continue
            is_installed "$p" || is_installed "${p%-git}" || want_aur+=("$p")
        done
    fi
    if ((${#missing[@]} == 0 && ${#want_aur[@]} == 0)); then
        ok "all filesystem tools already present — package manager not touched"
        write_state "$UNAVAIL_FILE" "$(printf '%s\n' "${known[@]+"${known[@]}"}" | sed '/^$/d' | sort -u)"
        return 0
    fi
    if [[ -e /run/ostree-booted ]]; then
        warn "image-based (ostree) system — layer the tools with:"
        warn "  rpm-ostree install --idempotent ${missing[*]}   (then reboot)"
        return 0
    fi
    if have transactional-update && [[ $(findmnt -no OPTIONS / 2>/dev/null) == ro,* ]]; then
        warn "transactional (read-only root) openSUSE — install the tools with:"
        warn "  transactional-update pkg install ${missing[*]}   (then reboot)"
        return 0
    fi

    if ((${#missing[@]})); then
        [[ $FAMILY == debian ]] && { apt-get update -qq || warn "apt-get update failed — using cached package lists"; }
        for p in "${missing[@]}"; do
            if is_available "$p"; then avail+=("$p"); else unavail+=("$p"); fi
        done
    fi
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
    if ((${#want_aur[@]})); then
        local helper user=${SUDO_USER:-${DOAS_USER:-}}
        helper=$(type -P paru || type -P yay || true)
        if [[ -n $helper && -n $user && $user != root ]]; then
            say "Installing AUR packages as $user via $(basename "$helper"): ${want_aur[*]}"
            runuser -u "$user" -- "$helper" -S --needed --noconfirm "${want_aur[@]}" ||
                warn "AUR install failed for some of: ${want_aur[*]}"
        else
            warn "AUR-only (install with an AUR helper): ${want_aur[*]}"
        fi
    fi
    for p in "${unavail[@]+"${unavail[@]}"}"; do warn "not available for this release: $p (optional)"; done
    write_state "$UNAVAIL_FILE" "$(printf '%s\n' "${known[@]+"${known[@]}"}" "${unavail[@]+"${unavail[@]}"}" | sed '/^$/d' | sort -u)"
    if [[ $FAMILY == fedora ]] && ! have fsck.apfs && ! have apfsck; then
        warn "APFS checker (apfsprogs) isn't in Fedora — build it from https://github.com/linux-apfs/apfsprogs if you need APFS"
    fi
    return 0
}

((NO_DEPS)) || install_deps

# ── program + alias ────────────────────────────────────────────────────────
say "Installing program"
put_file "$HERE/usb-dirtybit" "$BIN" 0755
if [[ -L $LINK && $(readlink -- "$LINK") == usb-dirtybit ]]; then
    same "$LINK → usb-dirtybit (unchanged)"
else
    note_new "$LINK"; ln -sfn usb-dirtybit "$LINK" && ok "$LINK → usb-dirtybit (works from sudo, scripts, any shell)"
fi
[[ -f $HERE/README.md ]] && put_file "$HERE/README.md" "$DOC/README.md" 0644

say "Installing the 'dirtybit' alias"
put_text "$PROFILE" 0644 "# dirtybit — fsck removable USB drives + clear dirty bits (installed by dirtybit/install.sh)
alias dirtybit='$BIN'
"
# bash: Fedora's /etc/bashrc already sources profile.d for interactive shells
case $FAMILY in
    suse)   add_hook /etc/bash.bashrc.local create ;;
    fedora) grep -q 'profile.d' /etc/bashrc 2>/dev/null || add_hook /etc/bashrc ;;
    *)      add_hook /etc/bash.bashrc ;;
esac
# zsh: Arch's zsh reads /etc/zsh/zshrc but ships none — create it there
if [[ $FAMILY == arch ]] && have zsh && [[ ! -e /etc/zshrc ]]; then
    add_hook /etc/zsh/zshrc create
else
    add_hook /etc/zshrc
    add_hook /etc/zsh/zshrc
fi
# fish
if [[ -d /etc/fish ]]; then
    put_text "$FISH" 0644 "# dirtybit (installed by dirtybit/install.sh)
alias dirtybit '$BIN'
"
fi
save_manifest

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
