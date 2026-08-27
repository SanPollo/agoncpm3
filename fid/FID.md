# Field Installable Device Drivers

Agon CP/M 3: Loadable Driver Mechanism
<br />Version 1.0
<br />(c) 2026 Nick J. Date. Released under the MIT Licence.

---

## Index

1. [About](#about)
2. [Details](#details)
3. [Memory Map](#memory-map)
4. [Compiling](#compiling)
5. [Loading](#loading)
6. [SVC Table](#svc-table)
7. [Character Devices (svc_chook)](#character-devices-svc_chook)
8. [Disc Drives (svc_dhook)](#disc-drives-svc_dhook)
9. [The two descriptors](#the-two-descriptors)
10. [Worked examples](#worked-examples)
11. [Diagnostics](#diagnostics)
12. [Building](#building)

---

## About

A Field Installable Device Driver (FID) is a driver loaded from the SD card at boot that can add a character device or a disc drive to a running CP/M 3 system, without rebuilding the BIOS or re-running GENCPM.

FIDs were originally implemented in CP/M Plus for the Amstrad CPC and PCW ranges of 8-bit computers, and you can read more about those on [John Elliott's site](https://www.seasip.info/Cpm/amsfid.html).

This document explains what the mechanism does, and how it works.

[Index](#index)

---

## Details

The FID is an ADL-mode eZ80 module living in segment `$04`, alongside the supervisor. It is not a CP/M program, nor a `.PRL`, and it never runs in a CP/M bank. It must not call the BDOS or the BIOS; everything it needs comes through a table of supervisor services. CP/M reaches these by gating out.

[Index](#index)

---

## Memory Map

```
segment $04   $040000-$04252E   Supervisor (cpm3.bin)
              $040100-$04014B   Gate Table - Fixed, append only
              $040180-$0401FF   SVC Table - Fixed, append only
              $04252F-$04452E   CCP Buffer (8K)
              $04452F-$04FFFF   FID Heap - (47,825 bytes)
```

The heap is whatever is left of segment `$04` after the supervisor, and the CCP buffer. Modules are loaded into it end to end, and a module may take more of it for its own use with `svc_alloc`. The boundaries move with the size of `cpm3.bin`, so the figures above are those of the build this document ships with.

[Index](#index)

---

## Compiling

`mkfid.py` produces a `.FID` file: a 32-byte header, the image, then a relocation table.

| Offset | Size | Field |
|---|---|---|
| `+00` | 4 | ADL jump to the entry point |
| `+04` | 8 | signature `AGONFID1` |
| `+0C` | 3 | origin the image was assembled at |
| `+0F` | 3 | image length, code plus data |
| `+12` | 3 | bss length - bytes zeroed above the image |
| `+15` | 3 | offset of the fixup table |
| `+18` | 3 | number of fixups |
| `+1B` | 2 | SVC API version required |
| `+1D` | 2 | 16-bit sum of the whole file |
| `+1F` | 1 | reserved |

### Relocation

[ez80asm](https://github.com/AgonPlatform/agon-ez80asm) is an absolute assembler with no object format, so `mkfid.py` assembles the driver twice at two origins and compares the two images. Every position whose bytes differ by the origin delta is an address needing a fixup. The scan tests every byte position, not only differing ones: a delta with a zero low byte changes only the middle byte of a 24-bit field, so the field can begin one or two bytes before the first byte that differs. The `jp` in the header, whose address field starts at offset 1, is exactly that case.

`mkfid.py` then verifies that every difference between the two images is accounted for by a fixup, so an address it failed to recognise is an error rather than a silent corruption.

### Addressing

SVC entries are at a fixed address, and need no relocation. References to the module's own code, and data are fixed up at load. A driver may therefore use absolute addressing freely.

[Index](#index)

---

## Loading

At `?init`, after the BIOS has installed the drives it knows about, it calls `agon$fidinit`, which gates to the supervisor's loader.

The loader reads `FID.INI`. The name is relative, so it is resolved against MOS's working directory - the directory CP/M was started from, which may be anywhere on the card. One filename per line; blank lines and lines starting `;` or `#` are ignored; load order is the order in the file. Wildcards, and directories are allowed:

```
*.FID              every driver beside cpm3.bin
fid/*.FID          every driver in a subdirectory (default)
/drivers/*.FID     an absolute path
RAMD.FID           one named driver
```

Names are reduced to a canonical form and de-duplicated, so a module named explicitly, and matched by a pattern is loaded once. Note, however, that `FID.INI` has a maximum file size of 512 bytes.

For each module the loader checks the length, the signature, the checksum and the API version, applies the fixups, zeroes the bss, then calls the module's entry point. On return:

- `A` = 0 - stay resident
- `A` ≠ 0 - discard
- `HL` = a null-terminated sign-on message, or 0 for silence

Every failure is reported, and skipped, as one bad driver must not stop the others from loading, or the system from booting.

### Heap Ordering

`fid_ptr` is advanced to just past the module before the entry routine runs, and rewound to the module's base if the module declines. A driver may therefore call `svc_alloc` from its entry routine, which is the only place most drivers will want to call it.

Reclaiming a declined module is explicit, and releases both its image, and anything it allocated before it decided to decline.

[Index](#index)

---

## SVC Table

At `$040180`, fixed, append only - never reorder.

| Address | Name | Contract |
|---|---|---|
| `+00` | `svc_version` | → `HL` = SVC table version |
| `+04` | `svc_pmsg` | `HL` = null-terminated string |
| `+08` | `svc_alloc` | `BC` = bytes → `HL` in segment `$04`, carry set if it will not fit |
| `+0C` | `svc_alloc0` | `BC` = bytes → `HL` in CP/M bank 0, for anything the BDOS must reach with a 16-bit address |
| `+10` | `svc_chook` | `HL` = device block → `A` = device number |
| `+14` | `svc_conout` | `A` = character |
| `+18` | `svc_conin` | → `A` = character |
| `+1C` | `svc_const` | → `A` = `$FF` if a character waits |
| `+20` | `svc_mosenter` | `MBASE` = 0, before a MOS call |
| `+24` | `svc_mosleave` | `MBASE` back to the CP/M bank |
| `+28` | `svc_dhook` | `HL` = drive block → `A` = drive number |

Unused slots up to `+7C` jump to a handler that returns an error, so calling a service this system does not have fails cleanly.

MOS calls. `MBASE` holds the CP/M bank while CP/M is running, so any MOS call a driver makes must be bracketed:

```
    call    svc_mosenter
    ld      a, mos_function
    rst.lil $08
    call    svc_mosleave
```

[Index](#index)

---

## Character Devices (svc_chook)

`HL` points at a block in segment `$04`:

```
+00  6 bytes  name, space padded
+06  db       mode byte    (System Guide Table 4-7, or modebaud.lib)
+07  db       baud byte
+08  dl       input routine     -> A = character
+0B  dl       output routine    A = character
+0E  dl       input status      -> A = $FF if ready
+11  dl       output status     -> A = $FF if ready
```

Returns `A` = the device number CP/M will know it by, carry clear; carry set if no slot is free. `MAXFIDDEV` in `cpm3.asm` is 4, and `NFIDDEV` in `agonchr.asm` reserves the same number of `@ctbl` slots. The BIOS passes its own figure in the descriptor and the supervisor takes the smaller of the two, so a mismatch costs devices rather than overrunning the table.

Dispatch: `?ci`, `?co`, `?cist` and `?cost` in `agonchr.asm` handle device numbers below the built-in count themselves; anything at or above it gates to `g$fidcio` with the operation in `A` and the device in `B`. The supervisor looks the device up and calls the driver's handler. An unclaimed number reports not ready and discards output, which is what the UART stubs already do.

The `@ctbl` entry is written into both bank copies of common. Common memory exists as two physical copies, and only the registered mutable region is carried across on a bank switch - and then only in the direction of travel. Writing one copy would make correctness depend on which bank happened to be current when the driver installed itself.

[Index](#index)

---

## Disc Drives (svc_dhook)

`HL` points at a 32-byte block in segment `$04`:

```
+00  db  drive     0 = A: through 15 = P:, or $FF for the first free
                   letter at or above the automatic floor
+01  db  unit      relative drive number the driver wants to see
+02  db  flags     reserved, must be zero
+03  17 bytes      the DPB, BY VALUE
+14  dl  read      handler addresses, 24-bit, in segment $04,
+17  dl  write     IN OPERATION ORDER
+1A  dl  login
+1D  dl  init
```

Returns `A` = the drive number, carry clear; carry set with `A` holding a `DRV_` reason code otherwise.

Everything a drive needs - allocation vector, BCBs, buffers, XDPH, the `@dtbl` entry - is already built by `drvnew_core`, which mounts C: through J: on every boot. Three things separate that from a driver being able to use it.

### The DPB has to be in common memory

BDOS function 31 returns the DPB address to the calling program, which runs in bank 1 - `bdos30.asm`, `func31`, is `call curselect / lhld dpbaddr / shld aret`. A DPB in bank 0 would leave `SHOW`, and anything else asking a drive for its parameters, reading whatever bank 1 holds at that address.

C: through J: sidestep this by sharing one statically declared DPB, which is legitimate only because their geometry is identical. A driver's geometry is its own, and the supervisor has no common memory to hand out - GENCPM owns all of it.

So `agondsk.asm` declares a fixed pool of DPB slots in the BIOS's CSEG, which is common:

```
NDPBSLOT equ    4
dpb$pool:
        ds      17*NDPBSLOT
```

`svc_dhook` takes a slot and copies the driver's DPB into it, in both bank copies, for the same reason `@ctbl` is written twice.

Measured cost: the pool takes 68 bytes of the resident BIOS CSEG, which stands at 960 bytes of the 1,024 in its four-page SPR allocation, so the TPA does not move. The 64 bytes left over hold three more slots - seven in all - before the boundary shifts and takes a page of TPA with it. `NDPBSLOT` may be raised that far, but check DRLINK's `CODE SIZE` and GENCPM's report afterwards.

### The handlers cannot go in an XDPH

An XDPH holds four sixteen-bit addresses that the kernel reaches with `PCHL`, so whatever it names must be Z80 code in bank 0. A driver's handlers are twenty-four-bit addresses in segment `$04` and cannot go there at all.

So every FID drive's XDPH names one shared set of four stubs in `agondsk.asm` - `fid$read`, `fid$write`, `fid$login`, `fid$init`. Each gathers the BDOS parameters and gates to `g$fiddio`, which maps the drive to the right driver. It is the same shape as `?ci`/`?co` reaching `g$fidcio`.

The stubs pass:

```
A  = operation: 0 read, 1 write, 2 login, 3 init
B  = @adrv, the absolute drive
C  = @rdrv, the relative drive
HL = the nine-byte parameter block, for read and write
```

The absolute drive travels in `B` rather than in the block because the nine-byte block is the same shape `g$dread` and `g$mio` already use, and all three are copied with one length. `bioskrnl.asm` sets both `@adrv` and `@rdrv` before every entry these stubs serve - `seldsk` before LOGIN, `d$init$loop` before INIT, `rw$common` before READ and WRITE - so both are valid in all four.

The supervisor keeps handlers in a table indexed straight by drive letter: sixteen entries of twelve bytes, 192 bytes of segment `$04`. That is cheaper than the code a map would need and has no failure mode. A zero entry means no driver owns that drive, and reports a permanent error rather than jumping through it.

### `drvnew_core` has to be reachable from a driver

`_g_drvnew` copies its request block out of the current CP/M segment, and `cur_seg` names bank 0 or bank 1 and nothing else - it cannot reach a block a driver built in segment `$04`.

So the routine is split: `_g_drvnew` is a gate front end that does the copy, and `drvnew_core` does the work from `dreq` and returns with a plain `RET` so it can be called from ADL-mode code. `svc_dhook` fills `dreq` itself and calls the core. There is one implementation of the drive-building logic.

### Drive Letters

```
FIRSTDYN  equ  3     first dynamic drive, D:
NDYNDRV   equ  10    one past the last, J:
FIRSTAUTO equ  10    first letter a driver may be given automatically, K:
```

`drvnew_core` decides a letter is free by finding a zero `@dtbl` entry - and A: and B: are zero. They are held for floppies by intention. Without a floor, the first driver to ask for "any free drive" would silently be handed A:.

So:

- `drive` = 0–15 - that exact letter, refused with `DRV_BADPARM` if it is already in use. A real floppy driver still gets A: this way, bypassing the floor entirely.
- `drive` = `$FF` - scan upward from `FIRSTAUTO`, refused only if nothing at all is free.

The floor is passed to the supervisor in the descriptor, so the policy is stated once, in the module that owns the drive map.

### What the driver's handlers receive

All four are called with `HL` pointing at a nine-byte block in segment `$04`:

```
+00  db  unit      the relative drive
+01  dw  track
+03  dw  sector
+05  dl  dma       a FULL 24-BIT ADDRESS
+08  db  count     records to transfer, always 1
```

Only `+00` is meaningful for login and init. Each returns `A` = 0 for success, non-zero for a permanent error.

The DMA bank is resolved by the supervisor, not the driver. A driver has no business knowing that CP/M banks are eZ80 segments, and `bank_map` is not exported to it. What it gets is a finished address it can `LDIR` to or from, which also means a driver written today keeps working if that mapping ever changes.

The resolved block is the same nine bytes rather than a larger one: a two-byte DMA address plus a one-byte bank is three bytes at `+05`, and a 24-bit address is three bytes at `+05`. Only the *meaning* of `+07` changes, so the block is copied whole and one byte is rewritten.

### Two rules a driver's DPB must obey

- `CKS` must have bit 15 set - the medium must be permanently mounted. A removable one needs a checksum vector, and there is no common memory left to allocate one from. `drvnew_core` enforces this.
- `PSH`/`PHM` of 0 mean 128-byte physical records and no data deblocking buffer, which is the simplest thing to write. Larger physical records work and save transfers on a real device.

### Ordering at boot

`?init` runs `agon$newdrv`, mounting C:–J:, then `agon$fidinit`. Both are inside `?init`, and the kernel walks `@dtbl` and calls each drive's `init` immediately after `?init` returns - so a drive added by a driver is initialised along with the rest, with no special case.

A driver must not format its medium in `init`. The kernel calls `init` from BOOT, and BOOT runs on every warm start, so anything written there is written again each time a program exits. One-time work belongs in the entry routine, which runs once.

[Index](#index)

---

## The two descriptors

At `?init` the BIOS hands the supervisor a description of itself.

```
; agonchr.asm                     ; agondsk.asm
fid$desc:                         fid$ddesc:
    dw  @ctbl        ; +0             dw  @dtbl       ; +0
    db  NBUILTIN     ; +2             dw  dpb$pool    ; +2
    db  NFIDDEV      ; +3             db  NDPBSLOT    ; +4
    dw  fid$ddesc    ; +4             db  FIRSTAUTO   ; +5
                                      dw  fid$write   ; +6
                                      dw  fid$read    ; +8
                                      dw  fid$login   ; +10
                                      dw  fid$init    ; +12
```

Two rather than one, because RMAC cannot import an equate from another module. The character counts are equates in `agonchr.asm`, and the slot count and drive floor are equates in `agondsk.asm`, so each descriptor is assembled in the module that owns its numbers, with one pointer between them.

Both copy lengths in `_g_fidinit` must match the blocks they read - six bytes and fourteen bytes.

[Index](#index)

---

## Worked examples

`upper.asm` → `UPPER.FID` - a character device that folds console input to upper case. The model for a character driver.

`ramd.asm` → `RAMD.FID` - a 32K RAM disc on K:, carved from the FID heap with `svc_alloc`. The model for a disc driver: a complete, working one small enough to read in a sitting. It arrives formatted and empty, so `DIR K:` reports no file and the drive is ready to be written to.

`RAMD` makes no MOS calls, needs no image format and does not touch M:, so nothing in it distracts from the interface it demonstrates. It also exercises the branch a card drive does not: `PSH`/`PHM` of 0 mean `drvnew_core` gives it no data deblocking buffer, as it does for M:.

Its geometry, checked against the System Guide:

```
SPT=32  BSH=3  BLM=7  EXM=0  DSM=31  DRM=31
AL0=80h AL1=0  CKS=8000h  OFF=0  PSH=0  PHM=0
```

- BLS 1024 → BSH 3, BLM 7 (Table 3-4)
- BLS 1024 with DSM < 256 → EXM 0 (Table 3-5)
- BLS 1024 → DSM must be ≤ 255
- 32 directory entries = 1024 bytes = one block → AL0 = `80h`
- DRM ≤ (BLS/32 × 16) − 1 = 511

`rd_format` fills the whole allocation with `E5`, which is what an empty CP/M directory is, so the drive is usable the moment it is hooked. All 32 blocks are free, so copying a file onto it exercises the write path.

`ramd.asm` also carries a `mod_end` guard. A driver handed a block that overlapped its own image would fill 32K with `E5` starting inside itself, overwriting the `LDIR` doing the filling. Six instructions turn that into a driver that declines and says so.

[Index](#index)

---

## Diagnostics

Two compile-time switches trace the mechanism, both shipped at 0, and with them off not one byte remains.

- `FIDDIAG` in `cpm3.asm` - traces drive hooking and dispatch: `FID: drive K dpb 0/4 ok`, `FID: io K0`.
- `RDDIAG` in `ramd.asm` - stage markers through the driver's entry routine: `RD1`, `RD2=` and the allocated address, `RD3`, `F1`, `RD4`, `RD5`. Each is printed *after* the step it names, so the last marker on screen is the last step that worked.

Both sets of helpers preserve every register and the flags, so a marker can sit between a computation and its use without changing what is being measured.

[Index](#index)

---

## Building

```
ez80asm cpm3.asm -l -s
cpm.py RMAC.COM AGONDSK.ASM            # and any other changed module
cpm.py DRLINK.COM "BNKBIOS3[B]=BIOSKRNL,AGONBNK,AGONCHR,AGONDSK,AGONINI,SCB"
cpm.py GENCPM.COM AUTO
python3 mkfid.py ramd.asm RAMD.FID
```

Copy `cpm3.bin`, `cpm3.sys` and the `.FID` files to the SD card. `cpm3.bin` and the drivers must be built from the same source tree - a mismatched pair is not detected and will not behave.

### Toolchain notes

- RMAC ignores `$` in symbols and truncates externals to six significant characters. `dec$tab` and `dectab` are one symbol. Check any new `agon$`- or `dpb$`-prefixed public name.

- RMAC silently skips blocks with LF line endings. CP/M-side sources are CRLF; `cpm3.asm`, `fid.inc` and the drivers are LF. An editor that inserts the wrong ending will make a module assemble to a plausible size with lines missing and no error. Check the module size changed after an edit.

- In DR assemblers `!` is a statement separator that terminates a comment, so `; mov a,e ! ani 1` assembles the second half.

- `ld d,h / ld e,l` copies 16 bits; `LDIR` in ADL mode uses 24. Use `push hl / pop de`.

- DRLINK needs `[B]`, and `SCB.REL` must be in the link. `SCB.ASM` defines `@civec` and the rest as absolute equates on page `0FEh`; the linker marks them page relocatable, and GENCPM repoints them at the real SCB in the BDOS.

- Read GENCPM's output rather than skimming it. It reports allocation failures, and a missing input file, without aborting - a missing `BNKBDOS3.SPR` produces a 256-byte `CPM3.SYS` and a cheerful success message.

[Index](#index)
