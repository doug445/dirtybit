#!/usr/bin/env bash
# Build a set of small filesystem images, several deliberately marked dirty,
# for exercising dirtybit without root:  usb-dirtybit -y -i <img> ...
# Usage: tests/make-test-images.sh [outdir]   (default: ./test-images)
set -u
OUT=${1:-./test-images}
mkdir -p "$OUT" && cd "$OUT" || exit 1
rm -f ./*.img

poke() { # file offset value — write one byte
    # shellcheck disable=SC2059
    printf "\\x$(printf %02x "$3")" | dd of="$1" bs=1 seek="$2" count=1 conv=notrunc status=none
}
peek() { od -An -tu1 -j"$2" -N1 "$1" | tr -d ' '; }
mk() { truncate -s "$2" "$1"; }

if type -P mkfs.fat >/dev/null; then
    mk fat32-dirty.img 64M; mkfs.fat -F32 -n FAT32DIRTY fat32-dirty.img >/dev/null
    poke fat32-dirty.img 65 $(($(peek fat32-dirty.img 65) | 1))      # Linux boot-sector dirty bit
    rsvd=$(od -An -tu2 -j14 -N2 fat32-dirty.img | tr -d ' ')
    poke fat32-dirty.img $((rsvd * 512 + 7)) 0x03                     # Windows FAT[1] clean+harderr bits off
    mk fat16-dirty.img 32M; mkfs.fat -F16 -n FAT16DIRTY fat16-dirty.img >/dev/null
    poke fat16-dirty.img 37 1
fi
if type -P mkfs.exfat >/dev/null; then
    mk exfat-dirty.img 64M; mkfs.exfat -L EXDIRTY exfat-dirty.img >/dev/null
    poke exfat-dirty.img 106 2
fi
if type -P mkfs.ntfs >/dev/null && type -P python3 >/dev/null; then
    mk ntfs-dirty.img 64M; mkfs.ntfs -F -f -q -L NTFSDIRTY ntfs-dirty.img >/dev/null 2>&1
    python3 -I - ntfs-dirty.img <<'PY'
import struct, sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    bs = f.read(512)
    bps, spc = struct.unpack_from('<HB', bs, 11)
    mft_lcn = struct.unpack_from('<q', bs, 0x30)[0]
    c = struct.unpack_from('<b', bs, 0x40)[0]
    rec = (1 << -c) if c < 0 else c * bps * spc
    mirr_lcn = struct.unpack_from('<q', bs, 0x38)[0]
    # MFT record 3 = $Volume; Windows updates it in $MFT and $MFTMirr alike
    for base in (mft_lcn, mirr_lcn):
        off = base * bps * spc + 3 * rec
        f.seek(off); r = bytearray(f.read(rec))
        a = struct.unpack_from('<H', r, 0x14)[0]
        while a < rec:
            t, ln = struct.unpack_from('<II', r, a)
            if t == 0xFFFFFFFF: break
            if t == 0x70:                           # $VOLUME_INFORMATION
                v = a + struct.unpack_from('<H', r, a + 0x14)[0]
                fl = struct.unpack_from('<H', r, v + 0x0A)[0] | 1
                struct.pack_into('<H', r, v + 0x0A, fl)
                f.seek(off); f.write(r); break
            a += ln
PY
fi
if type -P mkfs.ext4 >/dev/null; then
    mk ext4-dirty.img 64M; mkfs.ext4 -q -L EXT4DIRTY ext4-dirty.img
    debugfs -w -R "ssv state 0" ext4-dirty.img >/dev/null 2>&1
    mk ext4-16k.img 128M; mkfs.ext4 -q -F -b 16384 -L EXT4-16K ext4-16k.img 2>/dev/null
fi
if type -P mkfs.btrfs >/dev/null; then
    mk btrfs-16k.img 256M; mkfs.btrfs -q -f -s 16384 -L BTRFS16K btrfs-16k.img >/dev/null
    mk btrfs-4k.img 256M; mkfs.btrfs -q -f -s 4096 -L BTRFS4K btrfs-4k.img >/dev/null
fi
if type -P mkfs.xfs >/dev/null; then
    mk xfs-16k.img 400M; mkfs.xfs -q -f -b size=16384 -L XFS16K xfs-16k.img
fi
if type -P mkfs.f2fs >/dev/null; then
    mk f2fs.img 128M; mkfs.f2fs -q -f -l F2FS f2fs.img
    # 16K-block F2FS needs a newer mkfs.f2fs (-b); made on aarch64 16K kernels by default
    mk f2fs-16k.img 256M
    mkfs.f2fs -b 16384 -q -f -l F2FS16K f2fs-16k.img >/dev/null 2>&1 || rm -f f2fs-16k.img
fi
if type -P mkfs.hfsplus >/dev/null; then
    mk hfsplus-dirty.img 64M; mkfs.hfsplus -v HFSDIRTY hfsplus-dirty.img >/dev/null 2>&1
    poke hfsplus-dirty.img 1030 $(($(peek hfsplus-dirty.img 1030) & ~1))  # clear kHFSVolumeUnmountedBit
fi
if type -P mkfs.jfs >/dev/null; then
    mk jfs-dirty.img 64M; mkfs.jfs -q -L JFSDIRTY jfs-dirty.img >/dev/null 2>&1
    poke jfs-dirty.img $((32768 + 40)) 2                                   # FM_DIRTY
fi
if type -P mkfs.erofs >/dev/null; then
    d=$(mktemp -d); echo hello >"$d/hello.txt"
    mkfs.erofs erofs.img "$d" >/dev/null 2>&1; rm -rf "$d"
fi
ls -1 ./*.img
