#!/usr/bin/env python3
"""
cpm.py -- a very small CP/M 2.2 emulator, sufficient to run the genuine
Digital Research RMAC, DRLINK and GENCPM binaries against ordinary host
files.  Written for this build only; it is a build tool, not a product.

Drive A: is the current working directory.  File names are the usual
CP/M 8.3, stored on the host in upper case.

Console output is echoed to stdout so that GENCPM's transcript can be
read; console input is taken from a queue supplied on the command line.
"""

import os, sys
import z80

BDOS_TRAP = 0xFF00
WBOOT     = 0x0000
RECLEN    = 128


class CPM:
    def __init__(self, answers=None, verbose=True):
        self.m = z80.Z80Machine()
        self.dma = 0x0080
        self.user = 0
        self.drive = 0
        self.files = {}          # fcb address -> open host file object
        self.out = []
        self.answers = list(answers or [])
        self.verbose = verbose
        self.search = []
        self.exit_code = None

    # ---------------------------------------------------------------- memory
    def rd(self, a):   return self.m.memory[a & 0xFFFF]
    def wr(self, a, v): self.m.memory[a & 0xFFFF] = v & 0xFF
    def rdw(self, a):  return self.rd(a) | (self.rd(a + 1) << 8)

    def block(self, a, n):
        return bytes(self.m.memory[a:a + n])

    def putblock(self, a, data):
        self.m.set_memory_block(a & 0xFFFF, bytes(data))

    # ------------------------------------------------------------------ page 0
    def setup(self):
        mem = bytearray(0x10000)
        self.putblock(0, bytes(mem))
        # warm boot vector
        self.wr(0x0000, 0xC3); self.wr(0x0001, 0x03); self.wr(0x0002, 0xFF)
        self.wr(0x0003, 0x00)          # IOBYTE
        self.wr(0x0004, 0x00)          # current drive / user
        # BDOS entry
        self.wr(0x0005, 0xC3)
        self.wr(0x0006, BDOS_TRAP & 0xFF); self.wr(0x0007, BDOS_TRAP >> 8)
        self.wr(BDOS_TRAP, 0x76)       # halt marker (never executed)
        self.wr(0xFF03, 0x76)
        self.m.set_breakpoint(BDOS_TRAP)
        self.m.set_breakpoint(0xFF03)

    # --------------------------------------------------------------- file names
    @staticmethod
    def fcb_name(data):
        name = bytes(b & 0x7F for b in data[1:9]).decode('latin1').rstrip()
        ext  = bytes(b & 0x7F for b in data[9:12]).decode('latin1').rstrip()
        return (name + '.' + ext) if ext else name

    def host_path(self, fcb):
        return self.fcb_name(self.block(fcb, 12)).upper()

    # ------------------------------------------------------------------ helpers
    def conout(self, ch):
        c = chr(ch & 0x7F)
        self.out.append(c)
        if self.verbose:
            sys.stdout.write(c)
            sys.stdout.flush()

    def conin(self):
        while True:
            if not self.answers:
                return 0x0D
            s = self.answers[0]
            if s == '':
                self.answers.pop(0)
                return 0x0D
            ch = s[0]
            self.answers[0] = s[1:]
            return ord(ch)

    def readline(self, buf):
        maxlen = self.rd(buf)
        line = self.answers.pop(0) if self.answers else ''
        line = line[:maxlen].upper()
        self.wr(buf + 1, len(line))
        for i, ch in enumerate(line):
            self.wr(buf + 2 + i, ord(ch))
        for ch in line:
            self.conout(ord(ch))
        self.conout(0x0D); self.conout(0x0A)

    # ------------------------------------------------------------- file objects
    def openfile(self, fcb, create=False):
        path = self.host_path(fcb)
        if create:
            f = open(path, 'w+b')
        else:
            if not os.path.exists(path):
                return None
            f = open(path, 'r+b')
        self.files[fcb] = f
        return f

    def getfile(self, fcb):
        f = self.files.get(fcb)
        if f is None:
            path = self.host_path(fcb)
            if not os.path.exists(path):
                return None
            f = open(path, 'r+b')
            self.files[fcb] = f
        return f

    @staticmethod
    def seqrec(d):
        return (d[14] & 0x3F) * 4096 + (d[12] & 0x1F) * 128 + d[32]

    def setseq(self, fcb, rec):
        self.wr(fcb + 32, rec % 128)
        self.wr(fcb + 12, (rec // 128) % 32)
        self.wr(fcb + 14, rec // 4096)

    def readrec(self, f, rec):
        f.seek(0, 2)
        size = f.tell()
        if rec * RECLEN >= size:
            return None
        f.seek(rec * RECLEN)
        data = f.read(RECLEN)
        if len(data) < RECLEN:
            data += b'\x1a' * (RECLEN - len(data))
        return data

    def writerec(self, f, rec, data):
        f.seek(0, 2)
        size = f.tell()
        if rec * RECLEN > size:
            f.write(b'\x00' * (rec * RECLEN - size))
        f.seek(rec * RECLEN)
        f.write(data)
        f.flush()

    # ------------------------------------------------------------------- BDOS
    def bdos(self):
        fn = self.m.c
        de = self.m.de
        a = 0
        if fn == 0:
            self.exit_code = 0
            return None
        elif fn == 1:
            a = self.conin(); self.conout(a)
        elif fn == 2:
            self.conout(self.m.e)
        elif fn == 6:
            if self.m.e == 0xFF:
                a = 0
            else:
                self.conout(self.m.e)
        elif fn == 9:
            p = de
            while self.rd(p) != ord('$'):
                self.conout(self.rd(p)); p += 1
        elif fn == 10:
            self.readline(de)
        elif fn == 11:
            a = 0
        elif fn == 12:
            a = 0x22
        elif fn == 13:
            self.dma = 0x0080
        elif fn == 14:
            self.drive = self.m.e
        elif fn == 15:                                   # open
            f = self.openfile(de)
            if f is None:
                a = 0xFF
            else:
                f.seek(0, 2)
                recs = (f.tell() + RECLEN - 1) // RECLEN
                for i in range(12, 32):
                    self.wr(de + i, 0)
                self.wr(de + 15, min(recs, 128))
                self.wr(de + 32, 0)
                a = 0
        elif fn == 16:                                   # close
            f = self.files.pop(de, None)
            if f:
                f.close()
            a = 0
        elif fn in (17, 18):                             # search first / next
            if fn == 17:
                pat = self.host_path(de)
                if '?' in pat:
                    self.search = sorted(os.listdir('.'))
                else:
                    self.search = [pat] if os.path.exists(pat) else []
            a = 0xFF
            if self.search:
                nm = self.search.pop(0)
                base, _, ext = nm.partition('.')
                ent = bytearray(32)
                ent[0] = 0
                ent[1:9] = base.ljust(8)[:8].encode()
                ent[9:12] = ext.ljust(3)[:3].encode()
                self.putblock(self.dma, bytes(ent) + bytes(96))
                a = 0
        elif fn == 19:                                   # delete
            path = self.host_path(de)
            if os.path.exists(path):
                os.remove(path)
                a = 0
            else:
                a = 0xFF
        elif fn == 20:                                   # read sequential
            f = self.getfile(de)
            if f is None:
                a = 1
            else:
                d = self.block(de, 36)
                rec = self.seqrec(d)
                data = self.readrec(f, rec)
                if data is None:
                    a = 1
                else:
                    self.putblock(self.dma, data)
                    self.setseq(de, rec + 1)
                    a = 0
        elif fn == 21:                                   # write sequential
            f = self.getfile(de)
            if f is None:
                a = 1
            else:
                d = self.block(de, 36)
                rec = self.seqrec(d)
                self.writerec(f, rec, self.block(self.dma, RECLEN))
                self.setseq(de, rec + 1)
                a = 0
        elif fn == 22:                                   # make
            f = self.openfile(de, create=True)
            for i in range(12, 32):
                self.wr(de + i, 0)
            self.wr(de + 32, 0)
            a = 0
        elif fn == 23:                                   # rename
            old = self.fcb_name(self.block(de, 12)).upper()
            new = self.fcb_name(self.block(de + 16, 12)).upper()
            if os.path.exists(old):
                os.rename(old, new); a = 0
            else:
                a = 0xFF
        elif fn == 25:
            a = self.drive
        elif fn == 26:
            self.dma = de
        elif fn == 29:
            a = 0
        elif fn == 32:
            if self.m.e == 0xFF:
                a = self.user
            else:
                self.user = self.m.e
        elif fn == 33:                                   # read random
            f = self.getfile(de)
            if f is None:
                a = 1
            else:
                rec = self.rd(de + 33) | (self.rd(de + 34) << 8) | (self.rd(de + 35) << 16)
                data = self.readrec(f, rec)
                if data is None:
                    a = 1
                else:
                    self.putblock(self.dma, data)
                    self.setseq(de, rec)
                    a = 0
        elif fn == 34:                                   # write random
            f = self.getfile(de)
            if f is None:
                a = 1
            else:
                rec = self.rd(de + 33) | (self.rd(de + 34) << 8) | (self.rd(de + 35) << 16)
                self.writerec(f, rec, self.block(self.dma, RECLEN))
                self.setseq(de, rec)
                a = 0
        elif fn == 35:                                   # compute file size
            path = self.host_path(de)
            size = os.path.getsize(path) if os.path.exists(path) else 0
            recs = (size + RECLEN - 1) // RECLEN
            self.wr(de + 33, recs & 0xFF)
            self.wr(de + 34, (recs >> 8) & 0xFF)
            self.wr(de + 35, (recs >> 16) & 0xFF)
        elif fn == 36:                                   # set random record
            d = self.block(de, 36)
            rec = self.seqrec(d)
            self.wr(de + 33, rec & 0xFF)
            self.wr(de + 34, (rec >> 8) & 0xFF)
            self.wr(de + 35, (rec >> 16) & 0xFF)
        else:
            sys.stderr.write('\n[unimplemented BDOS function %d]\n' % fn)
        return a

    # -------------------------------------------------------------------- run
    def run(self, comfile, cmdtail=''):
        self.setup()
        with open(comfile, 'rb') as fh:
            img = fh.read()
        self.putblock(0x0100, img)

        # command tail and default FCBs
        tail = cmdtail.upper()
        self.wr(0x0080, len(tail))
        for i, ch in enumerate(tail):
            self.wr(0x0081 + i, ord(ch))
        self.wr(0x0081 + len(tail), 0)
        parts = tail.split()
        for idx, base in ((0, 0x005C), (1, 0x006C)):
            for i in range(16):
                self.wr(base + i, 0)
            if idx < len(parts):
                nm, _, ex = parts[idx].partition('.')
                self.wr(base, 0)
                for i in range(8):
                    self.wr(base + 1 + i, ord(nm[i]) if i < len(nm) else 0x20)
                for i in range(3):
                    self.wr(base + 9 + i, ord(ex[i]) if i < len(ex) else 0x20)
            else:
                for i in range(11):
                    self.wr(base + 1 + i, 0x20)

        self.m.pc = 0x0100
        self.m.sp = 0xFE00
        self.wr(0xFDFE, 0x00); self.wr(0xFDFF, 0x00)   # return to warm boot

        steps = 0
        while True:
            self.m.ticks_to_stop = 20_000_000
            self.m.run()
            pc = self.m.pc
            if pc == BDOS_TRAP:
                a = self.bdos()
                if self.exit_code is not None:
                    return self.exit_code
                sp = self.m.sp
                ret = self.rd(sp) | (self.rd(sp + 1) << 8)
                self.m.sp = (sp + 2) & 0xFFFF
                self.m.pc = ret
                self.m.a = a & 0xFF
                self.m.l = a & 0xFF
                self.m.h = 0
                self.m.b = 0
            elif pc == 0xFF03 or pc == 0x0000:
                return 0
            elif self.m.halted:
                return 0
            else:
                steps += 1
                if steps > 200000:
                    sys.stderr.write('\n[emulator: runaway, pc=%04X]\n' % pc)
                    return 1


def main():
    if len(sys.argv) < 2:
        print('usage: cpm.py <prog.com> [cmdtail] [-a answer]...')
        return 2
    prog = sys.argv[1]
    tail = sys.argv[2] if len(sys.argv) > 2 else ''
    answers = []
    args = sys.argv[3:]
    i = 0
    while i < len(args):
        if args[i] == '-a':
            answers.append(args[i + 1]); i += 2
        else:
            i += 1
    c = CPM(answers=answers)
    return c.run(prog, tail)


if __name__ == '__main__':
    sys.exit(main())
