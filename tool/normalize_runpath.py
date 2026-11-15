#!/usr/bin/env python3
"""Point every shared object in an installed bundle at its own directory (#301).

The Flutter toolchain links each plugin library with the RUNPATH of the
directory it was COMPILED in — an absolute path into the build tree. That path
means nothing on the machine the package is installed on: a locally built
package embeds the builder's home directory, a released one names a directory
that exists nowhere, and lintian reports every such library as
`custom-library-search-path`. Nothing needs it either — the engine and the other
plugins sit next to the library that looks for them.

So this rewrites DT_RUNPATH/DT_RPATH to `$ORIGIN`, the directory the library is
loaded from, which is exactly where its neighbours are. Called by BOTH packagers
(tool/build_rpm.sh, tool/build_deb.sh) on the staged tree, so the two packages
cannot differ in this.

How, and why it is safe: `$ORIGIN` is shorter than any path being replaced, so
the string is overwritten IN PLACE inside .dynstr and terminated one byte early.
No section moves, no offset changes, no header is touched — the same edit
chrpath makes, and the reason it needs no patchelf-style rewriting of the file.
Bytes after the new terminator are deliberately left alone: the linker may have
merged another string into the tail of this one.

Usage:  tool/normalize_runpath.py DIR [DIR...]

Walks each DIR, edits every ELF file that declares a RUNPATH/RPATH outside
`$ORIGIN`, and prints what it changed. Files it cannot parse as ELF (libapp.so's
Dart snapshot payload, data files, scripts) are skipped. Anything that looks
like a defect — an ELF it cannot follow, a RUNPATH too short to shorten — is a
hard failure: a silent skip here would ship the build tree.
"""

import os
import struct
import sys

ELF_MAGIC = b"\x7fELF"
ELFCLASS64, ELFDATA2LSB = 2, 1
PT_LOAD, PT_DYNAMIC = 1, 2
DT_NULL, DT_STRTAB, DT_RPATH, DT_RUNPATH = 0, 5, 15, 29
NEW_RUNPATH = b"$ORIGIN"


class ElfError(Exception):
    """The file is an ELF object this tool will not silently pass over."""


def _vaddr_to_offset(loads, vaddr):
    for p_vaddr, p_offset, p_filesz in loads:
        if p_vaddr <= vaddr < p_vaddr + p_filesz:
            return p_offset + (vaddr - p_vaddr)
    raise ElfError(f"virtual address 0x{vaddr:x} is in no PT_LOAD segment")


def _read_program_headers(data):
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
    e_phnum = struct.unpack_from("<H", data, 0x38)[0]
    loads, dynamic = [], None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + 0x28 > len(data):
            raise ElfError("program header table runs past the end of the file")
        (p_type,) = struct.unpack_from("<I", data, off)
        p_offset, p_vaddr = struct.unpack_from("<QQ", data, off + 0x08)
        (p_filesz,) = struct.unpack_from("<Q", data, off + 0x20)
        if p_type == PT_LOAD:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == PT_DYNAMIC:
            dynamic = (p_offset, p_filesz)
    return loads, dynamic


def _read_dynamic(data, dynamic):
    """(DT_STRTAB vaddr, [(tag, string offset)]) for the RUNPATH/RPATH entries."""
    offset, size = dynamic
    strtab_vaddr, search_paths = None, []
    for i in range(size // 16):
        at = offset + i * 16
        if at + 16 > len(data):
            raise ElfError("PT_DYNAMIC runs past the end of the file")
        tag, value = struct.unpack_from("<qQ", data, at)
        if tag == DT_NULL:
            break
        if tag == DT_STRTAB:
            strtab_vaddr = value
        elif tag in (DT_RPATH, DT_RUNPATH):
            search_paths.append((tag, value))
    return strtab_vaddr, search_paths


def normalize(path):
    """Rewrite `path`'s search paths to $ORIGIN. Returns the old value, or None
    when the file is not an ELF object or already searches only $ORIGIN."""
    with open(path, "rb") as f:
        head = f.read(6)
    if head[:4] != ELF_MAGIC:
        return None
    if head[4] != ELFCLASS64 or head[5] != ELFDATA2LSB:
        raise ElfError(
            "not a little-endian 64-bit ELF object; the packaged bundle is "
            "amd64 and this tool refuses to guess at anything else"
        )

    with open(path, "r+b") as f:
        data = bytearray(f.read())
        loads, dynamic = _read_program_headers(data)
        if dynamic is None:
            return None
        strtab_vaddr, search_paths = _read_dynamic(data, dynamic)
        if not search_paths:
            return None
        if strtab_vaddr is None:
            raise ElfError("declares a RUNPATH but no DT_STRTAB to read it from")
        strtab = _vaddr_to_offset(loads, strtab_vaddr)

        was = None
        for _tag, string_offset in search_paths:
            start = strtab + string_offset
            end = data.find(b"\0", start)
            if end < 0:
                raise ElfError("unterminated string in .dynstr")
            old = bytes(data[start:end])
            if all(e.startswith(NEW_RUNPATH) for e in old.split(b":")):
                continue
            if len(old) < len(NEW_RUNPATH):
                raise ElfError(
                    f'RUNPATH "{old.decode(errors="replace")}" is shorter than '
                    "$ORIGIN and cannot be rewritten in place"
                )
            was = old.decode(errors="replace")
            data[start : start + len(NEW_RUNPATH)] = NEW_RUNPATH
            data[start + len(NEW_RUNPATH)] = 0
        if was is None:
            return None
        f.seek(0)
        f.write(data)
        f.truncate()
    return was


def main(argv):
    roots = argv[1:]
    if not roots:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        print("usage: tool/normalize_runpath.py DIR [DIR...]", file=sys.stderr)
        return 2
    failed = False
    for root in roots:
        if not os.path.isdir(root):
            print(f"error: {root} is not a directory", file=sys.stderr)
            return 1
        for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
            for name in sorted(filenames):
                path = os.path.join(dirpath, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    continue
                try:
                    was = normalize(path)
                except (ElfError, struct.error, OSError) as exc:
                    print(f"error: {path}: {exc}", file=sys.stderr)
                    failed = True
                    continue
                if was is not None:
                    rel = os.path.relpath(path, root)
                    print(f"    RUNPATH {rel}: {was} -> $ORIGIN", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
