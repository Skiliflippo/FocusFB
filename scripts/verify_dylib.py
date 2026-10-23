#!/usr/bin/env python3
"""
Verifica binaria Mach-O 64 per FocusFB.dylib:
1. Architettura arm64 (MH_MAGIC_64 + CPU_TYPE_ARM64)
2. Presenza sezione constructor (__mod_init_func / __init_offsets)
3. Assenza totale di dipendenze da CydiaSubstrate / libsubstrate (compatibilita nativa SideStore, Feather, LiveContainer)
"""

import struct
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F

SECTION_TYPE_MASK = 0x000000FF
S_MOD_INIT_FUNC_POINTERS = 0x09
S_INIT_FUNC_OFFSETS = 0x16


def verify_macho_arm64(path: Path) -> None:
    data = path.read_bytes()
    if len(data) < 32:
        raise SystemExit(f"[ERRORE] File troppo piccolo per essere un Mach-O valido: {path}")

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
        "<IIIIIIII", data, 0
    )
    if magic != MH_MAGIC_64:
        raise SystemExit(
            f"[ERRORE] FocusFB.dylib deve essere un binario arm64 singolo (MH_MAGIC_64), trovato magic=0x{magic:08x}"
        )
    if cputype != CPU_TYPE_ARM64:
        raise SystemExit(
            f"[ERRORE] cputype inatteso: 0x{cputype:08x} (atteso CPU_TYPE_ARM64 0x0100000c)"
        )

    offset = 32
    init_sections = []
    linked_dylibs = []

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == LC_SEGMENT_64:
            segname_raw, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, segflags = (
                struct.unpack_from("<16sQQQQiiII", data, offset + 8)
            )
            segname = segname_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
            sect_off = offset + 72
            for _ in range(nsects):
                (
                    sectname_raw,
                    s_seg_raw,
                    s_addr,
                    s_size,
                    s_offset,
                    s_align,
                    s_reloff,
                    s_nreloc,
                    s_flags,
                    _r1,
                    _r2,
                    _r3,
                ) = struct.unpack_from("<16s16sQQIIIIIIII", data, sect_off)
                sectname = sectname_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
                stype = s_flags & SECTION_TYPE_MASK
                if s_size > 0 and stype in (S_MOD_INIT_FUNC_POINTERS, S_INIT_FUNC_OFFSETS):
                    init_sections.append((segname, sectname, stype, s_size))
                sect_off += 80
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            str_offset = struct.unpack_from("<I", data, offset + 8)[0]
            raw_str = data[offset + str_offset : offset + cmdsize].split(b"\x00", 1)[0]
            linked_dylibs.append(raw_str.decode("utf-8", errors="replace"))

        offset += cmdsize

    if not init_sections:
        raise SystemExit("[ERRORE] Nessuna sezione constructor/initializer trovata in FocusFB.dylib!")

    forbidden = ("cydiasubstrate", "libsubstrate", "substitute", "ellekit")
    bad_deps = [d for d in linked_dylibs if any(tok in d.lower() for tok in forbidden)]
    if bad_deps:
        raise SystemExit(
            f"[ERRORE] FocusFB.dylib contiene dipendenze esterne vietate per LiveContainer/SideStore: {bad_deps}"
        )

    print(f"[OK] {path.name}: Mach-O arm64 valido ({len(data):,} byte)")
    for seg, sect, stype, sz in init_sections:
        print(f"[OK] Initializer trovato: {seg},{sect} (type=0x{stype:02x}, size={sz})")
    print(f"[OK] Dipendenze dinamiche ({len(linked_dylibs)}): nessuna dipendenza da Substrate/ElleKit")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Uso: verify_dylib.py <percorso/FocusFB.dylib>")
    verify_macho_arm64(Path(sys.argv[1]))
