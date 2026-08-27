#!/usr/bin/env python3
"""
mkfid.py -- build a Field Installable Device Driver for Agon CP/M 3.

WHY THIS EXISTS
---------------
ez80asm emits absolute binaries only: there is no relocatable object format
and no linker.  A driver, though, has to be loadable at whatever address is
free in segment $04 when it is loaded, which moves every time cpm3.bin
changes size or another driver is loaded first.

So the relocation information is recovered rather than declared.  The source
is assembled TWICE at two origins a known distance apart, and the two images
compared.  Any byte that differs between them belongs to an address that the
assembler resolved, and every such address differs by exactly the distance
between the two origins.  That gives the position and size of every fixup
without the assembler having to cooperate.

The check is self-verifying: every byte that differs must be accounted for by
exactly one detected fixup.  If any differing byte is left over, the two
builds disagree for some reason other than relocation and this tool refuses
to produce a file rather than emit one with a fixup missing.

Addresses in the SVC table need no fixup at all: that table is at a fixed
address for all time, so references to it are identical in both builds and
never show up as differences.

USAGE
    mkfid.py driver.asm driver.fid

    mkfid.py --images low.bin high.bin --base 60000 --delta 4000 out.fid
        (when the two builds were made elsewhere, e.g. on the Agon itself)

FILE FORMAT
    +00  jp fid_ems        4   ADL jump to the entry point (relocated)
    +04  'AGONFID1'        8   signature and format version
    +0C  link base         3   origin the image was assembled at
    +0F  image length      3   code and data, from +00
    +12  bss length        3   zeroed by the loader above the image
    +15  reloc offset      3   where the fixup table starts
    +18  reloc count       3   number of fixups
    +1B  api version       2   SVC table version required
    +1D  checksum          2   16-bit sum of the file, this field as zero
    +1F  reserved          1

    Each fixup is a 3-byte little-endian offset from the start of the image,
    naming a 24-bit field that holds an address inside the module.

The header is written by the driver source itself (see the FIDHDR macro in
fid.inc); this tool fills in the fields it cannot know at assembly time.
"""

import argparse
import os
import subprocess
import sys

SIG = b"AGONFID1"
HDR_LEN = 32
API_VERSION = 1

OFF_SIG = 4
OFF_LINK = 12
OFF_IMAGE = 15
OFF_BSS = 18
OFF_RELOC = 21
OFF_RCNT = 24
OFF_APIV = 27
OFF_SUM = 29

DEFAULT_BASE = 0x060000
DEFAULT_DELTA = 0x004000


def le24(b, i):
    return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16)


def put24(b, i, v):
    b[i] = v & 0xFF
    b[i + 1] = (v >> 8) & 0xFF
    b[i + 2] = (v >> 16) & 0xFF


def put16(b, i, v):
    b[i] = v & 0xFF
    b[i + 1] = (v >> 8) & 0xFF


def assemble(source, org, out):
    """Assemble source at the given origin.  Returns the image bytes."""
    cmd = ["ez80asm", source, out, "-o", "%X" % org]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        sys.exit("ez80asm not found on PATH.  Assemble the two images "
                 "yourself and use --images.")
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit("assembly failed at origin %06X" % org)
    with open(out, "rb") as f:
        return f.read()


def find_fixups(lo, hi, base, delta):
    """Locate every 24-bit field that moved by exactly delta.

    Returns (fixups, unexplained) where unexplained is the set of byte
    positions that differ but are not covered by any fixup.
    """
    if len(lo) != len(hi):
        sys.exit("the two builds are different lengths (%d and %d): the "
                 "source is not position independent in size, which usually "
                 "means an ORG or a size that depends on the origin"
                 % (len(lo), len(hi)))

    differing = {i for i in range(len(lo)) if lo[i] != hi[i]}
    fixups = []
    covered = set()

    # Scan EVERY position, not only the differing ones.  A 24-bit address
    # that moves by a delta with zero low byte -- 4000h, say -- changes only
    # its middle byte, so the field can start one or two bytes before the
    # first byte that differs.  Anchoring the scan on differing bytes would
    # miss exactly those, the first fixup in every module among them: the JP
    # in the header, whose field starts at offset 1.
    for i in range(len(lo) - 2):
        if covered & {i, i + 1, i + 2}:
            continue
        v1 = le24(lo, i)
        v2 = le24(hi, i)
        if v2 - v1 != delta:
            continue
        # It must point somewhere inside the module, otherwise it is a
        # coincidence rather than an address.
        if not (base <= v1 <= base + len(lo)):
            continue
        # And it must explain at least one byte that actually differs,
        # otherwise it is not evidence of anything.
        if not ({i, i + 1, i + 2} & differing):
            continue
        fixups.append(i)
        covered |= {i, i + 1, i + 2}

    return fixups, sorted(differing - covered)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", nargs="?", help="driver source (.asm)")
    ap.add_argument("output", help="driver output (.fid)")
    ap.add_argument("--images", nargs=2, metavar=("LOW", "HIGH"),
                    help="use two pre-built images instead of assembling")
    ap.add_argument("--base", type=lambda s: int(s, 16),
                    default=DEFAULT_BASE,
                    help="link origin in hex (default 060000)")
    ap.add_argument("--delta", type=lambda s: int(s, 16),
                    default=DEFAULT_DELTA,
                    help="distance between the two builds, hex "
                         "(default 004000)")
    ap.add_argument("--bss", type=lambda s: int(s, 0), default=0,
                    help="bytes of uninitialised space above the image")
    args = ap.parse_args()

    base = args.base
    delta = args.delta

    if args.images:
        with open(args.images[0], "rb") as f:
            lo = f.read()
        with open(args.images[1], "rb") as f:
            hi = f.read()
    else:
        if not args.source:
            sys.exit("give a source file, or two images with --images")
        stem = os.path.splitext(args.output)[0]
        lo = assemble(args.source, base, stem + ".lo.bin")
        hi = assemble(args.source, base + delta, stem + ".hi.bin")

    if len(lo) < HDR_LEN:
        sys.exit("image is shorter than a header")
    if bytes(lo[OFF_SIG:OFF_SIG + 8]) != SIG:
        sys.exit("no AGONFID1 signature at offset 4: the source must start "
                 "with the FIDHDR macro from fid.inc")

    fixups, unexplained = find_fixups(lo, hi, base, delta)

    if unexplained:
        sys.exit("%d byte(s) differ between the two builds but are not part "
                 "of any 24-bit address, first at offset %04X.  Refusing to "
                 "write a file with a fixup missing."
                 % (len(unexplained), unexplained[0]))

    image = bytearray(lo)
    image_len = len(image)

    reloc = bytearray()
    for off in fixups:
        b = bytearray(3)
        put24(b, 0, off)
        reloc += b

    out = image + reloc

    put24(out, OFF_LINK, base)
    put24(out, OFF_IMAGE, image_len)
    put24(out, OFF_BSS, args.bss)
    put24(out, OFF_RELOC, image_len)
    put24(out, OFF_RCNT, len(fixups))
    put16(out, OFF_APIV, API_VERSION)
    put16(out, OFF_SUM, 0)

    # The checksum counts its own two bytes as zero, which is why they are
    # cleared first.  The loader can then sum the whole file in one pass and
    # subtract the stored bytes back out, instead of testing an offset on
    # every byte.
    put16(out, OFF_SUM, sum(out) & 0xFFFF)

    with open(args.output, "wb") as f:
        f.write(out)

    print("%s: %d bytes image, %d bss, %d fixups, %d bytes total"
          % (args.output, image_len, args.bss, len(fixups), len(out)))


if __name__ == "__main__":
    main()
