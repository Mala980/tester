#!/usr/bin/env python3
"""Apply Android/bionic ELF fixes to aarch64 binaries.

Equivalent of what `termux-elf-cleaner` does on-device:
  - PT_TLS p_align -> 64   (bionic requires 64-byte aligned TLS; Android 14+)
  - PT_GNU_RELRO align -> 16384 (match the 64 KB max page size Zig emits)
  - DF_1_* dynamic flags sanitized (replace unsupported flag combos with 1)

Usage: elf-fix.py <binary...>
"""
import struct
import sys

PT_LOAD = 1
PT_DYNAMIC = 2
PT_TLS = 7
PT_GNU_RELRO = 0x6474E552
DT_FLAGS_1 = 0x6FFFFFFB
DF_1_NOW = 0x1
DF_1_PIE = 0x08000000


def fix(path: str) -> bool:
    changed = False
    with open(path, "r+b") as f:
        data = f.read()
        if len(data) < 64 or data[:4] != b"\x7fELF":
            print(f"{path}: not an ELF, skipping")
            return False
        is64 = data[4] == 2
        if not is64:
            print(f"{path}: not ELF64, skipping")
            return False
        little = data[5] == 1
        endian = "<" if little else ">"

        e_phoff = struct.unpack_from(endian + "Q", data, 32)[0]
        e_phentsize = struct.unpack_from(endian + "H", data, 54)[0]
        e_phnum = struct.unpack_from(endian + "H", data, 56)[0]

        # Program headers
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            if off + 56 > len(data):
                break
            p_type = struct.unpack_from(endian + "I", data, off)[0]
            p_align_off = off + 48
            if p_type in (PT_TLS, PT_GNU_RELRO):
                p_align = struct.unpack_from(endian + "Q", data, p_align_off)[0]
                want = 64 if p_type == PT_TLS else 16384
                if p_align != want:
                    f.seek(p_align_off)
                    f.write(struct.pack(endian + "Q", want))
                    changed = True
                    print(
                        f"{path}: PT_{'TLS' if p_type == PT_TLS else 'GNU_RELRO'} "
                        f"p_align {p_align:#x} -> {want:#x}"
                    )

        # Dynamic section: sanitize DT_FLAGS_1
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            if off + 56 > len(data):
                break
            p_type = struct.unpack_from(endian + "I", data, off)[0]
            if p_type != PT_DYNAMIC:
                continue
            p_offset = struct.unpack_from(endian + "Q", data, off + 8)[0]
            p_filesz = struct.unpack_from(endian + "Q", data, off + 32)[0]
            for j in range(0, p_filesz, 16):
                tag_off = p_offset + j
                if tag_off + 16 > len(data):
                    break
                d_tag = struct.unpack_from(endian + "q", data, tag_off)[0]
                if d_tag == DT_FLAGS_1:
                    val = struct.unpack_from(endian + "Q", data, tag_off + 8)[0]
                    bad = val & ~DF_1_NOW
                    if bad:
                        f.seek(tag_off + 8)
                        f.write(struct.pack(endian + "Q", DF_1_NOW))
                        changed = True
                        print(f"{path}: DT_FLAGS_1 {val:#x} -> {DF_1_NOW:#x}")
    return changed


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    rc = 0
    for p in sys.argv[1:]:
        try:
            fix(p)
        except OSError as e:
            print(f"{p}: {e}")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())