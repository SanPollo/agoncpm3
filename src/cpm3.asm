; =============================================================================
;  cpm3.asm -- ADL-mode supervisor for CP/M 3 on the Agon Light
; =============================================================================
;
; (c) 2026 Nick J. Date. Released under the MIT Licence. See the accompanying
; LICENSE file for details.
;
; Portions derived from Agon CPM 2.2 by Aleksandr Sharikhin (nihirash).
;
; If you like this project, please consider buying Aleksandr a coffee:
; https://ko-fi.com/D1D6JVS74 and make sure you credit him in any derivatives.
;
; CP/M 3 code:
;     Copyright (C) 1978-1982 Digital Research, Inc.
;
; CP/M and its derivatives are used and distributed under the
; CP/M Licence 2022, with permission granted by DRDOS, Inc.,
; successor in interest to Digital Research.
;
;
; CP/M 3 itself runs as plain Z80 code inside a 64K MBASE segment.  This
; program is the other half: it lives in segment $04 in ADL mode and provides
; everything the Z80 side cannot reach for itself -- MBASE changes, 24-bit
; block moves, and hardware access.
;
; The Z80 side calls in through the fixed gate table at $040100 using the
; encoding UM0077 gives for a call issued from Z80 mode with a 24-bit target
; (52 CD nn mm MM).  Per Table 49 that puts the return address on the SPL
; stack, not the Z80-mode stack, which is what makes it safe for a gate to
; change MBASE before returning.
;
; MEMORY MAP
;   $040000-$04FFFF  segment $04, divided as:
;       $040000-...      this supervisor, up to image_end
;       ...              the CCP buffer, CCP_MAX (8K) bytes
;       ...  -$04FFFF    the FID heap, whatever is left
;     The two boundaries move with the size of this file, so they are
;     derived from image_end rather than written down here.  The current
;     figures are printed by the build.
;   $050000-$05FFFF  CP/M bank 1  -- the TPA
;   $060000-$06FFFF  CP/M bank 0  -- system bank
;   $070000-$0BBFFF  M: RAM drive, 311296 bytes
;   $0BC000-$0BFFFF  MOS -- DO NOT TOUCH (see below)
;
; The figures above are taken from MOS 3.0.2's own *MEM command run on a
; stock Agon Light 2, not inferred:
;
;   ROM      &000000-&01ffff  82% used
;   USER:LO  &040000-&0bbfff  507904 bytes
;   MOS:DATA &0bc000-&0bcbd4    3029 bytes
;   MOS:HEAP &0bcbd5-&0bf7ff   11307 bytes
;   STACK24  &0bf800-&0c0000    2048 bytes
;   USER:HI  &b7e000-&b7ffff    8192 bytes
;
; Two things follow from that, and both matter here:
;
; 1. The external 512K of RAM is at $040000-$0BFFFF, NOT $000000-$07FFFF.
;    $000000-$03FFFF is on-chip flash holding MOS itself.  cstartup's cold
;    boot wipe in agon-mos-3.0.2/src_startup/init_params_f92.asm confirms
;    it: "ld hl,40000h / ld bc,80000h-1 / ldir".  So segments $07-$0A are
;    real RAM on a stock board, and $0B0000-$0BBFFF is a further 48K.
;
; 2. $0BC000 is a HARD FLOOR.  MOS's static data, heap and stack live above
;    it, and they back the file API this supervisor calls -- mos_fopen,
;    mos_fread, mos_fwrite, mos_flseek -- on every transfer to every
;    SD-card drive, for the whole life of the CP/M session.  Reclaiming it
;    because "CP/M never returns to MOS" would break C: -- the boot drive --
;    on the next disk access.  The RAM drive stops at $0BBFFF for that
;    reason.
;
; The tail of segment $04 above this supervisor's own code and variables was
; held back rather than given to M:, and it is now spoken for: the CCP buffer
; sits immediately above image_end, and everything above THAT is the FID heap
; that loadable drivers are loaded into and allocate from.  M: still stops at
; $0BBFFF and is unaffected by anything that happens up here, which is why
; growing this file costs FID heap and nothing else.
;
; BUILD
;   ez80asm cpm3.asm -l -s
;   Requires ez80asm 2.0+.  Source must be CRLF-free; ez80asm is relaxed
;   about line endings, unlike RMAC.
;
; STATUS
;   Working, and confirmed on hardware.  The system loads CPM3.SYS and
;   CCP.COM from the SD card and boots banked CP/M 3 to a C> prompt with a
;   62,214-byte TPA.  Implemented and exercised: bank switching, cross-bank
;   block moves, console I/O, the .dsk image drives on C: to J: (read and
;   write), the M: RAM drive, warm boot, the ?time clock in both directions,
;   and the FID loadable driver mechanism for both character devices and
;   whole disc drives.
;
;   Known gaps, all documented at the point they occur:
;     - DATE SET moves CP/M's own clock but is not written back to the VDP,
;       so it does not survive a reset.  See the note by the RTC section:
;       on a stock machine a reset clears the VDP's clock too, so there is
;       nothing to preserve until a battery backup module is fitted.
;     - The two gates at +44 and +48 are RETIRED, not spare.  See the block
;       marked "RETIRED" further down.
;     - Serial character I/O is not wired up; see the stubs in agonchr.asm.
;
;   README.md is the project overview and FID.md is the driver author's
;   reference.
; =============================================================================

; ------------------------------------------------------------------ constants

SEG_SUP:        .equ    $04 ; this supervisor
SEG_BANK1:      .equ    $05 ; CP/M bank 1, the TPA
SEG_BANK0:      .equ    $06 ; CP/M bank 0, system bank

MAXFRAG:        .equ    8   ; mutable common fragments we can track

; UART0 -- the link to the VDP.  The CP/M 2.2 port drives these registers
; directly rather than going through MOS's console, which avoids MOS's
; interrupt-driven keyboard handling entirely.  Same approach here.
UART0:          .equ    $C0
REG_RBR:        .equ    UART0+0         ; receive buffer
REG_THR:        .equ    UART0+0         ; transmit holding
REG_IER:        .equ    UART0+1
REG_FTC:        .equ    UART0+2
REG_LSR:        .equ    UART0+5
LSR_RDY:        .equ    $01 ; receive data ready

; MOS's own UART0_serial_TX (agon-mos/src/serial.asm) polls THIS bit --
; UART_LSR_ETH, $20, "transmit holding register empty" -- not the confusingly
; similarly-named UART_LSR_ETX ($40, "transmit empty" / TEMT, meaning the
; shift register has gone fully idle, not just that the next byte can be
; loaded).  The CP/M 2.2 port polls $40, and I copied that uncritically.
; MOS's own working code is the trustworthy reference: use $20.
LSR_ETH:        .equ    $20 ; transmit holding register empty
TX_WAIT:        .equ    16384           ; matches MOS's own TX_WAIT bound;
    ; an unbounded wait on a bit that
    ; never sets is a silent, permanent
    ; hang with no panic

; --- REAL-TIME CLOCK -----------------------------------------------------
;
; The Agon's clock lives on the ESP32, inside the VDP, and the only way to
; reach it is to ask the VDP.  Once CP/M is running that is impossible: the
; VDP is in fabgl terminal emulation mode, and agon-vdp's video.ino, in
; processTerminal case TerminalState::Enabled, hands every byte we send
; straight to Terminal->write().  processor->processNext() is never reached,
; so the VDU interpreter never sees a request and no reply is generated.
;
; MOS cannot help either, for a second and independent reason.  mos_getrtc
; calls rtc_update() (clock.c), which sends the request and then waits on
; wait_VDP(0x20) for MOS's UART0 receive interrupt to set bit 5 of
; vpd_protocol_flags.  console_init turns that interrupt off.  The flag can
; never be set, so the call would spin out its timeout every time.
;
; THE CLOCK IS THEREFORE READ EXACTLY ONCE, DURING STARTUP, BEFORE
; console_init.  At that point nothing is in the way: MOS's UART interrupt is still armed,
; vdp_protocol is still running, and a refresh behaves exactly as it does at
; the MOS prompt.  From then on the time is carried forward by counting
; VBLANK interrupts, which is what the System Guide expects anyway:
;
;   "This entry point is for systems that must interrogate the clock to
;    determine the time.  Systems in which the clock is capable of generating
;    an interrupt should use an interrupt service routine to set the Time and
;    Date fields on a regular basis."     -- System Guide 3.4.5
;
; We do the second of those, just lazily: the counter runs on the interrupt,
; and the SCB is brought up to date when the BDOS asks rather than on every
; tick.
;
; The Agon's clock is kept by the VDP and is not battery backed, so unless
; the user sets it the date restarts from the same value at every power on.
; That is a property of the machine, not of this code.

; MOS system variables.  mos_api_sysvars is "LD IX,_sysvars / RET"
; (mos_api.asm line 562) -- two instructions, no VDP traffic, no interrupts --
; so it is safe to call at any point.  The pointer is fetched once at startup
; and cached; _sysvars is an absolute 24-bit address, so it stays valid
; whatever MBASE is set to afterwards.
mos_sysvars:    .equ    $08
mos_unpackrtc:  .equ    $23 ; HL = buffer, C = flags.  Bit 0 refreshes
    ; the cached clock before unpacking.
SYSVAR_TIME:    .equ    $00 ; 4 bytes: centisecond counter (_clock)
SYSVAR_RTC:     .equ    $1A ; 6 bytes: the raw clock packet

; TICKS_PER_SEC -- how many counts of _clock make one second.
;
; _vblank_handler in MOS's interrupts.asm adds TWO to _clock on every VBLANK,
; and every video mode in agon-vdp's agon_screen.h is 60Hz, so the counter
; advances 120 per second.  It is described in MOS as centiseconds, which
; assumes 50Hz; on this machine it therefore GAINS, running 1.2 times real
; time.  Dividing by 120 rather than by 100 is the whole of the correction --
; there is no separate fudge factor anywhere below.
;
; VGA 640x480 is nominally 59.94Hz rather than 60.00, and had the Agon used
; the standard timings this would run about 0.1% fast -- roughly a minute and
; a half a day.  It does not: measured against an external clock, a CP/M
; session and the reference still agree after thirty minutes, where 59.94Hz
; against an assumed 60.00 would have drifted about two seconds.  120 is the
; constant to trim if a machine is ever found that disagrees.
TICKS_PER_SEC:  .equ    120

GATE_BASE:      .equ    $040100         ; must match agon.lib

; --- FIELD INSTALLABLE DEVICE DRIVERS -----------------------------------
;
; A FID is an ADL-mode eZ80 module loaded into the free tail of segment
; $04 and reached through the SVC table below.  It is NOT a Z80 or PRL
; module in a CP/M bank, and that is not a stylistic choice:
;
;   - The BIOS kernel's character I/O lives in COMMON memory and runs in
;     whichever bank happens to be current.  bioskrnl.asm's conout,
;     out$scan, coster and in$scan are all inside its CSEG.  A driver
;     body in bank 0 would therefore be unreachable whenever a transient
;     program in bank 1 wrote to the console, and bank-switching per
;     character would mean copying the mutable common region twice for
;     every byte.
;
;   - Any real driver on this machine needs MOS or hardware access, which
;     needs ADL mode, which means segment $04 regardless.
;
; The SVC table is at a FIXED address for the same reason the gate table
; is: a FID calls it by absolute address, so those calls need no
; relocation.  Only the FID's references to its own code and data are
; fixed up at load time.
SVC_BASE:       .equ    $040180         ; SVC jump table, fixed address
SVC_SLOTS:      .equ    32  ; 4 bytes each -> $040180-$0401FF
FID_API:        .equ    1   ; SVC table version

; FID file header, 32 bytes.  Shapes chosen to be readable in a hex dump.
FIDH_LEN:       .equ    32
FIDH_SIG:       .equ    4   ; 'AGONFID1', 8 bytes
FIDH_LINK:      .equ    12  ; origin the image was assembled at
FIDH_IMAGE:     .equ    15  ; bytes of code+data
FIDH_BSS:       .equ    18  ; bytes to zero above the image
FIDH_RELOC:     .equ    21  ; offset of the fixup table
FIDH_RCNT:      .equ    24  ; number of fixups
FIDH_APIV:      .equ    27  ; SVC table version required
FIDH_SUM:       .equ    29  ; 16-bit sum of the file

MAXFIDDEV:      .equ    4   ; character devices a FID may add.
    ; @ctbl in agonchr.asm reserves the
    ; same number of slots; the two must
    ; agree and the BIOS passes its own
    ; figure so a mismatch is caught.

NDRIVELET:      .equ    16  ; A: through P:.  The drive-to-driver
    ; table is indexed straight by drive
    ; letter rather than through a map:
    ; sixteen entries of twelve bytes is
    ; 192 bytes of segment $04, which is
    ; cheaper than the code a map would
    ; need and has no failure mode.

; --- DIAGNOSTICS ---------------------------------------------------------
;
; Supervisor code cannot be run anywhere but on the machine itself, so the
; tracing below is built in rather than added when something fails.
;
; With FIDDIAG at 0 not one byte of it remains in the assembled image.
;
; Every diagnostic is placed where it CANNOT DISTURB WHAT IT MEASURES: the
; helpers preserve all registers and the flags, and a marker is never put
; between a computation and its use.
FIDDIAG:        .equ    0   ; 1 = trace drive hooking and dispatch

CCP_MAX:        .equ    $2000           ; 8K ceiling; the CP/M 3 CCP is ~3K

; CCP_STORE is declared as ordinary storage at the end of this file rather
; than as a fixed .equ, which puts it in segment $04 at an address the
; assembler picks.  An 8K buffer sits comfortably inside this supervisor's
; own 64K segment, with no hand-chosen address to keep in step with the
; M: RAM drive or with anything else.

; --- M: RAM drive ---
;
; See the memory map at the top of this file for where these bounds come
; from.  RAM_TOP is exclusive: the last usable byte is RAM_TOP-1.
RAM_BASE:       .equ    $070000         ; first byte of the RAM drive
RAM_TOP:        .equ    $0BC000         ; first byte of MOS's data -- keep off
RAM_SIZE:       .equ    RAM_TOP-RAM_BASE ; $4C000 = 311296 bytes
RECSIZE:        .equ    128 ; M: transfers 128-byte records
SPT_RAM:        .equ    128 ; records per track, must match the
    ; SPT field of agonm$dpb in agondsk.asm

; --- M: directory ---
;
; A CP/M directory entry is free only when its first byte is 0E5h.  Any
; other value is an entry the BDOS will not hand out, so a drive whose
; directory has never been written contains no free entries at all: DIR
; shows nothing and the first write fails with no directory space.
;
; A: gets its 0E5h fill from cpmtools when the image is built.  M: has no
; image and no equivalent, and CP/M 3 ships no format utility, so the
; supervisor does it -- see format_m.
;
; Size is taken straight from agonm$dpb in agondsk.asm: DRM = 511, so there
; are 512 entries of 32 bytes = 16384 bytes, which is eight 2048-byte
; blocks -- exactly what AL0 = 0FFh in that DPB reserves.
;
; THESE MUST BE CHANGED TOGETHER WITH DRM AND AL0 IN agondsk.asm.
M_DIRENTS:      .equ    512 ; DRM + 1
M_DIRSIZE:      .equ    M_DIRENTS*32    ; 16384 bytes at the base of the drive
DIR_FREE:       .equ    $E5 ; CP/M's "entry unused" marker

; MOS API calls used by the loader
mos_fopen:      .equ    $0A
mos_fclose:     .equ    $0B
mos_fread:      .equ    $1A
mos_fwrite:     .equ    $1B
mos_flseek:     .equ    $1C
ffs_dfindfirst: .equ    $94 ; HL = DIR, DE = FILINFO, BC = path,
    ; IX = pattern.  A = FRESULT.
ffs_dfindnext:  .equ    $95 ; HL = DIR, DE = FILINFO.  A = FRESULT.
ffs_getcwd:     .equ    $9E ; HL = buffer, BC = its size.
    ; A = FRESULT.

; FatFS structure layout, taken from the FILINFO and DIR definitions MOS
; publishes for assembler callers in src/mos_api.inc.  Not guessed: those
; .STRUCT blocks are the authority, and they mirror src_fatfs/ff.h.
FI_ATTRIB:      .equ    8   ; fsize(4) + fdate(2) + ftime(2)
FI_FNAME:       .equ    22  ; ... + fattrib(1) + altname(13)
AM_DIR:         .equ    $10 ; fattrib bit for a subdirectory

; THESE TWO ARE DELIBERATELY LARGER THAN MOS PUBLISHES.
;
; mos_api.inc gives DIR_SIZE as 46 and FILINFO_SIZE as 278.  But its DIR
; omits the "pat" pointer that ff.h declares under FF_USE_FIND, and MOS's
; own ffconf.h sets FF_USE_FIND to 1 -- so the structure the compiler
; actually lays out is three bytes longer than the one the include file
; describes, and f_findfirst writes to that field.  Allocating to the
; published size would let MOS scribble on whatever came next.
;
; Over-allocating costs nothing here and cannot be wrong in the dangerous
; direction, so both are rounded well past any plausible layout.
DIRBUF_SIZE:    .equ    64  ; MOS says 46, ff.h implies 49
FINFO_SIZE:     .equ    320 ; MOS says 278
fa_read:        .equ    $01 ; FA_READ
fa_write:       .equ    $02 ; FA_WRITE

; --- bank-0 heap ---
;
; GENCPM allocates directory buffers, data buffers and hash tables from the
; bottom of the memory segment declared by MEMSEG00, upward.  gencpm.plm's
; get$space computes each address as
;
;   base*256 + (len*256 - attr)
;
; with attr counting down from the full length, so the first buffer lands at
; the segment base and later ones follow it.  MEMSEG00 declares base 00, so
; GENCPM's buffers grow upward from 0000 in bank 0.
;
; Measured on the generated system as it stands: A: takes a 512-byte directory
; buffer at 0000-01FF and M: a 128-byte one at 0200-027F.  A: also has a data
; deblocking buffer, but GENCPM was told to keep buffers in common and put it
; at FD06, out of bank 0 altogether.
;
; HEAP0_BASE is therefore set well clear of that at 1000h, leaving 3.5K of
; headroom -- room for seven more 512-byte buffers before anything GENCPM
; allocates could reach the heap.  IT IS NOT DERIVED, IT IS CHOSEN, so it has
; to be rechecked whenever a drive is added that GENCPM gives its own buffers
; to.  Drives that share A:'s buffers cost nothing here.
;
; The ceiling is derived rather than chosen: the banked system's base is
; bnk_top - bnk_len*256, both of which come out of the CPM3.SYS header, so
; the heap automatically shrinks if the banked region grows downward.
HEAP0_BASE:     .equ    $1000

; _g_drvnew return codes
DRV_OK:         .equ    0
DRV_BADPARM:    .equ    1   ; drive out of range, or already present
DRV_NOIMAGE:    .equ    2   ; image file would not open
DRV_NOROOM:     .equ    3   ; bank-0 heap exhausted
DRV_NOTPERM:    .equ    4   ; CKS asks for a checksum vector
DRV_NODPB:      .equ    5   ; DPB pool exhausted.  Only svc_dhook can
    ; raise this: the drives the BIOS installs
    ; itself share agon$dpb0 and take no slot.

SPT_PHYS:       .equ    16  ; 512-byte physical sectors per track,
    ; matching SPT=64 records in the DPB
    ; (nihirash geometry: 64 records of
    ; 128 bytes = 8192 bytes per track,
    ; which is 16 sectors of 512)
SECSIZE:        .equ    512 ; physical sector size
NDRIVES:        .equ    16  ; highest relative drive number plus
    ; one -- the range of units drv_open
    ; will accept.  NOT a count of open
    ; files: only one image is open at a
    ; time, so this costs nothing beyond a
    ; bounds check.
    ;
    ; Drive letter, relative drive number
    ; and image letter are all the same
    ; value.  Unit 2 is C: and opens
    ; cpmc.dsk; unit 9 is J: and opens
    ; cpmj.dsk.  Nothing has to remember an
    ; offset between them.
    ;
    ; This is unrelated to
    ; MOS_maxOpenFiles: the open-file limit
    ; is respected by construction, because
    ; the disk driver never holds more than
    ; one handle at a time.

    macro   MOSCALL func
    ld      a, func
    rst.lil $08
    endmacro

    .assume adl = 1
    .org    $040000

    jp      _start
    .align  64
    .db     "MOS"
    .db     0
    .db     1

; =============================================================================
;  GATE TABLE
; -----------------------------------------------------------------------------
;  Fixed address, fixed order.  agon.lib on the Z80 side hard-codes these
;  offsets, so entries may only ever be appended, never reordered or removed.
;  Each entry is a 4-byte ADL-mode JP.
; =============================================================================

    .org    GATE_BASE
g_bank:         jp      _g_bank         ; +00  A = CP/M bank number
g_move:         jp      _g_move         ; +04  HL=dst DE=src BC=count
g_xmove:        jp      _g_xmove        ; +08  B=dst bank C=src bank
g_conout:       jp      _g_conout       ; +0C  C = character
g_conin:        jp      _g_conin        ; +10  -> A = character
g_const:        jp      _g_const        ; +14  -> A = $FF if ready
g_time:         jp      _g_time         ; +18  C = 0 get, $FF set
g_dread:        jp      _g_dread        ; +1C  HL = parameter block
g_dwrite:       jp      _g_dwrite       ; +20  HL = parameter block
g_dlogin:       jp      _g_dlogin       ; +24  C  = relative drive
g_ldccp:        jp      _g_ldccp        ; +28  copy the CCP into the TPA
g_setcom:       jp      _g_setcom       ; +2C  HL=start DE=len
g_mio:          jp      _g_mio          ; +30  HL = parameter block, A = dir
g_drvnew:       jp      _g_drvnew       ; +34  HL = drive request block
g_fidinit:      jp      _g_fidinit      ; +38  HL = BIOS descriptor block
g_fidcio:       jp      _g_fidcio       ; +3C  A = operation, B = device
g_fiddio:       jp      _g_fiddio       ; +40  A = operation, B = @adrv,
    ;      C = @rdrv, HL = parm block
; +44 and +48 are RESERVED, NOT SPARE.  They belonged to g$rtcraw and
; g$esptime, which supported GETDATE.COM and CHCKDATE.COM; see the block
; marked "RETIRED" further down for what they did and how to bring them
; back.  The two entries stay here as RET so that every offset below +44
; keeps its value and nothing downstream shifts -- and so that a future
; gate is given +4C rather than silently reusing an offset that a stale
; .FID or a stale utility might still call.
g_rtcraw:       ret
    .db     0, 0, 0                 ; pad to the table's 4-byte stride
g_esptime:      ret
    .db     0, 0, 0


; =============================================================================
;  SVC TABLE -- THE FID SIDE OF THE INTERFACE
; -----------------------------------------------------------------------------
;  Fixed address, fixed order, append only, exactly like the gate table above.
;  A FID calls these by absolute address, so they need no relocation; only a
;  FID's references to its own code and data are fixed up when it is loaded.
;
;  The Amstrad PCW solved the same problem by planting relocation markers in
;  the driver image so its loader could patch SVC addresses in.  A fixed table
;  is simpler and cheaper, and this machine has the address space to spare.
;
;  Unused slots point at svc_bad, which returns carry set, so a FID built
;  against a later API that calls a service this system does not have gets a
;  clean failure instead of a jump into whatever follows.
; =============================================================================

    .org    SVC_BASE
svc_version:    jp      _svc_version    ; +00  -> HL = API version
svc_pmsg:       jp      _svc_pmsg       ; +04  HL = string in segment $04
svc_alloc:      jp      _svc_alloc      ; +08  BC = bytes -> HL in segment $04
svc_alloc0:     jp      _svc_alloc0     ; +0C  BC = bytes -> HL in bank 0
svc_chook:      jp      _svc_chook      ; +10  HL = device request block
svc_conout:     jp      _svc_conout     ; +14  A = character, to the VDP
svc_conin:      jp      _svc_conin      ; +18  -> A = character
svc_const:      jp      _svc_const      ; +1C  -> A = 0FFh if ready
svc_mosenter:   jp      _svc_mosenter   ; +20  MBASE = 0 for a MOS call
svc_mosleave:   jp      _svc_mosleave   ; +24  MBASE back to the CP/M bank
svc_dhook:      jp      _svc_dhook      ; +28  HL = drive request block
    ; --- unused slots ---
    jp      svc_bad         ; +2C
    jp      svc_bad         ; +30
    jp      svc_bad         ; +34
    jp      svc_bad         ; +38
    jp      svc_bad         ; +3C
    jp      svc_bad         ; +40
    jp      svc_bad         ; +44
    jp      svc_bad         ; +48
    jp      svc_bad         ; +4C
    jp      svc_bad         ; +50
    jp      svc_bad         ; +54
    jp      svc_bad         ; +58
    jp      svc_bad         ; +5C
    jp      svc_bad         ; +60
    jp      svc_bad         ; +64
    jp      svc_bad         ; +68
    jp      svc_bad         ; +6C
    jp      svc_bad         ; +70
    jp      svc_bad         ; +74
    jp      svc_bad         ; +78
    jp      svc_bad         ; +7C

svc_bad:
    scf
    ret

; =============================================================================
;  BANK SWITCHING
; =============================================================================

; -----------------------------------------------------------------------------
; _g_bank -- select CP/M bank <A> for processor execution.
;
; The whole difficulty of this port is here.  On a machine with overlapping
; banks this would be a port write; on the eZ80 the banks are entire 64K
; segments that cannot overlap, so "common" memory exists as two physical
; copies and the mutable part has to be carried across.
;
; Order matters: copy first, THEN set MBASE.  The RET.LIL at the end resumes
; Z80 execution at the same 16-bit offset in the NEW segment (UM0077 Table 83:
; the ending PC is {MBASE, PC[15:0]} using the current MBASE), and the caller's
; RET after that pops from the Z80-mode stack -- which by then is the new
; segment's copy.  If the stack had not been copied, that RET would return to
; whatever stale bytes happened to be there.
;
; Preserves BC, DE, HL.  Corrupts A.
; -----------------------------------------------------------------------------
_g_bank:
    push    hl
    push    de
    push    bc
    push    ix

    cp      2
    jr      nc, @done   ; only banks 0 and 1 exist

    ld      hl, bank_map
    ld      de, 0       ; 24-bit clear: see handle_addr
    ld      e, a
    add     hl, de
    ld      a, (hl)     ; A = target segment
    ld      hl, cur_seg
    cp      (hl)
    jr      z, @done    ; already selected: nothing to do

    ld      (new_seg), a
    call    copy_common ; cur_seg -> new_seg
    ld      a, (new_seg)
    ld      (cur_seg), a
    ld      mb, a       ; MBASE writable only in ADL mode
@done:
    pop     ix
    pop     bc
    pop     de
    pop     hl
    ret.lil ; resumes in the selected segment


; -----------------------------------------------------------------------------
; copy_common -- copy every registered mutable fragment from the segment named
; by cur_seg to the one named by new_seg.
;
; Phase 0 measured cross-segment LDIR at 5-6 MB/s with per-call overhead too
; small to detect: five block sizes moving the same total all took the same
; time.  That is why a fragmented mutable region costs no more than a
; contiguous one of the same total size, and why this loop is not a problem.
; -----------------------------------------------------------------------------
copy_common:
    ld      ix, frag_tbl
    ld      b, MAXFRAG
@loop:
    push    bc

    ld      de, (ix+3)  ; fragment length
    ld      hl, 0
    ld      (tmp_len), hl
    ld      (tmp_len), de
    ld      a, 0
    ld      (tmp_len+2), a          ; force BCU = 0
    ld      bc, (tmp_len)
    ld      a, b
    or      c
    jr      z, @end     ; zero length terminates the list

    ld      de, (ix+0)  ; fragment offset within a segment

    ld      (tmp_src), de
    ld      a, (cur_seg)
    ld      (tmp_src+2), a
    ld      (tmp_dst), de
    ld      a, (new_seg)
    ld      (tmp_dst+2), a

    ld      hl, (tmp_src)           ; LDIR is (DE) <- (HL):
    ld      de, (tmp_dst)           ; HL is the SOURCE, DE the DEST
    ldir    ; 2 bus cycles/byte in ADL mode

    lea     ix, ix+6
    pop     bc
    djnz    @loop
    ret
@end:
    pop     bc
    ret


; -----------------------------------------------------------------------------
; _g_setcom -- register a mutable common fragment.
;   HL = first byte (16-bit offset within a segment), DE = length in bytes.
;
; Calls APPEND rather than replace, so the BIOS can declare each fragment
; separately as it discovers them: the resident BDOS data block, the SCB page,
; the kernel's boot stack, and its own variables.  A length of zero is ignored.
;
; This must be called before the first bank switch.  Until it is, the fragment
; table is empty and _g_bank would switch without carrying anything across.
; -----------------------------------------------------------------------------
_g_setcom:
    push    ix
    push    bc
    push    de
    push    hl

    ld      a, e        ; ignore a zero-length request
    or      d
    jr      z, @out

    ld      ix, frag_tbl
    ld      b, MAXFRAG
@find:
    ld      a, (ix+3)   ; existing length low
    or      (ix+4)      ; existing length high
    jr      z, @store   ; free slot found
    lea     ix, ix+6
    djnz    @find
    jr      @out        ; table full -- silently ignore
; (see note in the write-up)
@store:
    ld      (ix+0), hl
    ld      (ix+3), de
@out:
    pop     hl
    pop     de
    pop     bc
    pop     ix
    ret.lil

; =============================================================================
;  BLOCK MOVES
; =============================================================================

; -----------------------------------------------------------------------------
; _g_xmove -- set the banks for the NEXT _g_move only.
;   B = destination bank, C = source bank.
;
; The BDOS uses this to shift data between the TPA and its buffers in bank 0.
; On this machine that is simply a copy between two segments and needs no
; processor bank switch at all, which is why cross-bank data movement is cheap
; here even though cross-bank execution is not.
; -----------------------------------------------------------------------------
_g_xmove:
    push    hl
    push    de

    ld      a, b
    call    bank_to_seg
    ld      (xm_dst), a
    ld      a, c
    call    bank_to_seg
    ld      (xm_src), a
    ld      a, 1
    ld      (xm_armed), a

    pop     de
    pop     hl
    ret.lil


; -----------------------------------------------------------------------------
; _g_move -- block move.  HL = destination, DE = source, BC = count.
;
; If _g_xmove has armed a cross-bank transfer the recorded segments are used
; and the arming is cleared; otherwise both ends are in the current segment.
; Returns HL and DE advanced past the last byte moved, as the BDOS expects.
; -----------------------------------------------------------------------------
_g_move:
    push    ix
    push    af

    ld      (tmp_dst), hl
    ld      (tmp_src), de
    ld      (tmp_len), bc
    ld      a, 0
    ld      (tmp_len+2), a          ; BCU = 0: count is 16-bit

    ld      a, (xm_armed)
    or      a
    jr      nz, @cross

    ld      a, (cur_seg); plain move, current segment
    ld      (tmp_dst+2), a
    ld      (tmp_src+2), a
    jr      @go
@cross:
    ld      a, (xm_dst)
    ld      (tmp_dst+2), a
    ld      a, (xm_src)
    ld      (tmp_src+2), a
    xor     a
    ld      (xm_armed), a           ; arming lasts one move only
@go:
    ; CP/M 3's ?move is specified as HL = destination, DE = source,
    ; which is the OPPOSITE of LDIR's (DE) <- (HL).  Load them the
    ; way LDIR wants them.
    ld      hl, (tmp_src)
    ld      de, (tmp_dst)
    ld      bc, (tmp_len)
    ldir

    pop     af
    pop     ix
    ret.lil


; -----------------------------------------------------------------------------
; bank_to_seg -- map CP/M bank number in A to an MBASE segment, in A.
; Anything other than bank 0 is treated as bank 1, which is what the BDOS
; means when it passes a bank number it expects to be the TPA.
; -----------------------------------------------------------------------------
bank_to_seg:
    or      a
    jr      nz, @one
    ld      a, SEG_BANK0
    ret
@one:
    ld      a, SEG_BANK1
    ret

; =============================================================================
;  CONSOLE
; -----------------------------------------------------------------------------
;  Direct UART0 access, as the CP/M 2.2 port does.  The VDP is put into
;  terminal emulation mode at startup, so characters written to UART0 appear on
;  screen and keystrokes arrive back the same way.  Going through MOS's console
;  API instead would drag in its interrupt-driven keyboard handling for no
;  benefit, and would need MBASE juggling on every character.
; =============================================================================

; _g_conout -- send the character in C.
_g_conout:
    call    conout_char
    ret.lil

; conout_char -- the body of the console output gate, ending in a plain RET
; so that supervisor code can call it.  A gate ends in RET.LIL and returns to
; Z80 mode; an internal caller needs an ordinary return.  Same split as
; drv_open and _g_dlogin.
conout_char:
    ; C holds the character throughout: the countdown MUST use a
    ; register pair other than BC, or it overwrites C before the
    ; character is ever written out.  (First attempt at this got
    ; that wrong -- caught in review before it reached hardware.)
    push    af
    push    de
    ld      de, TX_WAIT
@wait:
    in0     a, (REG_LSR)
    and     LSR_ETH
    jr      nz, @send
    dec     de
    ld      a, d
    or      e
    jr      nz, @wait
    ; Timed out: MOS itself gives up after TX_WAIT rather than
    ; hang forever, and does the same here.  The character is
    ; dropped rather than risk a second permanent hang.
    pop     de
    pop     af
    ret
@send:
    ld      a, c
    out0    (REG_THR), a
    pop     de
    pop     af
    ret

; _g_conin -- wait for a keystroke, return it in A.
_g_conin:
    call    conin_char
    ret.lil

; conin_char -- body of the console input gate, plain RET for internal callers.
conin_char:
@wait:
    in0     a, (REG_LSR)
    and     LSR_RDY
    jr      z, @wait
    in0     a, (REG_RBR)
    or      a
    jr      z, @wait    ; discard NUL, as the 2.2 port does
    cp      127         ; map DEL to backspace
    jr      nz, @out
    ld      a, 8
@out:
    ret

; _g_const -- A = $FF if a character is waiting, 0 if not.
_g_const:
    call    const_char
    ret.lil

; const_char -- body of the console status gate, plain RET for internal callers.
const_char:
    in0     a, (REG_LSR)
    and     LSR_RDY
    ret     z
    ld      a, $FF
    ret


; =============================================================================
;  CLOCK
; -----------------------------------------------------------------------------
;  BIOS function 26.  C = 0 to read the clock, 0FFh to set it.  System Guide
;  3.4.5:
;
;    "a zero in register C indicates that the BIOS should update the Time and
;     Date fields in the SCB.  A OFFH in register C indicates that the BDOS
;     has just set the Time and Date in the SCB and the BIOS should update its
;     clock."
;
;  Both directions are implemented.  The clock is held here, in binary, as a
;  day count plus hours, minutes and seconds, together with the value of MOS's
;  tick counter at the moment that reading was correct.  Everything else is
;  arithmetic on those.
;
;  WHY THE TIME IS KEPT AS A DAY COUNT AND NOT AS A DATE.  @date is already
;  "the number of days since 31 December 1977" (System Guide 2.7), so rolling
;  past midnight is a single increment.  No month lengths, no leap years, no
;  calendar of any kind is needed after startup -- that work happens once, in
;  rtc_decode, and never again.
;
;  WHY THE SCB STORE IS NOT DONE HERE.  This supervisor cannot address the
;  SCB.  scb.asm declares @date, @hour, @min and @sec as absolute external
;  equates on page 0FEh, and System Guide 3.1 explains that the linker marks
;  those page relocatable and GENCPM rewrites 0FExxh to the real address.
;  That fixup happens at link and generation time, to the BIOS.  This file is
;  a separate eZ80 program that neither DRLINK nor GENCPM ever sees.  So the
;  supervisor hands ?time five ready-to-store bytes and agonbnk.asm stores
;  them, where the symbols resolve.
; =============================================================================

; clock_init -- read the ESP32's clock, once, at startup.
;
; MUST BE CALLED BEFORE console_init.  Everything this depends on -- MOS's
; UART0 receive interrupt, vdp_protocol, wait_VDP -- is switched off or
; bypassed the moment the VDP goes into terminal mode.
;
; mos_unpackrtc is used rather than mos_getrtc for two reasons.  mos_getrtc
; returns a FORMATTED STRING (rtc_formatDateTime), which would have to be
; parsed back.  And mos_UNPACKRTC skips the unpack entirely when the address
; is zero --
;
;     if (flags & 1) rtc_update();
;     if (address != 0) rtc_unpack(&rtc, (vdp_time_t *)address);
;
; -- so passing HL = 0 performs the refresh and nothing else.  The six raw
; bytes are then read straight out of MOS's own sysvars, which is the same
; packet rtc_decode below was written and checked against.  Taking the
; unpacked vdp_time_t instead would mean relying on the field offsets the ZDS
; compiler chose for that struct, which are not visible from here.
clock_init:
    push    bc
    push    de
    push    hl

    xor     a
    ld      (rtc_stat), a           ; 0 = nothing has been attempted

    ; Bare, for the reason set out at length in _start: this runs in
    ; the loader phase, where MB is 0 and MOS calls take no
    ; bracketing.  mos_enter would be harmless on its own; it is
    ; mos_leave, setting MB to cur_seg, that breaks every MOS call
    ; and every rst.lil $18 that follows.
    ld      hl, 0                   ; refresh only, do not unpack
    ld      c, 1                    ; bit 0: refresh before unpacking
    MOSCALL mos_unpackrtc

    ; Copy MOS's cached packet out of its system variables.  IX is not
    ; used here because LDIR wants the source in HL.
    push    ix
    ld      ix, (sysvars)
    lea     hl, ix+SYSVAR_RTC
    pop     ix
    ld      de, rtc_pkt
    ld      bc, 6
    ldir

    ld      a, 6
    ld      (rtc_len), a
    ld      a, 1
    ld      (rtc_stat), a           ; 1 = a packet was fetched

    call    rtc_decode              ; CF set if it is not a usable date
    jr      c, @unset

    ; Anchor the running clock on the reading just taken.
    call    tick_now
    ld      (tick_base), hl
    xor     a
    ld      (tick_frac), a
    ld      a, 1
    ld      (clock_ok), a

    ; RETIRED: esp_blk was seeded from clk_blk here, and esp_ok set
    ; alongside clock_ok, so that GETDATE.COM had a copy of the
    ; startup reading that DATE SET could not move.
    ;
    ;   ld      hl, clk_blk
    ;   ld      de, esp_blk
    ;   ld      bc, BLK_SIZE
    ;   ldir
    ;   ld      (esp_ok), a

    pop     hl
    pop     de
    pop     bc
    ret

@unset:
    xor     a
    ld      (clock_ok), a           ; ?time will decline until DATE SET
    pop     hl
    pop     de
    pop     bc
    ret


; _g_time -- HL = five-byte buffer in the caller's segment:
;   +0,+1  @date, days since 31 December 1977, low byte first
;   +2     @hour, BCD
;   +3     @min,  BCD
;   +4     @sec,  BCD
; C = 0 to fill the buffer from the clock, 0FFh to set the clock from it.
; Returns A = 0 and Z set on success, non-zero otherwise.
_g_time:
    push    bc
    push    de
    push    hl

    ; Splice the caller's segment onto the 16-bit offset, exactly as
    ; disk_io does.  The third store also overwrites whatever HLU
    ; happened to hold on the way in from Z80 mode, which is why this
    ; is done in two parts rather than as one 24-bit store.
    ld      (tmp_dst), hl
    ld      a, (cur_seg)
    ld      (tmp_dst+2), a

    ld      a, c
    or      a
    jr      nz, @set

; --- C = 0: bring the clock up to date and report it -------------------------
    ld      a, (clock_ok)
    or      a
    jr      z, @fail                ; never set: leave the SCB alone, so an
    ; unset clock reads as unset rather than
    ; as some arbitrary date

    call    clock_advance
    push    ix
    ld      ix, clk_blk
    call    blk_pack                ; time_res = the five bytes
    pop     ix

    ld      hl, time_res
    ld      de, (tmp_dst)
    ld      bc, 5
    ldir
    jr      @ok

; --- C = 0FFh: the BDOS has just set the SCB ---------------------------------
;
; FUTURE: THIS COULD ALSO BE WRITTEN THROUGH TO THE VDP.  It is not, because
; the correction would be lost at the next reset -- confirmed on hardware,
; the RESET button loses the ESP32's clock as well as the eZ80's.  With a
; battery backup module fitted that stops being true and the write becomes
; worth making: set the time once from the CP/M prompt and every later boot of
; CP/M, MOS or BBC BASIC inherits it.
;
; The obstacle is not the packet format, which is known.  It is that the VDU
; interpreter cannot be reached at all while the VDP is in terminal mode,
; exactly as for reading.
;
;
; This is what makes DATE SET work.  BDOS function 104 writes @date, @hour
; and @min into the SCB, zeroes @sec, and then calls here.  All that is needed
; is to make those values the new base and restart the count from now.
;
; Note this works even when the ESP32's clock was never set: the user can set
; the time from inside CP/M and it will run correctly for the session.  It
; does not reach the VDP, so it does not survive a reset.
@set:
    ld      hl, (tmp_dst)
    ld      de, time_res
    ld      bc, 5
    ldir

    ; @date is built a byte at a time rather than with LD HL,(nn),
    ; which would read THREE bytes and pull the BCD hour at +2 into
    ; HLU.  LD HL,0 first clears all 24 bits.
    ld      hl, 0
    ld      a, (time_res+1)
    ld      h, a
    ld      a, (time_res+0)
    ld      l, a
    ld      (clk_date), hl

    ld      a, (time_res+2)
    call    bcd2bin
    ld      (clk_hour), a
    ld      a, (time_res+3)
    call    bcd2bin
    ld      (clk_min), a
    ld      a, (time_res+4)
    call    bcd2bin
    ld      (clk_sec), a

    call    tick_now
    ld      (tick_base), hl
    xor     a
    ld      (tick_frac), a
    ld      a, 1
    ld      (clock_ok), a

@ok:
    pop     hl
    pop     de
    pop     bc
    xor     a
    ret.lil
@fail:
    pop     hl
    pop     de
    pop     bc
    ld      a, 1
    or      a
    ret.lil


; =============================================================================
;  RETIRED -- support for GETDATE.COM and CHCKDATE.COM
; -----------------------------------------------------------------------------
;  This block is commented out, and costs the FID heap nothing.  The clock
;  does not need any of it: it existed so that two transients could ask what
;  the startup fetch returned and what the ESP32 would say now.
;
;  The utilities themselves do not work.  Run on hardware they flood the
;  console and leave the machine unusable.  The gate table is not the cause:
;  g$rtcraw and g$esptime were checked in the built image at +44 and +48,
;  correctly aligned and jumping to the right addresses.  Note that these
;  would be the ONLY GATES CALLED FROM A CP/M TRANSIENT.  Every other gate in
;  this table is entered from the BIOS or from a FID module in segment $04,
;  never from user code in the TPA.  Anything that goes looking for the fault
;  should start there.
;
;  TO BRING IT BACK: uncomment this block, restore the two gate table entries
;  at +44 and +48 to JP form, uncomment esp_blk and its seeding in clock_init,
;  and uncomment the second blk_addsec pass in clock_advance.  Each of those
;  sites is marked "RETIRED".
; =============================================================================
;
;; _g_rtcraw -- diagnostic gate.  HL = an eight-byte buffer in the caller's
;; segment, filled with:
;;   +0     status: 0 = the clock was never fetched, 1 = a packet was fetched,
;;                  3 = the packet was not a usable date
;;   +1     number of payload bytes in that packet
;;   +2..+7 the six raw bytes
;;
;; This exists so that a failure at startup can be told apart from a wrong
;; answer without a debugger.  The fetch happens once, during boot, and by the
;; time anything can be printed the moment has long passed -- so the evidence
;; is kept.  GETDATE.COM prints it.
;_g_rtcraw:
;    push    bc
;    push    de
;    push    hl
;    ld      (tmp_dst), hl
;    ld      a, (cur_seg)
;    ld      (tmp_dst+2), a
;    ld      hl, rtc_stat
;    ld      de, (tmp_dst)
;    ld      bc, 8
;    ldir
;    pop     hl
;    pop     de
;    pop     bc
;    xor     a
;    ret.lil
;
;
;; _g_esptime -- compare the running clock with the ESP32's reckoning, and
;; optionally put the running clock back to it.
;;
;; HL = a ten-byte buffer in the caller's segment:
;;   +0..+4  what the ESP32 would read now
;;   +5..+9  what CP/M's clock reads now
;; each in the same form ?time uses: @date low, @date high, hour, minute and
;; second in BCD.
;;
;; C = 0 reports; C = 1 re-anchors the running clock to the ESP32's reckoning
;; first, so the two halves then agree.
;;
;; Returns A = 0 on success, 1 if the startup fetch never produced a usable
;; date, in which case the buffer is not written.
;;
;; BOTH HALVES ARE COMPUTED IN ONE CALL, ON PURPOSE.  If the caller asked for
;; them separately, the tick counter could advance between the two requests and
;; a clock that was perfectly in step would report a one-second disagreement.
;; GETDATE.COM decides whether to set the clock by comparing these two, so that
;; would make it set the clock at random.
;;
;; "What the ESP32 would read now" means the reading taken at startup, carried
;; forward on the tick counter.  The ESP32 itself is unreachable once the VDP
;; is in terminal mode -- see the note by clock_init -- so this is as close to
;; asking it as the machine allows.  It is NOT a fresh reading, and if the
;; ESP32's clock was wrong at startup this will faithfully put the wrong time
;; back.
;_g_esptime:
;    push    bc
;    push    de
;    push    hl
;    push    ix
;
;    ld      (tmp_dst), hl
;    ld      a, (cur_seg)
;    ld      (tmp_dst+2), a
;
;    ld      a, (esp_ok)
;    or      a
;    jr      z, @fail
;
;    ; Bring both blocks up to the present before anything is read
;    ; or compared.  clock_advance moves clk_blk and esp_blk by the
;    ; same number of seconds, so they stay exactly in step.
;    call    clock_advance
;
;    ld      a, c
;    or      a
;    jr      z, @report
;
;    ; C = 1: put the running clock back.  Copying the block and
;    ; re-snapshotting the counter is the whole operation -- the same
;    ; thing clock_init does at startup, and the same thing ?time
;    ; does when the BDOS sets the clock.
;    ld      hl, esp_blk
;    ld      de, clk_blk
;    ld      bc, BLK_SIZE
;    ldir
;    call    tick_now
;    ld      (tick_base), hl
;    xor     a
;    ld      (tick_frac), a
;    ld      a, 1
;    ld      (clock_ok), a
;
;@report:
;    ld      ix, esp_blk
;    call    blk_pack
;    ld      hl, time_res
;    ld      de, (tmp_dst)
;    ld      bc, 5
;    ldir
;
;    ld      ix, clk_blk
;    call    blk_pack
;    ld      hl, time_res
;    ld      de, (tmp_dst)
;    ex      de, hl
;    ld      bc, 5
;    add     hl, bc                  ; second half starts at +5
;    ex      de, hl
;    ld      bc, 5
;    ldir
;
;    pop     ix
;    pop     hl
;    pop     de
;    pop     bc
;    xor     a
;    ret.lil
;
;@fail:
;    pop     ix
;    pop     hl
;    pop     de
;    pop     bc
;    ld      a, 1
;    or      a
;    ret.lil
;
;
;

; =============================================================================
;  RUNNING THE CLOCK
; -----------------------------------------------------------------------------
;  _clock (sysvar offset 0) is a 32-bit counter incremented by 2 on every
;  VBLANK by _vblank_handler in MOS's interrupts.asm.  The interrupt comes
;  from the VDP's VSync line on a GPIO pin, not from UART traffic, so it keeps
;  running under CP/M -- _start re-enables interrupts before jumping in.
;
;  Only the low 24 bits are read, because HL is 24 bits wide and LD HL,(nn)
;  moves three bytes.  That is deliberate and safe: all arithmetic below is
;  modulo 2^24, so the wrap at 2^24 counts -- about 38 hours -- handles
;  itself, exactly as long as ?time is called at least once in any 38-hour
;  period.  It is called on every date-stamped file operation and by every
;  DATE command, but a machine left idle for two days will lose a wrap.
;  Recording that as a known limit rather than pretending otherwise.
; =============================================================================

; tick_now -- HL = the low 24 bits of MOS's tick counter.
tick_now:
    push    ix
    ld      ix, (sysvars)
    ld      hl, (ix+SYSVAR_TIME)
    pop     ix
    ret

; clock_advance -- add however much real time has passed to the held clock.
;
; The remainder is CARRIED, not discarded.  Dropping it would lose up to
; TICKS_PER_SEC-1 counts on every call, and since the BDOS calls ?time on
; every date-stamped file operation, a busy system would run slow by an
; amount that depended on how often it was asked -- the worst kind of clock
; fault, because it would look like drift rather than a bug.
clock_advance:
    push    bc
    push    de
    push    hl

    call    tick_now
    ld      de, (tick_base)
    or      a
    sbc     hl, de                  ; HL = counts since the base, mod 2^24
    push    hl                      ; keep the elapsed count
    add     hl, de
    ld      (tick_base), hl         ; new base = the reading just taken
    pop     hl

    ; LD DE,0 AND NOT LD D,0.  DE is a 24-bit register here and it
    ; still holds the top byte of tick_base from the LD DE,(nn)
    ; above; setting only D and E would leave DEU dirty and add a
    ; multiple of 65,536 counts.  The same trap is described at
    ; length for the loader variables further down this file.
    ld      a, (tick_frac)
    ld      de, 0
    ld      e, a
    add     hl, de                  ; plus whatever was left over last time

    ; Divide by TICKS_PER_SEC.  Repeated subtraction: the divisor is
    ; 120 and the dividend is the counts since the last call, so this
    ; turns once per elapsed second.  A machine idle for an hour costs
    ; 3,600 turns of a six-instruction loop, which is nothing; the
    ; alternative is a 24-bit division routine that would be longer
    ; than the entire clock.
    ld      de, TICKS_PER_SEC
    ld      bc, 0                   ; BC = whole seconds
@div:
    or      a
    sbc     hl, de
    jr      c, @divdone
    inc     bc
    jr      @div
@divdone:
    add     hl, de                  ; undo the last subtraction
    ld      a, l
    ld      (tick_frac), a          ; remainder, 0..TICKS_PER_SEC-1

    ; Add BC seconds to the held time.
    push    ix
    ld      ix, clk_blk
    call    blk_addsec
    pop     ix

    ; RETIRED: esp_blk was advanced here in lockstep, by the same BC,
    ; so that GETDATE.COM could ask what the ESP32 would say now.
    ; Advancing it in step rather than recomputing it from a stored
    ; startup anchor was deliberate -- the anchor form is limited to
    ; one wrap of the tick counter, 38 hours, because the subtraction
    ; is modulo 2^24, and the regression suite caught it wrapping on a
    ; simulated seven-day run.  Restore BOTH lines together if this
    ; ever comes back.
    ;
    ;   push    bc              ; blk_addsec is destructive on HL and
    ;                           ; reads BC, so keep a copy
    ;   ld      ix, clk_blk
    ;   call    blk_addsec
    ;   pop     bc
    ;   ld      ix, esp_blk
    ;   call    blk_addsec

    pop     hl
    pop     de
    pop     bc
    ret

; -----------------------------------------------------------------------------
;  A "clock block" is six bytes: a three-byte day count, then hour, minute and
;  second, each binary.  There are two of them -- clk_blk, the running clock,
;  which DATE SET is allowed to move; and esp_blk, the ESP32's reckoning,
;  which only the tick may move.  The routines below take the block base in IX
;  so that the same, once-verified carry logic serves both rather than being
;  written out twice.
; -----------------------------------------------------------------------------
BLK_DATE:       .equ    0   ; three bytes
BLK_HOUR:       .equ    3
BLK_MIN:        .equ    4
BLK_SEC:        .equ    5
BLK_SIZE:       .equ    6

; blk_tick -- advance the block at IX by exactly one second.
;
; A system that has been idle for a day turns this 86,400 times on the first
; call afterwards; at eZ80 speeds that is well under a second, and it happens
; once.  Doing it this way rather than with divisions keeps the carry logic in
; one place where it can be read.
blk_tick:
    ld      a, (ix+BLK_SEC)
    inc     a
    cp      60
    jr      c, @storesec
    xor     a
    ld      (ix+BLK_SEC), a
    ld      a, (ix+BLK_MIN)
    inc     a
    cp      60
    jr      c, @storemin
    xor     a
    ld      (ix+BLK_MIN), a
    ld      a, (ix+BLK_HOUR)
    inc     a
    cp      24
    jr      c, @storehour
    xor     a
    ld      (ix+BLK_HOUR), a
    ; Past midnight.  @date is a day count, so this really is just
    ; an increment -- no month length, no leap year, nothing.
    ld      hl, (ix+BLK_DATE)
    inc     hl
    ld      (ix+BLK_DATE), hl
    ret
@storehour:
    ld      (ix+BLK_HOUR), a
    ret
@storemin:
    ld      (ix+BLK_MIN), a
    ret
@storesec:
    ld      (ix+BLK_SEC), a
    ret

; blk_addsec -- add BC seconds to the block at IX.
blk_addsec:
    push    bc
    pop     hl                      ; HL = seconds to add, all 24 bits
@addsec:
    ; THE ZERO TEST MUST BE 24-BIT.  "LD A,H / OR L" only looks at
    ; the low sixteen, and the count here can exceed 65,535: the
    ; tick counter spans 2^24, so a long gap between calls yields up
    ; to about 139,000 seconds.  SBC HL,DE with DE zero and carry
    ; clear leaves HL alone and sets Z on the full 24-bit result.
    ld      de, 0
    or      a
    sbc     hl, de
    ret     z
    dec     hl
    push    hl
    call    blk_tick
    pop     hl
    jr      @addsec

; blk_pack -- render the block at IX into the five bytes at time_res:
; @date low, @date high, then hour, minute and second in BCD.
blk_pack:
    push    hl
    ld      hl, (ix+BLK_DATE)
    ld      (time_res), hl          ; three bytes; +2 is overwritten below
    ld      a, (ix+BLK_HOUR)
    call    bin2bcd
    ld      (time_res+2), a
    ld      a, (ix+BLK_MIN)
    call    bin2bcd
    ld      (time_res+3), a
    ld      a, (ix+BLK_SEC)
    call    bin2bcd
    ld      (time_res+4), a
    pop     hl
    ret

; =============================================================================
;  CLOCK PACKET DECODE
; -----------------------------------------------------------------------------
;  The six bytes are the eZ80 end of agon-vdp's vdp_time_t, a union of a
;  packed bitfield struct with a six-byte array.  MOS's rtc_unpack (clock.c)
;  gives the field positions explicitly, as masks against the little-endian
;  32-bit word formed by bytes 0-3:
;
;      month      d & 0000000Fh            byte 0, bits 0-3
;      day        d & 000001F0h >> 4       byte 0 bits 4-7 + byte 1 bit 0
;      dayOfWeek  d & 00000E00h >> 9       byte 1, bits 1-3
;      dayOfYear  d & 001FF000h >> 12      byte 1 bits 4-7 + byte 2 bits 0-4
;      hour       d & 03E00000h >> 21      byte 2 bits 5-7 + byte 3 bits 0-1
;      minute     d & FC000000h >> 26      byte 3, bits 2-7
;      second     byte 4
;      year       byte 5, SIGNED, plus 1980
;
;  This runs ONCE, at startup.  month and dayOfWeek are decoded even though
;  the running clock does not need them, because GETDATE prints them and
;  because a month of 0 with a day of 0 is the signature of a clock that has
;  never been set.
; =============================================================================

; rtc_decode -- convert rtc_pkt into the held clock.
; CF clear on success; CF set if the packet does not describe a date CP/M
; can represent.
rtc_decode:
    push    bc
    push    de
    push    hl

    ; --- day of month: byte 0 bits 4-7, byte 1 bit 0 -------------
    ld      a, (rtc_pkt+0)
    rrca
    rrca
    rrca
    rrca
    and     $0F
    ld      c, a
    ld      a, (rtc_pkt+1)
    and     $01
    rlca
    rlca
    rlca
    rlca
    or      c
    ld      (rtc_day), a

    ; A DAY OF ZERO MEANS THE CLOCK HAS NEVER BEEN READ.
    ;
    ; MOS's _rtc is six bytes of BSS, cleared by cstartup.asm, and
    ; nothing in MOS's main() calls rtc_update() -- init_rtc() only
    ; sets the enable flag.  An all-zero packet decodes as month 0
    ; (January), day 0, and year 0 + 1980, which looks like a
    ; perfectly ordinary 1 January 1980 and would convert to a
    ; plausible @date of 731.  The day of zero is the only tell.
    or      a
    jp      z, @bad     ; JP, not JR: @bad is at the far end of this
    ; routine and out of relative range

    ; RETIRED: month (byte 0 bits 0-3, zero-based) and day of week
    ; (byte 1 bits 1-3) were decoded here purely so CHCKDATE.COM
    ; could print them.  The running clock needs neither: it works
    ; from a day count.  Note if these come back that the packet's
    ; day of week is not always right, because the ESP32's overflow
    ; flag persists across a reset.
    ;
    ;   ld      a, (rtc_pkt+0)
    ;   and     $0F
    ;   ld      (rtc_mon), a
    ;   ld      a, (rtc_pkt+1)
    ;   rrca
    ;   and     $07
    ;   ld      (rtc_dow), a

    ; --- day of year: byte 1 bits 4-7, byte 2 bits 0-4 ----------
    ;
    ; ZERO-BASED.  ESP32Time::getDayofYear() returns tm_yday
    ; straight out of a struct tm, and its own comment says
    ; "(0-365)".  1 January is 0.
    ld      hl, 0
    ld      a, (rtc_pkt+2)
    and     $1F
    ld      l, a
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl          ; << 4
    ld      a, (rtc_pkt+1)
    rrca
    rrca
    rrca
    rrca
    and     $0F
    ; LD DE,0 first, for the reason given in clock_advance: DE is
    ; 24 bits wide and holds whatever the caller left in DEU.
    ld      de, 0
    ld      e, a
    add     hl, de
    ld      (rtc_yday), hl

    ; --- hour: byte 2 bits 5-7, byte 3 bits 0-1 -----------------
    ld      a, (rtc_pkt+2)
    rlca
    rlca
    rlca
    and     $07
    ld      c, a
    ld      a, (rtc_pkt+3)
    and     $03
    rlca
    rlca
    rlca
    or      c
    ld      (clk_hour), a

    ; --- minute: byte 3 bits 2-7 --------------------------------
    ld      a, (rtc_pkt+3)
    rrca
    rrca
    and     $3F
    ld      (clk_min), a

    ; --- second: byte 4 -----------------------------------------
    ld      a, (rtc_pkt+4)
    ld      (clk_sec), a

    ; --- year: byte 5, signed, plus 1980 ------------------------
    ;
    ; The VDP computes this as rtc.getYear() - EPOCH_YEAR with
    ; EPOCH_YEAR 1980 and stores it in a uint8_t, and MOS reads it
    ; back through a signed char.  A cold ESP32 has never had
    ; settimeofday() called on it, so its clock reads 1970 and this
    ; byte is 0F6h -- a well-formed packet holding a date eight
    ; years before CP/M's epoch.  @date is unsigned, so it cannot
    ; be represented and must be rejected rather than wrapped.
    ;
    ; SIGN EXTENSION IS DONE BY SUBTRACTING, NOT BY WIDENING.
    ; DE is a 24-bit register here, so loading 0FFxxh into its low
    ; half does not make it negative -- ADD HL,DE would then bring
    ; in 65,526 rather than -10.  Taking the magnitude and using
    ; SBC avoids the whole question.
    ld      a, (rtc_pkt+5)
    ld      hl, 1980
    bit     7, a
    jr      nz, @yrneg
    ld      de, 0           ; clears DEU as well as D and E
    ld      e, a
    add     hl, de
    jr      @yrdone
@yrneg:
    neg                     ; A = magnitude of the offset
    ld      de, 0
    ld      e, a
    or      a
    sbc     hl, de
@yrdone:
    ld      (rtc_year), hl

    ; Reject anything before 1978: @date counts days since
    ; 31 December 1977 and cannot go negative.
    ld      de, 1978
    or      a
    sbc     hl, de
    jp      c, @bad     ; JP for the reason given above

    ; --- @date --------------------------------------------------
    ;
    ;   @date = days_before_year(year) + dayOfYear + 1
    ;
    ; where days_before_year(y) counts the days from 1 January 1978
    ; to 1 January of y:
    ;
    ;   n     = y - 1978
    ;   leaps = (y - 1977) / 4          leap years in [1978, y)
    ;   if y > 2100: leaps = leaps - 1  2100 is not a leap year
    ;   days  = 365*n + leaps
    ;
    ; 1980 is the first leap year at or after 1978, which is what
    ; makes the (y-1977)/4 form come out right; 2000 IS a leap year
    ; and needs no special case.  Checked against the calendar for
    ; every day from 1 January 1978 to 31 December 2130 -- 55,882
    ; dates, no mismatches -- and the largest value in that range
    ; is 55,882, comfortably inside the 16 bits @date allows.
    ;
    ; HL still holds year-1978 from the test above.
    ld      b, l            ; B = n.  n < 256 for any year the
    ; one-byte packet field can express.
    ld      hl, 0
    ld      a, b
    or      a
    jr      z, @noyears     ; DJNZ with B=0 would loop 256 times
    ld      de, 365
@years:
    add     hl, de
    djnz    @years
@noyears:

    ; leaps = (year - 1977) / 4
    push    hl
    ld      hl, (rtc_year)
    ld      de, 1977
    or      a
    sbc     hl, de
    ; SRL H / RR L shifts the low SIXTEEN bits only, leaving HLU
    ; untouched.  That is correct here and only here: HL came from
    ; a 24-bit SBC of two small positive numbers, so HLU is zero.
    srl     h
    rr      l
    srl     h
    rr      l               ; HL = (year-1977)/4
    ; 2100 is divisible by 4 but is not a leap year.
    ld      de, (rtc_year)
    push    hl
    ld      hl, 2100
    or      a
    sbc     hl, de          ; CF set if year > 2100
    pop     hl
    jr      nc, @nocentury
    dec     hl
@nocentury:
    ex      de, hl
    pop     hl
    add     hl, de          ; HL = 365*n + leaps

    ld      de, (rtc_yday)
    add     hl, de
    inc     hl              ; 1 January 1978 is day 1, not day 0
    ld      (clk_date), hl

    pop     hl
    pop     de
    pop     bc
    or      a               ; CF clear
    ret

@bad:
    ld      a, 3
    ld      (rtc_stat), a
    pop     hl
    pop     de
    pop     bc
    scf
    ret

; bin2bcd -- A (0-99) to packed BCD.  Corrupts nothing else.
bin2bcd:
    push    bc
    ld      b, 0
@tens:
    cp      10
    jr      c, @units
    sub     10
    inc     b
    jr      @tens
@units:
    ld      c, a
    ld      a, b
    rlca
    rlca
    rlca
    rlca
    or      c
    pop     bc
    ret

; bcd2bin -- packed BCD in A to binary.  Corrupts nothing else.
;
; Used only on values the BDOS put in the SCB.  A malformed digit (A-F in
; either nibble) cannot produce a value the clock cannot hold: the worst case
; is 9*16+15 = 159, and blk_tick's comparisons are "greater or equal", so
; the field would roll over on the next tick rather than stick.
bcd2bin:
    push    bc
    ld      c, a
    and     $0F
    ld      b, a            ; B = units
    ld      a, c
    rrca
    rrca
    rrca
    rrca
    and     $0F             ; A = tens
    add     a, a            ; x2
    ld      c, a
    add     a, a            ; x4
    add     a, a            ; x8
    add     a, c            ; x10
    add     a, b
    pop     bc
    ret


; =============================================================================
;  DISK
; -----------------------------------------------------------------------------
;  Drives are files on the SD card named cpm<letter>.dsk, the same convention
;  the CP/M 2.2 port uses.  The BIOS installs C: through J: -- cpmc.dsk to
;  cpmj.dsk -- so A: and B: are left free for a floppy driver supplied as a
;  FID.  Drive letter, relative drive number and image letter are all the
;  same value, so nothing has to remember an offset between them.
;
;  ONE IMAGE IS OPEN AT A TIME, OPENED ON DEMAND.  MOS 3.0.2 allows only
;  eight files open at once (MOS_maxOpenFiles in its config.h), so a handle
;  held per drive for the life of the session would consume every one of them
;  with eight images mounted and leave nothing for the FID loader to open
;  FID.INI with.  The full reasoning is at drv_open below.
;
;  The BIOS passes a 9-byte parameter block rather than trying to squeeze the
;  transfer parameters into registers:
;
;      +0  relative drive
;      +1  track          (2 bytes)
;      +3  sector         (2 bytes)
;      +5  DMA address    (2 bytes, within the bank named at +7)
;      +7  DMA bank
;      +8  sector count
;
;  HL holds its 16-bit address in the currently selected segment.
;
;  MOS reads and writes through full 24-bit pointers, so the transfer goes
;  directly to or from the CP/M bank -- no bounce buffer, and a DMA address in
;  a different bank from the caller costs nothing.
; =============================================================================

; _g_dlogin -- open the image for relative drive C if not already open.
; Returns A = 0 and Z set on success.
_g_dlogin:
    call    drv_open
    ret.lil

; drv_open -- make the image for relative drive C the open one.
;
; ONE IMAGE IS OPEN AT A TIME, OPENED ON DEMAND.  This is what the CP/M 2.2
; port does, and it is not a simplification for its own sake: MOS allows only
; a fixed number of files open at once, so a handle held per drive for the
; session would consume every one of them, leaving the FID loader unable to
; open FID.INI with eight images mounted.
;
; Holding handles buys little in any case.  A drive that is already current
; costs one compare; only a switch costs a close and an open, and CP/M works
; a drive at a time, so switches are rare next to the sector traffic between
; them.  Closing also flushes, so a switch commits pending writes instead of
; leaving them in FatFS's buffers for the rest of the session.
;
; This is separate from _g_dlogin because a gate ends in RET.LIL and returns
; to Z80 mode; internal callers -- disk_io and _g_drvnew -- need a plain RET.
;
; Returns A = 0 and Z set on success, A = 1 and NZ if the image will not open.
drv_open:
    push    hl
    push    de
    push    bc

    ld      a, c
    cp      NDRIVES
    jr      nc, @fail

    ; already the open one?
    ld      a, (cur_handle)
    or      a
    jr      z, @swap    ; nothing open at all
    ld      a, (cur_unit)
    cp      c
    jr      z, @already

@swap:
    ; Close whatever is open before opening the next.  Closing
    ; also flushes, so a drive switch commits any pending write
    ; rather than leaving it in FatFS's buffer indefinitely.
    ld      a, (cur_handle)
    or      a
    jr      z, @noclose
    push    bc
    ld      bc, 0
    ld      c, a
    call    mos_enter
    MOSCALL mos_fclose
    call    mos_leave
    pop     bc
@noclose:
    xor     a
    ld      (cur_handle), a
    ld      a, $FF
    ld      (cur_unit), a

    ld      a, c
    add     a, 'a'
    ld      (drv_letter), a
    ld      hl, drv_name
    push    bc
    ld      bc, 0       ; 24-bit clear before setting C
    ld      c, fa_read+fa_write
    call    mos_enter
    MOSCALL mos_fopen
    call    mos_leave
    pop     bc
    or      a
    jr      z, @fail    ; handle 0 = could not open
    ld      (cur_handle), a
    ld      a, c
    ld      (cur_unit), a
@already:
    pop     bc
    pop     de
    pop     hl
    xor     a
    ret
@fail:
    pop     bc
    pop     de
    pop     hl
    ld      a, 1
    or      a
    ret


; _g_dread / _g_dwrite -- transfer sectors described by the block at HL.
_g_dread:
    ld      a, mos_fread
    jr      disk_io
_g_dwrite:
    ld      a, mos_fwrite
disk_io:
    ld      (io_func), a
    push    ix
    push    de
    push    bc

    ; copy the parameter block out of the CP/M segment
    ld      (tmp_src), hl
    ld      a, (cur_seg)
    ld      (tmp_src+2), a
    ld      hl, (tmp_src)           ; source: block in the CP/M bank
    ld      de, parm    ; destination: our copy
    ld      bc, 9
    ldir

    ; Make this drive's image the open one.  ONE IMAGE IS OPEN AT
    ; A TIME, and it is opened on demand rather than held for the
    ; session -- see the note on drv_open above.  A drive that is
    ; already current costs one compare.
    ld      a, (parm+0)
    ld      c, a
    call    drv_open
    or      a
    jp      nz, @fail   ; image will not open
    ld      a, (cur_handle)
    ld      (io_handle), a

    ; byte offset into the image
    ;   = (track * SPT_PHYS + sector) * SECSIZE
    ; HL is 24-bit in ADL mode, and an 8 MB image needs 23 bits, so
    ; this cannot overflow for any drive the DPB can describe.
    ;
    ; THE 16-BIT FIELDS ARE LOADED A BYTE AT A TIME, DELIBERATELY.
    ;
    ; "ld hl, (parm+1)" and "ld de, (parm+3)" are THREE-byte loads
    ; in ADL mode (UM0077 Table 10: the .L half of the mode makes
    ; the data block operate on 24-bit registers, and that is the
    ; default here because of .assume adl = 1).  HLU would pick up
    ; the low byte of the sector, and DEU the low byte of the DMA
    ; address.
    ;
    ; The stray bytes would in fact be harmless, because every path
    ; to the result passes through the *512 multiply below -- nine
    ; left shifts, and 16 + 9 = 25 is already past bit 23, so they
    ; are shifted out before they can reach it.  But that property
    ; depends entirely on the shift count that follows: change
    ; SECSIZE, or reorder the multiply and the add, and it is
    ; silently lost.  Building HL and DE from cleared registers is
    ; correct on its own terms, for four bytes and no run-time
    ; difference worth measuring.  The same pattern is used in
    ; _g_mio.
    ld      hl, 0
    ld      a, (parm+2)
    ld      h, a        ; track high
    ld      a, (parm+1)
    ld      l, a        ; track low

    ld      b, 4
@tspt:
    add     hl, hl      ; * SPT_PHYS sectors/track
    djnz    @tspt

    ld      de, 0       ; clears DEU as well as D and E
    ld      a, (parm+4)
    ld      d, a        ; sector high
    ld      a, (parm+3)
    ld      e, a        ; sector low
    add     hl, de
    ld      b, 9
@x512:
    add     hl, hl      ; * 512 bytes/sector
    djnz    @x512

    ; MOS ARGUMENT REGISTERS ARE WHOLE REGISTERS, NOT HALVES.
    ;
    ; From MOS 3.0.2's own mos_api.asm:
    ;
    ;   mos_api_flseek: PUSH DE   ; UINT32 offset (msb)
    ;       PUSH HL   ; UINT32 offset (lsb)
    ;       PUSH BC   ; UINT8  fh
    ;
    ;   mos_api_fread:  PUSH DE   ; UINT24 btr
    ;       PUSH HL   ; UINT24 buffer
    ;       PUSH BC   ; UINT8  fh
    ;
    ; So the seek offset is the 32-bit pair {DE:HL}, and the file
    ; handle is taken from the WHOLE of BC.  The previous code set
    ; only C and only E ("ld c,a" / "ld e,0"), leaving B, BCU, D and
    ; DEU holding whatever happened to be there.  D and DEU are the
    ; most significant half of the seek offset, and a few
    ; instructions earlier "ld de,(parm+3)" had loaded the sector
    ; number into DE -- so every seek went to a garbage offset far
    ; beyond the end of the image, and the read that followed
    ; returned nothing.  Same class of fault as handle_addr below:
    ; a 16-bit habit applied to 24-bit registers.
    call    mos_enter

    ld      bc, 0       ; 24-bit clear, then the handle
    ld      a, (io_handle)
    ld      c, a
    ld      de, 0       ; offset msb: MUST be zero
    MOSCALL mos_flseek

    ; transfer length = count * SECSIZE
    ld      hl, 0
    ld      a, (parm+8)
    ld      l, a
    ld      b, 9
@len:
    add     hl, hl
    djnz    @len
    ex      de, hl      ; DE = byte count (24-bit)

    ; buffer = {segment of DMA bank, DMA address}
    ; Three-byte load, left as it is: the stray third byte
    ; (parm+7, the bank) is overwritten two lines later by the
    ; segment number, so it is not merely harmless but actively
    ; the intended shape of the operation.
    ld      hl, (parm+5)
    ld      (tmp_dst), hl
    ld      a, (parm+7)
    call    bank_to_seg
    ld      (tmp_dst+2), a
    ld      hl, (tmp_dst)

    ld      bc, 0       ; 24-bit clear, then the handle
    ld      a, (io_handle)
    ld      c, a
    ld      a, (io_func)
    rst.lil $08         ; mos_fread or mos_fwrite
    call    mos_leave

    pop     bc
    pop     de
    pop     ix
    xor     a
    ret.lil
@fail:
    pop     bc
    pop     de
    pop     ix
    ld      a, 1
    or      a
    ret.lil


; =============================================================================
;  M: RAM DRIVE
; =============================================================================

; -----------------------------------------------------------------------------
; _g_mio -- transfer between the M: RAM drive and a CP/M bank.
;   HL = parameter block in the current CP/M segment (same nine-byte layout
;        as the one g_dread and g_dwrite take -- see agondsk.asm)
;   A  = 0 to read (RAM -> DMA), non-zero to write (DMA -> RAM)
;
; Returns A = 0 and Z on success, A = 1 on a request that falls outside the
; drive.  Nothing else can fail: there is no device and no MOS call here.
;
; WHY THIS GATE EXISTS AT ALL
; ---------------------------
; _g_move cannot do this job.  It resolves both ends through bank_to_seg,
; which only knows CP/M bank 0 -> $06 and bank 1 -> $05; it has no way to
; name an address in $07-$0B.  Rather than complicate the BDOS's own move
; path, the RAM drive gets its own gate.
;
; NO SEGMENT ARITHMETIC IS NEEDED for the RAM side.  This code runs in ADL
; mode with real 24-bit addressing, so a single LDIR crosses the $07/$08/
; $09/$0A/$0B boundaries without noticing them.  The 64K segment granularity
; only constrains code that EXECUTES in a segment, which this does not.
; -----------------------------------------------------------------------------
_g_mio:
    push    ix
    push    de
    push    bc

    ld      (mio_dir), a

    ; copy the parameter block out of the CP/M segment
    ld      (tmp_src), hl
    ld      a, (cur_seg)
    ld      (tmp_src+2), a
    ld      hl, (tmp_src)           ; source: block in the CP/M bank
    ld      de, parm_m  ; destination: our copy
    ld      bc, 9
    ldir

    ; ---- byte offset into the drive ----
    ;   = (track * SPT_RAM + record) * RECSIZE
    ;
    ; The 16-bit fields are loaded a byte at a time so that HLU and
    ; DEU are known to be zero.  "ld hl,(parm_m+1)" would read THREE
    ; bytes in ADL mode and put the low byte of the record number in
    ; HLU.  As it happens the shifts below would carry that byte off
    ; the top of the register before it reached the result -- the
    ; same accident that made the old disk_io code work, discussed
    ; at length there -- but this way the code does not depend on
    ; the shift count for its correctness.
    ld      hl, 0
    ld      a, (parm_m+2)
    ld      h, a        ; track high
    ld      a, (parm_m+1)
    ld      l, a        ; track low

    ld      b, 7
@trk128:
    add     hl, hl      ; * SPT_RAM (128) records/track
    djnz    @trk128

    ld      de, 0
    ld      a, (parm_m+4)
    ld      d, a        ; record high
    ld      a, (parm_m+3)
    ld      e, a        ; record low
    add     hl, de

    ld      b, 7
@rec128:
    add     hl, hl      ; * RECSIZE (128) bytes/record
    djnz    @rec128
    ld      (mio_off), hl           ; byte offset from RAM_BASE

    ; ---- transfer length = count * RECSIZE ----
    ld      hl, 0
    ld      a, (parm_m+8)
    ld      l, a
    ld      b, 7
@mlen:
    add     hl, hl
    djnz    @mlen
    ld      (mio_len), hl

    ; ---- bounds check: offset + length must not exceed RAM_SIZE ----
    ;
    ; This is not defensive decoration.  The address immediately
    ; above this drive is MOS's static data, and a transfer that
    ; ran past the end would corrupt the file handles that every
    ; SD-card drive depends on -- with the damage appearing later,
    ; on an unrelated drive.  Refusing here keeps the failure local
    ; and reportable.
    ld      hl, (mio_off)
    ld      de, (mio_len)
    add     hl, de      ; 24-bit add, cannot wrap: the
; largest possible operands are
; well under $FFFFFF
    ld      de, RAM_SIZE
    or      a           ; clear carry before SBC
    sbc     hl, de
    jr      z, @inrange ; exactly at the top is fine
    jr      nc, @mfail  ; past the top is not

@inrange:
    ; ---- RAM-side address ----
    ld      hl, (mio_off)
    ld      de, RAM_BASE
    add     hl, de
    ld      (mio_ram), hl

    ; ---- CP/M-side address: {segment of DMA bank, DMA offset} ----
    ; Three-byte load on purpose, as in disk_io: the third byte is
    ; replaced by the segment number before anything reads it.
    ld      hl, (parm_m+5)
    ld      (mio_dma), hl
    ld      a, (parm_m+7)
    call    bank_to_seg
    ld      (mio_dma+2), a

    ld      bc, (mio_len)
    ld      a, (mio_dir)
    or      a
    jr      nz, @mwrite

    ld      hl, (mio_ram)           ; read: RAM -> DMA
    ld      de, (mio_dma)
    ldir
    jr      @mdone
@mwrite:
    ld      hl, (mio_dma)           ; write: DMA -> RAM
    ld      de, (mio_ram)
    ldir
@mdone:
    pop     bc
    pop     de
    pop     ix
    xor     a
    ret.lil
@mfail:
    pop     bc
    pop     de
    pop     ix
    ld      a, 1
    or      a
    ret.lil


; =============================================================================
;  BANK-0 HEAP AND DYNAMIC DRIVE INSTALLATION
; -----------------------------------------------------------------------------
;  GENCPM can only allocate a drive's tables if the drive is already in @dtbl
;  when the system is generated.  gencpm.plm's need$tbl walks @dtbl and skips
;  any zero entry, so a drive that comes into existence at run time gets no
;  allocation vector, no buffer control blocks and no buffers, and the first
;  directory read hands the BDOS a null BCB.
;
;  Everything GENCPM would have built is therefore built here instead, out of
;  bank-0 memory that GENCPM was never given.  The shapes are not invented:
;  they were read out of a generated system and matched against gencpm.plm and
;  setbuf.plm.  A real GENCPM-built directory BCB for A: reads
;
;    FF 00 00 00 00 00 00 00 00 00 00 00 00 00 00
;
;  and the data BCB for the same drive
;
;    FF 00 00 00 00 00 00 00 00 00 06 FD 00 00 00
;
;  i.e. every field zero except drv = 0FFh (no drive owns the buffer yet), the
;  buffer address at +10, and the bank at +12.  That is what build_bcb writes.
;
;  ONE THING IS DELIBERATELY NOT ALLOCATED HERE: THE DPB.
;
;  BDOS function 31 returns the DPB address to the CALLING PROGRAM --
;  bdos30.asm, func31, is "call curselect / lhld dpbaddr / shld aret" -- and
;  the calling program runs in bank 1.  A DPB in bank 0 would be unreadable to
;  it, so SHOW and anything else that asks for drive parameters would read
;  whatever bank 1 happens to hold at that address.  The DPB has to be in
;  common memory, and this supervisor has no common memory to give out: GENCPM
;  owns all of it.  A drive installed here must therefore point at a DPB that
;  already exists in the BIOS's common segment.
;
;  For the first drive installed this way that is no restriction at all -- it
;  has the same geometry as A: and shares A:'s DPB, exactly as GENCPM does for
;  identical drives (in an eight-drive generation all eight DPHs pointed at the
;  same DPB).  A driver wanting a geometry of its own will need somewhere in
;  common to put a DPB, and that is not solved yet.
; =============================================================================

; -----------------------------------------------------------------------------
; heap0_init -- set the bank-0 heap bounds from the loaded system's layout.
;
; Must be called after load_system, which is where bnk_top and bnk_len are
; filled in from the CPM3.SYS header.  Called before anything can allocate.
; -----------------------------------------------------------------------------
heap0_init:
    ld      hl, HEAP0_BASE
    ld      (heap0_ptr), hl
    ld      a, SEG_BANK0
    ld      (heap0_ptr+2), a

    ; ceiling = base of the banked system = bnk_top - bnk_len*256
    ld      hl, 0
    ld      a, (bnk_len)
    ld      h, a        ; HL = bnk_len * 256
    ex      de, hl
    ld      hl, (bnk_top)
    or      a           ; clear carry for SBC
    sbc     hl, de
    ld      (heap0_end), hl
    ld      a, SEG_BANK0
    ld      (heap0_end+2), a
    ret


; -----------------------------------------------------------------------------
; heap0_alloc -- allocate BC bytes from the bank-0 heap.
;
; Returns HL = the 24-bit address of the block, carry clear.  Carry set and
; HL undefined if the request will not fit.
;
; The block is zero-filled.  GENCPM zeroes the space it allocates for buffer
; control blocks and buffers ("zero memory for the BCB buffers" in setbuf.plm)
; and the BDOS zeroes an allocation vector at login, so zeroing here matches
; what the rest of the system expects to find and removes the question of
; which fields must be initialised and which merely may be.
; -----------------------------------------------------------------------------
heap0_alloc:
    push    de
    push    bc

    ld      hl, (heap0_ptr)
    ld      de, (heap0_end)
    push    hl          ; keep the block address
    add     hl, bc      ; HL = new top of heap
    ; Carry from ADD HL,BC cannot be relied on here: both operands
    ; are well inside 24 bits.  Compare against the ceiling.
    or      a
    sbc     hl, de
    jr      z, @fits    ; exactly reaching the ceiling
    jr      nc, @full   ; past it
@fits:
    pop     hl          ; block address
    push    hl
    add     hl, bc
    ld      (heap0_ptr), hl         ; commit
    pop     hl

    ; zero the block
    ;
    ; "ld d,h / ld e,l" WOULD BE WRONG HERE.  It copies sixteen
    ; bits, and LDIR in ADL mode uses the whole 24-bit DE, so the
    ; destination would inherit whatever DEU happened to hold and
    ; the fill would land in some other segment entirely.  PUSH
    ; HL / POP DE moves all three bytes.  Same class of fault as
    ; handle_addr's, and the reason every address here is built
    ; from a full-width clear.
    push    hl
    push    bc
    ld      (hl), 0
    push    hl
    pop     de
    inc     de
    dec     bc
    ld      a, b
    or      c
    jr      z, @zeroed  ; a one-byte block is done
    ldir
@zeroed:
    pop     bc
    pop     hl

    pop     bc
    pop     de
    or      a           ; carry clear = success
    ret
@full:
    pop     hl
    pop     bc
    pop     de
    scf
    ret


; -----------------------------------------------------------------------------
; _g_drvnew -- build and install a drive that GENCPM knows nothing about.
;
;   HL = 16-bit address, in the currently selected CP/M segment, of a 15-byte
;        request block:
;
;     +00  db  drive          logical drive, 0 = A: through 15 = P:
;     +01  db  unit           relative drive number stored in the XDPH
;     +02  db  flags          bit 0: open the image for <unit> first, and
;     refuse to install the drive if it is not there
;     +03  dw  write          driver entry points, addresses in bank 0
;     +05  dw  read
;     +07  dw  login
;     +09  dw  init
;     +11  dw  dpb17-byte DPB, which MUST be in common memory
;     +13  dw  dtbl           address of the BIOS's @dtbl
;
; Returns A = 0 and Z set on success, or one of the DRV_ codes with NZ.
;
; The request block is read through the current segment, which at ?init time is
; bank 0 -- the same arrangement disk_io uses for its parameter block.
; -----------------------------------------------------------------------------
_g_drvnew:
    ; copy the request block out of the CP/M segment, then hand
    ; over to the core.
    ;
    ; THE SPLIT EXISTS FOR svc_dhook.  A request block built by a
    ; loadable driver lives in segment $04, which is not a CP/M
    ; segment, so the copy above cannot reach it: cur_seg names
    ; bank 0 or bank 1 and nothing else.  svc_dhook therefore fills
    ; dreq itself and calls drvnew_core directly.  Splitting the
    ; routine keeps ONE implementation of the drive-building logic;
    ; duplicating it for the driver path would guarantee the two
    ; drifted apart.
    ;
    ; The core returns with a plain RET so it can be called from
    ; ADL-mode code; only this gate entry ends with RET.LIL.
    ld      (tmp_src), hl
    ld      a, (cur_seg)
    ld      (tmp_src+2), a
    ld      hl, (tmp_src)
    ld      de, dreq
    ld      bc, 15
    ldir

    call    drvnew_core
    ret.lil


; -----------------------------------------------------------------------------
; drvnew_core -- build and install the drive described by dreq.
;
; Entered with the 15-byte request already in dreq.  Returns A = 0 and Z set
; on success, or a DRV_ code with NZ.  Ordinary RET.
; -----------------------------------------------------------------------------
drvnew_core:
    push    ix
    push    de
    push    bc

    ld      a, (dreq+0) ; drive must be a real letter
    cp      16
    jp      nc, @badparm

    ; refuse to displace a drive that already exists.  @dtbl holds
    ; one word per letter, so the entry is at dtbl + drive*2.
    call    dtbl_addr
    ld      (dreq_slot), hl
    ld      a, (hl)
    inc     hl
    or      (hl)
    jp      nz, @badparm

    ; the DPB has to describe a permanently mounted medium: a
    ; removable one needs a checksum vector, and CSV is one more
    ; thing this routine cannot put in common memory.  System
    ; Guide: bit 15 of CKS set means permanently mounted.
    ld      hl, (dreq+11)           ; DPB, in common
    ld      (tmp_src), hl
    ld      a, (cur_seg)
    ld      (tmp_src+2), a
    ld      hl, (tmp_src)
    ld      de, 12      ; CKS is at offset 11, high
    add     hl, de      ; byte at 12
    ld      a, (hl)
    and     $80
    jp      z, @notperm

    ; DSM, at DPB offset 5, sizes the allocation vector
    ld      hl, (tmp_src)
    ld      de, 5
    add     hl, de
    ld      e, (hl)
    inc     hl
    ld      d, (hl)
    ld      (dreq_dsm), de

    ; physical record size = 128 << PSH, PSH at DPB offset 15
    ld      hl, (tmp_src)
    ld      de, 15
    add     hl, de
    ld      a, (hl)
    ld      (dreq_psh), a
    ld      hl, 128
    or      a
    jr      z, @recsz
    ld      b, a
@shift:
    add     hl, hl
    djnz    @shift
@recsz:
    ld      (dreq_recsz), hl

    ; optionally prove the image is there before building anything
    ld      a, (dreq+2)
    and     $01
    jr      z, @noimgchk
    ld      bc, 0
    ld      a, (dreq+1)
    ld      c, a        ; C = relative drive
    call    drv_open
    or      a
    jp      nz, @noimage
@noimgchk:

    ; ---- allocation vector ----------------------------------
    ;
    ; (DSM/8)+1 bytes, DOUBLED.  The doubling is not optional
    ; here: gencpm.plm's get$alloc$chk allocates
    ;
    ;   alloc(i) = shr(dpb.dsm,3) + 1;
    ;   if dbl$alv or bnk$swt then alloc(i) = alloc(i) + alloc(i);
    ;
    ; and this is a banked system, so bnk$swt is true and the
    ; vector is always double whatever DBLALV was answered.  A
    ; single-length vector would be written past its end by the
    ; BDOS's free-space scan.
    ld      hl, (dreq_dsm)
    srl     h
    rr      l
    srl     h
    rr      l
    srl     h
    rr      l           ; HL = DSM/8
    inc     hl
    add     hl, hl      ; doubled
    push    hl
    pop     bc
    call    heap0_alloc
    jp      c, @noroom
    ld      (dreq_alv), hl

    ; ---- directory BCB and its buffer ------------------------
    ld      bc, (dreq_recsz)
    call    build_bcb
    jp      c, @noroom
    ld      (dreq_dirbcb), hl

    ; ---- data BCB, only if the medium is blocked -------------
    ;
    ; setbuf.plm: "if record(i).size = 80h then dph.dtabcb =
    ; 0ffffh" -- a drive whose physical record is already 128
    ; bytes needs no deblocking buffer, and M: is generated
    ; exactly that way.  Same rule here, driven by PSH.
    ld      hl, $FFFF
    ld      (dreq_dtabcb), hl
    ld      a, (dreq_psh)
    or      a
    jr      z, @nodta
    ld      bc, (dreq_recsz)
    call    build_bcb
    jp      c, @noroom
    ld      (dreq_dtabcb), hl
@nodta:

    ; ---- the XDPH itself -------------------------------------
    ;
    ; TEN bytes of prefix below a 25-byte DPH, so 35 in all.  The
    ; prefix size is not a matter of choice: bioskrnl.asm's
    ; d$init$loop reaches backwards from the DPH address with
    ;
    ;   dcx h ! dcx h ! mov a,m ! sta @RDRV   ; DPH-2
    ;   dcx h         ; DPH-3
    ;   mov d,m ! dcx h ! mov e,m ; init ptr at DPH-4
    ;
    ; so the layout is write, read, login and init as four words
    ; at DPH-10 through DPH-3, the relative drive at DPH-2 and the
    ; drive type at DPH-1.  agondsk.asm's static XDPHs emit
    ; exactly that.  This was written as 31 first, on a miscount
    ; of the prefix as six bytes, which would have left the DPH's
    ; last four fields -- DTABCB, HASH and HBANK -- lying in
    ; whatever was allocated next.
    ld      bc, 35
    call    heap0_alloc
    jp      c, @noroom
    ld      (dreq_xdph), hl

    ld      a, (dreq+3)
    ld      (hl), a
    inc     hl
    ld      a, (dreq+4)
    ld      (hl), a     ; +0 write
    inc     hl
    ld      a, (dreq+5)
    ld      (hl), a
    inc     hl
    ld      a, (dreq+6)
    ld      (hl), a     ; +2 read
    inc     hl
    ld      a, (dreq+7)
    ld      (hl), a
    inc     hl
    ld      a, (dreq+8)
    ld      (hl), a     ; +4 login
    inc     hl
    ld      a, (dreq+9)
    ld      (hl), a
    inc     hl
    ld      a, (dreq+10)
    ld      (hl), a     ; +6 init
    inc     hl
    ld      a, (dreq+1)
    ld      (hl), a     ; +8 relative drive
    inc     hl
    ld      (hl), 0     ; +9 drive type
    inc     hl          ; HL -> DPH proper

    push    hl          ; the DPH address
    ; XLT = 0 and the nine scratch bytes and MF are already zero
    ; from heap0_alloc; step over them to the DPB pointer.
    ld      de, 12
    add     hl, de
    ld      a, (dreq+11)
    ld      (hl), a
    inc     hl
    ld      a, (dreq+12)
    ld      (hl), a     ; DPB
    inc     hl
    ld      (hl), 0
    inc     hl
    ld      (hl), 0     ; CSV = 0, permanently mounted
    inc     hl
    ld      de, (dreq_alv)
    ld      (hl), e
    inc     hl
    ld      (hl), d     ; ALV
    inc     hl
    ld      de, (dreq_dirbcb)
    ld      (hl), e
    inc     hl
    ld      (hl), d     ; DIRBCB
    inc     hl
    ld      de, (dreq_dtabcb)
    ld      (hl), e
    inc     hl
    ld      (hl), d     ; DTABCB
    inc     hl
    ld      (hl), $FF
    inc     hl
    ld      (hl), $FF   ; HASH = 0FFFFh, hashing off
    inc     hl
    ld      (hl), 0     ; HBANK
    pop     hl          ; HL = DPH

    ; ---- publish it in @dtbl --------------------------------
    ;
    ; Last of all.  Until this store the drive does not exist as
    ; far as the BDOS is concerned, so a failure anywhere above
    ; leaves the system exactly as it was, minus some heap.
    ld      de, (dreq_slot)
    ld      a, l
    ld      (de), a
    inc     de
    ld      a, h
    ld      (de), a

    pop     bc
    pop     de
    pop     ix
    xor     a
    ret

@badparm:
    ld      a, DRV_BADPARM
    jr      @out
@noimage:
    ld      a, DRV_NOIMAGE
    jr      @out
@noroom:
    ld      a, DRV_NOROOM
    jr      @out
@notperm:
    ld      a, DRV_NOTPERM
@out:
    pop     bc
    pop     de
    pop     ix
    or      a
    ret


; -----------------------------------------------------------------------------
; build_bcb -- allocate a buffer of BC bytes, a buffer control block for it,
; and the list head that the DPH actually points at.
;
; Returns HL = the address to put in the DPH's DIRBCB or DTABCB field, which
; in a BANKED system is not the BCB but a two-byte pointer to it.  Measured on
; a generated system: A:'s DPH holds DIRBCB = F052, and F052 holds F058, which
; is where the BCB actually is.  setbuf.plm accounts for those two bytes
; separately from the BCBs themselves ("link$cnt * 2" in bcb$buf$siz).
;
; Carry set if the heap is exhausted; the heap is not rewound, but nothing has
; been published to the BDOS either, so the only cost is the lost bytes.
;
; ALL THREE ALLOCATIONS ARE MADE HERE rather than by the caller.  An earlier
; version took the buffer address in HL and left the caller holding it on the
; stack across the call, so a failure inside this routine returned with the
; caller's stack one entry deep and its POPs took the wrong values -- a fault
; that would only ever appear once the heap was nearly full.
; -----------------------------------------------------------------------------
build_bcb:
    push    de
    push    bc

    call    heap0_alloc ; the buffer
    jr      c, @fail
    ld      (bcb_buf), hl

    ld      bc, 15      ; the BCB proper
    call    heap0_alloc
    jr      c, @fail
    ld      (bcb_ptr), hl

    ld      (hl), $FF   ; +0  drv: nothing owns it yet
    ld      bc, 10
    add     hl, bc
    ld      de, (bcb_buf)
    ld      (hl), e
    inc     hl
    ld      (hl), d     ; +10 buffer address
    inc     hl
    ld      (hl), 0     ; +12 bank 0
    ; +1..+9 and +13,+14 are left as heap0_alloc found them, which
    ; is zero -- matching a GENCPM-built BCB byte for byte.

    ld      bc, 2       ; the list head
    call    heap0_alloc
    jr      c, @fail
    ld      de, (bcb_ptr)
    ld      (hl), e
    inc     hl
    ld      (hl), d
    dec     hl          ; HL = list head

    pop     bc
    pop     de
    or      a
    ret
@fail:
    pop     bc
    pop     de
    scf
    ret


; -----------------------------------------------------------------------------
; dtbl_addr -- HL = address of the @dtbl entry for the drive in dreq+0.
; -----------------------------------------------------------------------------
dtbl_addr:
    push    de
    ld      hl, 0       ; 24-bit clear: see handle_addr
    ld      a, (dreq+14)
    ld      h, a
    ld      a, (dreq+13)
    ld      l, a        ; HL = @dtbl, 16-bit
    ld      de, 0
    ld      a, (dreq+0)
    ld      e, a
    add     hl, de
    add     hl, de      ; two bytes per entry
    ld      (tmp_dst), hl
    ld      a, (cur_seg)
    ld      (tmp_dst+2), a
    ld      hl, (tmp_dst)
    pop     de
    ret


; =============================================================================
;  FID LOADING
; -----------------------------------------------------------------------------
;  Called once from the BIOS's ?init: the CP/M 3 equivalent of the moment the
;  PCW loads its own FIDs.  The BIOS and BDOS are present, the console works,
;  and the CCP has not started.  Drives installed by agon$newdrv have already
;  been added, so a driver sees the finished drive map.
;
;  The modules to load are named in FID.INI, one per line.  The name is
;  relative, so it is resolved against MOS's working directory -- the
;  directory CP/M was started from, which may be anywhere on the card.  A
;  list file needs only mos_fopen and mos_fread, and it makes LOAD ORDER
;  EXPLICIT, which matters because order decides device numbering.  Blank
;  lines and lines starting ';' or '#' are ignored.
; =============================================================================

; -----------------------------------------------------------------------------
; _g_fidinit -- HL = 16-bit address, in the current CP/M segment, of the
; character half of the BIOS descriptor, which is fid$desc in agonchr.asm:
;
;     +00  dw  @ctbl      the BIOS character device table
;     +02  db  builtin    devices the BIOS provides itself
;     +03  db  spare      spare @ctbl slots the BIOS has reserved
;     +04  dw  ddesc      the disc half, fid$ddesc in agondsk.asm
;
; and the disc half, read through that pointer, is:
;
;     +00  dw  @dtbl      the BIOS drive table
;     +02  dw  dpbpool    DPB slots, in COMMON memory
;     +04  db  nslot      how many slots there are
;     +05  db  firstauto  lowest drive letter that may be assigned
;                         automatically; see FIRSTAUTO in agondsk.asm
;     +06  dw  write      the four shared drive stubs, Z80 code in
;     +08  dw  read       bank 0, that every FID drive's XDPH points at
;     +10  dw  login
;     +12  dw  init
;
; TWO DESCRIPTORS RATHER THAN ONE, because RMAC cannot export an equate:
; the character counts are equates in agonchr.asm and the slot count and
; drive floor are equates in agondsk.asm, so a single flat block would have
; to duplicate one pair or the other and keep the copies equal by hand.
;
; BOTH COPY LENGTHS BELOW MUST MATCH THE BLOCKS THEY READ.  This is the
; failure the descriptor was designed to make impossible in the other
; direction, so it is worth saying plainly: change a descriptor, change the
; length here, and check the module size changed after the edit.
;
; Returns A = number of modules installed.
; -----------------------------------------------------------------------------
_g_fidinit:
    push    ix
    push    hl
    push    de
    push    bc

    ld      (tmp_src), hl
    ld      a, (cur_seg)
    ld      (tmp_src+2), a
    ld      hl, (tmp_src)
    ld      de, fdesc
    ld      bc, 6       ; SIX, matching fid$desc
    ldir

    ; follow the pointer to the disc half, which is in the same
    ; CP/M segment
    ld      hl, 0
    ld      a, (fdesc+5)
    ld      h, a
    ld      a, (fdesc+4)
    ld      l, a
    ld      (tmp_src), hl
    ld      a, (cur_seg)
    ld      (tmp_src+2), a
    ld      hl, (tmp_src)
    ld      de, fddesc
    ld      bc, 14      ; FOURTEEN, matching fid$ddesc
    ldir

    ; No drive has a driver until one asks for it, and no DPB slot
    ; is spoken for.  Cleared here rather than relying on the
    ; initial values so that this is correct if the loader is ever
    ; called twice.
    xor     a
    ld      (fid_ndrv), a
    ld      (dpb_used), a
    ld      hl, fid_ddrv
    ld      de, fid_ddrv+1
    ld      bc, NDRIVELET*12-1
    ld      (hl), 0
    ldir

    ; The BIOS owns the table space and this owns the handler
    ; space, so take whichever count is smaller rather than
    ; trusting either side alone.
    ld      a, (fdesc+3)
    cp      MAXFIDDEV+1
    jr      c, @spareok
    ld      a, MAXFIDDEV
    ld      (fdesc+3), a
@spareok:
    xor     a
    ld      (fid_count), a
    ld      (fid_ndev), a

    ld      hl, CCP_END ; the heap is the free tail of
    ld      (fid_ptr), hl           ; segment $04, above the CCP
    ld      a, FID_SEG  ; buffer
    ld      (fid_ptr+2), a

    call    fid_getcwd
    call    fid_loadlist

    ld      a, (fid_count)
    pop     bc
    pop     de
    pop     hl
    pop     ix
    ret.lil


; -----------------------------------------------------------------------------
; fid_getcwd -- fetch the working directory, once, for canonicalising names.
;
; Without it a relative name can never be reconciled with an absolute one:
; "fid/X.FID" and "/cpm3/fid/X.FID" may be the same file, but nothing in the
; strings says so.  With it, every relative name is resolved against the
; working directory before comparison and all spellings agree.
;
; A failure is not fatal -- fid_cwd is simply left empty and canonicalisation
; falls back to comparing relative names against each other, which is what it
; did before and still catches the common cases.
; -----------------------------------------------------------------------------
fid_getcwd:
    push    hl
    push    de
    push    bc
    xor     a
    ld      (fid_cwd), a; empty until proven otherwise
    ld      hl, fid_cwd
    ld      bc, FIDNAME_MAX
    call    mos_enter
    MOSCALL ffs_getcwd
    call    mos_leave
    or      a
    jr      z, @out
    xor     a           ; failed: leave it empty
    ld      (fid_cwd), a
@out:
    pop     bc
    pop     de
    pop     hl
    ret


; -----------------------------------------------------------------------------
; fid_loadlist -- read FID.INI and load each module it names.
; An absent list file is not an error: it means no drivers.
; -----------------------------------------------------------------------------
; EVERY MOS CALL BELOW IS BRACKETED BY mos_enter/mos_leave.
;
; MOS requires MBASE to be zero for its API calls.  The loader runs from the
; BIOS's ?init, which is to say DURING CP/M, when MBASE holds the CP/M bank --
; $06 or $05, never 0.  drv_open and disk_io bracket for exactly this reason.
; Without it mos_fopen returns a zero handle, the routine takes its "no list
; file" exit, and the whole mechanism does nothing at all without a word of
; complaint.
;
; The rule is: any MOS call reachable after the jump into CP/M must bracket.
; load_system, load_ccp and read_record need not, and do not, because they run
; from _start while MBASE is still zero.
fid_loadlist:
    ld      hl, fidlist
    ld      bc, 0
    ld      c, fa_read
    call    mos_enter
    MOSCALL mos_fopen
    call    mos_leave
    or      a
    jp      z, @nolist  ; JP, not JR: the list-building
; and loading code between here
; and @nolist puts it out of
; relative range
    ld      (fidhandle), a

    ld      bc, 0
    ld      c, a
    ld      hl, fidlbuf
    ld      de, FIDLBUF_MAX
    call    mos_enter
    MOSCALL mos_fread   ; DE = bytes actually read
    call    mos_leave
    push    de

    ld      bc, 0
    ld      a, (fidhandle)
    ld      c, a
    call    mos_enter
    MOSCALL mos_fclose
    call    mos_leave
    pop     de

    ld      hl, fidlbuf
    ld      (fidl_ptr), hl
    add     hl, de
    ld      (fidl_end), hl

@nextline:
    call    fid_getline
    jr      z, @built   ; buffer exhausted
    ld      a, (fidname)
    or      a
    jr      z, @nextline; blank
    cp      ';'
    jr      z, @nextline
    cp      '#'
    jr      z, @nextline

    ; A pattern contributes every file it matches; a plain name
    ; contributes itself.  NOTHING IS LOADED YET.
    call    fid_haswild
    jr      z, @plain
    call    fid_expand
    jr      @nextline
@plain:
    call    fid_addlist
    jr      @nextline

@built:
    ; ---- second phase: load the list ----
    ;
    ; The whole list is built, in the order the file names things
    ; and with duplicates already dropped, before a single module
    ; is opened.  Deciding what to load and then loading it are
    ; two separate jobs, and mixing them was what made the earlier
    ; version need a match buffer per pattern.
    ld      a, (fid_nlist)
    or      a
    ret     z
    ld      b, a
    ld      c, 0
@loadloop:
    push    bc
    ld      de, 0
    ld      a, c
    ld      e, a
    call    mul_de_name
    ld      de, fid_list
    add     hl, de      ; HL -> the entry
    ld      de, fidname
    ld      b, FIDNAME_MAX
    call    fid_cat
    call    fid_load
    pop     bc
    inc     c
    djnz    @loadloop
    ret

@nolist:
    ; A missing list file means no drivers, which is an ordinary
    ; configuration and not worth a word.
    ret


; -----------------------------------------------------------------------------
; fid_addlist -- add fidname to the load list unless it is already there.
;
; The comparison is made on a CANONICAL form of each name, not on the text as
; written, so that the same file written two ways is recognised as one:
;
;   fids/X.FID   ./fids/X.FID   FIDS\X.FID   fids//X.FID   fids/./X.FID
;
; all reduce to FIDS/X.FID.  Case is folded because FAT is case-insensitive,
; separators are folded to '/', repeated separators collapse, and "." segments
; are dropped.
;
; WHAT IT DOES NOT CATCH: ".." is not resolved, and a relative name is never
; reconciled with an absolute one -- "X.FID" and "/cpm3/X.FID" may be the same
; file but cannot be known to be without asking MOS for the working
; directory.  Both would load twice.  The name stored for opening is always
; the one as written; the canonical form exists only to compare.
; -----------------------------------------------------------------------------
fid_addlist:
    push    hl
    push    de
    push    bc

    ld      hl, fidname
    ld      de, fid_canon
    call    fid_canonise

    ld      a, (fid_nlist)
    or      a
    jr      z, @append
    ld      b, a
    ld      c, 0
@each:
    push    bc
    ld      de, 0
    ld      a, c
    ld      e, a
    call    mul_de_name
    ld      de, fid_list
    add     hl, de      ; HL -> stored name
    ld      de, fid_canon2
    call    fid_canonise
    ld      hl, fid_canon
    ld      de, fid_canon2
    call    fid_samename
    pop     bc
    jr      z, @out     ; already listed
    inc     c
    djnz    @each

@append:
    ld      a, (fid_nlist)
    cp      MAXFIDS
    jr      nc, @out    ; list full: silently ignore
    ld      de, 0
    ld      e, a
    call    mul_de_name
    ld      de, fid_list
    add     hl, de
    ex      de, hl      ; DE -> the free slot
    ld      hl, fidname
    ld      b, FIDNAME_MAX
    call    fid_cat
    ld      a, (fid_nlist)
    inc     a
    ld      (fid_nlist), a
@out:
    pop     bc
    pop     de
    pop     hl
    ret


; -----------------------------------------------------------------------------
; fid_isep -- Z if A is a path separator.  A is preserved.
; -----------------------------------------------------------------------------
fid_isep:
    cp      '/'
    ret     z
    cp      $5C         ; backslash, spelled
    ret     ; numerically to keep the
; assembler's escape rules out


; -----------------------------------------------------------------------------
; fid_canonise -- write a canonical form of the string at HL into the buffer at
; DE.  Separators become '/', runs of them collapse, "." segments vanish, and
; letters are folded to upper case.  A leading separator is kept, since it
; distinguishes an absolute name from a relative one.
; -----------------------------------------------------------------------------
fid_canonise:
    push    af
    push    hl
    push    de
    push    bc
    ld      (fid_cstart), de
    ld      b, FIDNAME_MAX

    ld      a, (hl)
    call    fid_isep
    jr      z, @absolute

    ; A RELATIVE NAME IS RESOLVED AGAINST THE WORKING DIRECTORY,
    ; so that "fid/X.FID" and "/cpm3/fid/X.FID" reduce to the same
    ; thing.  The working directory is itself absolute and already
    ; ends without a trailing separator, so it is emitted through
    ; the same segment machinery below by simply canonicalising it
    ; first and then continuing with the name.
    ld      a, (fid_cwd)
    or      a
    jr      z, @seg     ; no working directory known
    push    hl
    ld      hl, fid_cwd
    call    @copyabs
    pop     hl
    jr      @seg

@absolute:
    ld      a, '/'      ; keep a leading separator
    ld      (de), a
    inc     de
    dec     b
    inc     hl
    jr      @seg

; copy an already-absolute path at HL into the output, folding case and
; normalising separators, leaving DE at its end
@copyabs:
    ld      a, (hl)
    or      a
    ret     z
    call    fid_isep
    jr      nz, @absch
    ld      a, '/'
@absch:
    call    fid_upper
    ld      c, a
    ld      a, b
    cp      2
    ret     c
    ld      a, c
    ld      (de), a
    inc     de
    dec     b
    inc     hl
    jr      @copyabs

@seg:
    ld      a, (hl)     ; skip any run of separators
    or      a
    jr      z, @done
    call    fid_isep
    jr      nz, @haveseg
    inc     hl
    jr      @seg

@haveseg:
    ld      a, (hl)     ; is the segment just "."?
    cp      '.'
    jr      nz, @emitseg
    inc     hl
    ld      a, (hl)
    dec     hl
    or      a
    jr      z, @skipdot
    call    fid_isep
    jr      nz, @emitseg
@skipdot:
    inc     hl          ; drop it and go round again
    jr      @seg

@emitseg:
    push    hl          ; separator needed first?
    ld      hl, (fid_cstart)
    or      a
    sbc     hl, de
    pop     hl
    jr      z, @copyseg ; nothing written yet
    dec     de
    ld      a, (de)
    inc     de
    cp      '/'
    jr      z, @copyseg
    ld      a, b
    cp      2
    jr      c, @done
    ld      a, '/'
    ld      (de), a
    inc     de
    dec     b

@copyseg:
    ld      a, (hl)
    or      a
    jr      z, @done
    call    fid_isep
    jr      z, @seg     ; segment ended
    call    fid_upper
    ld      c, a
    ld      a, b
    cp      2
    jr      c, @done    ; no room left
    ld      a, c
    ld      (de), a
    inc     de
    dec     b
    inc     hl
    jr      @copyseg

@done:
    xor     a
    ld      (de), a
    pop     bc
    pop     de
    pop     hl
    pop     af
    ret


; -----------------------------------------------------------------------------
; fid_getline; -----------------------------------------------------------------------------
; fid_getline -- copy the next line into fidname, null terminated.
; NZ if a line was produced, Z when the buffer is exhausted.
; Control characters are dropped, so a file written with either line ending,
; or with a stray tab, still parses.
; -----------------------------------------------------------------------------
fid_getline:
    ld      hl, (fidl_ptr)
    ld      de, (fidl_end)
    or      a
    sbc     hl, de
    jr      nc, @none

    ld      hl, (fidl_ptr)
    ld      de, fidname
    ld      b, 0
@ch:
    push    hl
    ld      bc, (fidl_end)
    or      a
    sbc     hl, bc
    pop     hl
    jr      nc, @eol
    ld      a, (hl)
    cp      13
    jr      z, @eol
    cp      10
    jr      z, @eol
    cp      32
    jr      c, @skipch  ; other control character
    ld      c, a
    ld      a, b
    cp      FIDNAME_MAX-1
    jr      nc, @skipch ; name buffer full
    ld      a, c
    ld      (de), a
    inc     de
    inc     b
@skipch:
    inc     hl
    jr      @ch
@eol:
    xor     a
    ld      (de), a
@skip:
    push    hl
    ld      bc, (fidl_end)
    or      a
    sbc     hl, bc
    pop     hl
    jr      nc, @fin
    ld      a, (hl)
    cp      13
    jr      z, @eat
    cp      10
    jr      nz, @fin
@eat:
    inc     hl
    jr      @skip
@fin:
    ld      (fidl_ptr), hl
    or      1           ; NZ = a line was produced
    ret
@none:
    xor     a
    ret


; -----------------------------------------------------------------------------
; fid_haswild -- Z if fidname holds no wildcard, NZ if it holds * or ?
; -----------------------------------------------------------------------------
fid_haswild:
    push    hl
    ld      hl, fidname
@scan:
    ld      a, (hl)
    or      a
    jr      z, @none
    cp      '*'
    jr      z, @yes
    cp      '?'
    jr      z, @yes
    inc     hl
    jr      @scan
@yes:
    pop     hl
    or      1           ; NZ
    ret
@none:
    pop     hl
    xor     a           ; Z
    ret


; -----------------------------------------------------------------------------
; fid_expand -- treat fidname as a pattern and load everything it matches in
; the current directory.
;
; TWO PASSES, DELIBERATELY.  The directory is enumerated to completion first
; and the names collected, and only then are the modules opened and read.
; Interleaving the two would mean holding a FatFS DIR open across f_open,
; f_read and f_close on another file, and MOS builds FatFS with FF_FS_TINY,
; where every object shares one window buffer.  FatFS is documented to cope
; with that, but "documented to cope" is a poorer thing to rely on than not
; doing it at all, and the second buffer costs 512 bytes of a segment with
; 52K spare.
;
; A line with no directory part is given the path ".", which FatFS resolves
; to the current directory because MOS sets FF_FS_RPATH to 2.  That is what
; makes a pattern pick up drivers sitting beside cpm3.bin rather than in the
; card root.  It must be "." and not an empty string -- see the note at the
; declaration of fid_path.
; -----------------------------------------------------------------------------
fid_expand:
    push    ix
    push    bc
    push    de
    push    hl

    ; Split the line into a directory and a pattern.  f_findfirst
    ; takes them SEPARATELY and matches the pattern against bare
    ; filenames only, so a line with a separator in it cannot be
    ; passed whole.
    call    fid_split

    ld      hl, fid_dirbuf
    ld      de, fid_finfo
    ld      bc, fid_dir
    ld      ix, fid_pat
    call    mos_enter
    MOSCALL ffs_dfindfirst
    call    mos_leave

@each:
    or      a
    jr      nz, @out    ; FRESULT non-zero: stop
    ld      a, (fid_finfo+FI_FNAME)
    or      a
    jr      z, @out     ; empty name: no more matches

    ld      a, (fid_finfo+FI_ATTRIB)
    and     AM_DIR
    jr      nz, @next   ; a subdirectory, not a driver

    call    fid_buildname
    call    fid_addlist

@next:
    ld      hl, fid_dirbuf
    ld      de, fid_finfo
    call    mos_enter
    MOSCALL ffs_dfindnext
    call    mos_leave
    jr      @each

@out:
    pop     hl
    pop     de
    pop     bc
    pop     ix
    ret


; -----------------------------------------------------------------------------
; fid_buildname -- put the directory back on the front of the matched name.
;
; FILINFO returns the BARE FILENAME, so a module found in a subdirectory would
; be listed under a name that could not then be opened.  The result goes into
; fidname, which the pattern and directory have already been copied out of.
; -----------------------------------------------------------------------------
fid_buildname:
    push    hl
    push    de
    push    bc

    ld      de, fidname
    ld      b, FIDNAME_MAX
    ld      a, (fid_dir)
    cp      '.'
    jr      nz, @withdir
    ld      a, (fid_dir+1)
    or      a
    jr      z, @bare    ; the directory is just "."
@withdir:
    ld      hl, fid_dir
    call    fid_cat
    dec     de          ; the last character written
    ld      a, (de)
    inc     de
    call    fid_isep
    jr      z, @bare    ; it already ends in one
    ld      a, b
    cp      2
    jr      c, @bare
    ld      a, '/'
    ld      (de), a
    inc     de
    dec     b
@bare:
    ld      hl, fid_finfo+FI_FNAME
    call    fid_cat

    pop     bc
    pop     de
    pop     hl
    ret


; -----------------------------------------------------------------------------
; fid_samename -- compare the strings at HL and DE, folding case.  Z if equal.
; -----------------------------------------------------------------------------
fid_samename:
    push    hl
    push    de
    push    bc
@cmp:
    ld      a, (hl)
    call    fid_upper
    ld      b, a
    ld      a, (de)
    call    fid_upper
    cp      b
    jr      nz, @differ
    or      a
    jr      z, @same    ; both ended together
    inc     hl
    inc     de
    jr      @cmp
@same:
    pop     bc
    pop     de
    pop     hl
    xor     a
    ret
@differ:
    pop     bc
    pop     de
    pop     hl
    or      1
    ret


; fid_upper -- fold A to upper case.
fid_upper:
    cp      'a'
    ret     c
    cp      'z'+1
    ret     nc
    sub     'a'-'A'
    ret


; mul_de_name -- HL = DE * FIDNAME_MAX (64), by shifts.
mul_de_name:
    push    de
    ex      de, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl      ; *64
    pop     de
    ret


; -----------------------------------------------------------------------------
; fid_cat -- append the string at HL to DE, with B bytes of room remaining.
;
; On return DE points at the terminating zero and B is the room still left, so
; several pieces can be joined without any of them running past the end of the
; buffer.
; -----------------------------------------------------------------------------
fid_cat:
@c:
    ld      a, b
    cp      2           ; room for a character and a
    jr      c, @e       ; terminator?
    ld      a, (hl)
    or      a
    jr      z, @e
    ld      (de), a
    inc     hl
    inc     de
    dec     b
    jr      @c
@e:
    xor     a
    ld      (de), a
    ret


; -----------------------------------------------------------------------------
; fid_split -- divide fidname into a directory and a pattern.
;
; f_findfirst TAKES THE DIRECTORY AND THE PATTERN SEPARATELY, and matches the
; pattern against bare filenames only.  A line like "fids/*.FID" passed whole
; as the pattern can therefore never match anything -- which is exactly how it
; behaved.  The line is split at its last separator instead:
;
;   *.FID  ->  directory ".",      pattern "*.FID"
;   fids/*.FID         ->  directory "fids",   pattern "*.FID"
;   /fids/*.FID        ->  directory "/fids",  pattern "*.FID"
;   /*.FID ->  directory "/",      pattern "*.FID"
;
; Both separators are accepted, since MOS takes either.
; -----------------------------------------------------------------------------
fid_split:
    push    hl
    push    de
    push    bc

    xor     a
    ld      (fid_hassep), a
    ld      hl, fidname
@scan:
    ld      a, (hl)
    or      a
    jr      z, @split
    cp      '/'
    jr      z, @mark
    cp      '\\'
    jr      nz, @next
@mark:
    ld      (fid_sep), hl
    ld      a, 1
    ld      (fid_hassep), a
@next:
    inc     hl
    jr      @scan

@split:
    ld      a, (fid_hassep)
    or      a
    jr      z, @nodir

    ; directory: everything before the last separator
    ld      hl, fidname
    ld      de, fid_dir
    ld      b, FIDNAME_MAX
@copydir:
    push    hl
    ld      bc, (fid_sep)
    or      a
    sbc     hl, bc
    pop     hl
    jr      nc, @dirend
    ld      a, b
    cp      2
    jr      c, @dirend
    ld      a, (hl)
    ld      (de), a
    inc     hl
    inc     de
    dec     b
    jr      @copydir
@dirend:
    xor     a
    ld      (de), a

    ; a leading separator leaves the directory empty: that is the
    ; root, not the current directory
    ld      a, (fid_dir)
    or      a
    jr      nz, @pattern
    ld      a, '/'
    ld      (fid_dir), a
    xor     a
    ld      (fid_dir+1), a
@pattern:
    ld      hl, (fid_sep)
    inc     hl          ; past the separator
    ld      de, fid_pat
    ld      b, FIDNAME_MAX
    call    fid_cat
    jr      @out

@nodir:
    ld      hl, fid_path; "."
    ld      de, fid_dir
    ld      b, FIDNAME_MAX
    call    fid_cat
    ld      hl, fidname
    ld      de, fid_pat
    ld      b, FIDNAME_MAX
    call    fid_cat
@out:
    pop     bc
    pop     de
    pop     hl
    ret


; -----------------------------------------------------------------------------
; fid_field -- BC = header offset, returns HL = the 24-bit value there.
; -----------------------------------------------------------------------------
fid_field:
    ld      hl, (fidbase)
    add     hl, bc
    ld      hl, (hl)
    ret


; -----------------------------------------------------------------------------
; fid_load -- load, relocate and start the module named in fidname.
;
; Every failure is reported and skipped.  One bad driver must not stop the
; others, and must certainly not stop the system booting.
; -----------------------------------------------------------------------------
fid_load:
    ld      hl, (fid_ptr)
    ld      (fidbase), hl

    ld      hl, fidname
    ld      bc, 0
    ld      c, fa_read
    call    mos_enter
    MOSCALL mos_fopen
    call    mos_leave
    or      a
    jp      z, @noopen
    ld      (fidhandle), a

    ld      hl, FID_TOP ; read into what is left
    ld      de, (fid_ptr)
    or      a
    sbc     hl, de
    ex      de, hl      ; DE = space remaining
    ld      hl, (fid_ptr)
    ld      bc, 0
    ld      a, (fidhandle)
    ld      c, a
    call    mos_enter
    MOSCALL mos_fread   ; DE = bytes actually read
    call    mos_leave
    ld      (fid_flen), de

    ld      bc, 0
    ld      a, (fidhandle)
    ld      c, a
    call    mos_enter
    MOSCALL mos_fclose
    call    mos_leave

    ld      hl, (fid_flen)          ; shorter than a header?
    ld      de, FIDH_LEN
    or      a
    sbc     hl, de
    jp      c, @badfile

    ld      hl, (fidbase)           ; signature
    ld      de, FIDH_SIG
    add     hl, de
    ld      de, fidsig
    ld      b, 8
@sig:
    ld      a, (de)
    cp      (hl)
    jp      nz, @badsig
    inc     hl
    inc     de
    djnz    @sig

    call    fid_checksum
    jp      nz, @badsum

    ld      hl, (fidbase)           ; API version
    ld      de, FIDH_APIV
    add     hl, de
    ld      a, (hl)
    cp      FID_API
    jp      nz, @badapi
    inc     hl
    ld      a, (hl)
    or      a
    jp      nz, @badapi

    ; --- relocate ---
    ;
    ; delta = where it landed less where it was linked.  Each
    ; fixup names the offset of a 24-bit field holding an address
    ; inside the module.  References to the SVC table need no
    ; fixup: that address is fixed for all time.
    ld      bc, FIDH_LINK
    call    fid_field
    ex      de, hl
    ld      hl, (fidbase)
    or      a
    sbc     hl, de
    ld      (fid_delta), hl

    ld      bc, FIDH_RCNT
    call    fid_field
    ld      (fid_rcnt), hl

    ld      bc, FIDH_RELOC
    call    fid_field
    ex      de, hl
    ld      hl, (fidbase)
    add     hl, de
    ld      (fid_rptr), hl
@reloc:
    ld      hl, (fid_rcnt)
    ld      a, l
    or      h
    jr      z, @relocdone
    dec     hl
    ld      (fid_rcnt), hl

    ld      hl, (fid_rptr)
    ld      de, (hl)    ; offset within the module
    inc     hl
    inc     hl
    inc     hl
    ld      (fid_rptr), hl

    ld      hl, (fidbase)
    add     hl, de      ; -> the field to patch
    push    hl
    ld      de, (hl)
    ld      hl, (fid_delta)
    add     hl, de
    ex      de, hl
    pop     hl
    ld      (hl), de
    jr      @reloc
@relocdone:

    ; --- zero the uninitialised area ---
    ;
    ; AFTER relocation, never before.  The bss starts at
    ; image_len and the fixup table normally sits there too, so
    ; zeroing first would erase the list being applied.
    ld      bc, FIDH_BSS
    call    fid_field
    push    hl
    pop     bc          ; BC = bss length
    ld      a, b
    or      c
    jr      z, @nobss
    push    bc
    ld      bc, FIDH_IMAGE
    call    fid_field
    ex      de, hl
    ld      hl, (fidbase)
    add     hl, de      ; -> first bss byte
    pop     bc
    ld      (hl), 0
    push    hl
    pop     de
    inc     de
    dec     bc
    ld      a, b
    or      c
    jr      z, @nobss
    ldir
@nobss:

    ; --- where the next module would go ---
    ld      bc, FIDH_IMAGE
    call    fid_field
    push    hl
    ld      bc, FIDH_BSS
    call    fid_field
    pop     de
    add     hl, de      ; image + bss
    ld      de, (fidbase)
    add     hl, de
    ld      (fid_next), hl

    ; --- start it ---
    ;
    ; THE HEAP POINTER IS ADVANCED BEFORE THE MODULE RUNS, not after.
    ;
    ; Advancing it on the way out would let a module that declines
    ; reclaim its space by doing nothing, but it would leave fid_ptr
    ; pointing AT THE MODULE ITSELF for the whole of its entry
    ; routine, so svc_alloc would hand a driver its own code.  A
    ; driver that then filled its allocation would overwrite the very
    ; instructions doing the filling.
    ;
    ; Reclaiming a declined module is explicit instead: fid_ptr goes
    ; back to fidbase, which also releases anything the module
    ; allocated before deciding to decline.  The module is gone, and
    ; so is everything it asked for.
    ld      hl, (fid_next)
    ld      (fid_ptr), hl

    ld      hl, (fidbase)
    call    fid_call
    push    af
    ld      a, h        ; HL = sign-on message, or 0
    or      l
    jr      z, @nomsg
    call    fid_pmsg
    ld      hl, fidcrlf
    call    fid_pmsg
@nomsg:
    pop     af
    or      a
    jr      nz, @dropped
    ld      a, (fid_count)
    inc     a
    ld      (fid_count), a
    ret

@dropped:
    ; declined: put the heap back, reclaiming the module and
    ; anything it allocated
    ld      hl, (fidbase)
    ld      (fid_ptr), hl
    ret

@noopen:
    ld      hl, msg_fidopen
    jr      @report
@badfile:
    ld      hl, msg_fidshort
    jr      @report
@badsig:
    ld      hl, msg_fidsig
    jr      @report
@badsum:
    ld      hl, msg_fidsum
    jr      @report
@badapi:
    ld      hl, msg_fidapi
@report:
    push    hl
    ld      hl, fidname
    call    fid_pmsg
    pop     hl
    call    fid_pmsg
    ld      hl, fidcrlf
    call    fid_pmsg
    ret


; -----------------------------------------------------------------------------
; fid_checksum -- Z set if the file matches the sum stored at FIDH_SUM.
;
; The stored value is the 16-bit sum of every byte of the file WITH ITS OWN
; TWO BYTES COUNTED AS ZERO, which lets the check be done as one pass over
; everything followed by subtracting the two stored bytes back out, rather
; than testing an offset on every byte.
; -----------------------------------------------------------------------------
fid_checksum:
    push    bc
    push    de
    push    hl

    ld      hl, (fidbase)
    ld      bc, (fid_flen)
    ld      de, 0
@sum:
    ld      a, b
    or      c
    jr      z, @summed
    ld      a, (hl)
    push    hl
    ld      hl, 0
    ld      l, a
    add     hl, de
    ex      de, hl
    pop     hl
    inc     hl
    dec     bc
    jr      @sum
@summed:
    ld      (fid_sum), de           ; truncate to 16 bits by
    ld      hl, 0       ; reloading only two bytes
    ld      a, (fid_sum)
    ld      l, a
    ld      a, (fid_sum+1)
    ld      h, a
    push    hl          ; total, 16 bits

    ld      hl, (fidbase)           ; the stored value
    ld      bc, FIDH_SUM
    add     hl, bc
    ld      c, (hl)
    inc     hl
    ld      b, (hl)
    push    bc

    ld      hl, 0       ; low byte plus high byte
    ld      l, c
    ld      a, b
    ld      c, a
    ld      b, 0
    add     hl, bc
    ex      de, hl      ; DE = the two stored bytes

    pop     bc          ; BC = stored sum
    pop     hl          ; HL = total
    or      a
    sbc     hl, de      ; total with the field zeroed
    or      a
    sbc     hl, bc      ; compare with what was stored
    ld      (fid_sum), hl
    ld      a, (fid_sum)
    ld      hl, 0
    ld      l, a
    ld      a, (fid_sum+1)
    or      l           ; low 16 bits zero = match

    pop     hl
    pop     de
    pop     bc
    ret


; -----------------------------------------------------------------------------
; fid_call -- call the module entry at HL, preserving A.
; There is no CALL (HL) on this processor, so the return address is pushed by
; hand and the entry reached with JP (HL).
; -----------------------------------------------------------------------------
fid_call:
    ld      (fid_entry), hl
    ld      hl, @back
    push    hl
    ld      hl, (fid_entry)
    jp      (hl)
@back:
    ret


; fid_pmsg -- print the null-terminated string at HL, in segment $04.
fid_pmsg:
    push    af
    push    bc
    push    hl
@loop:
    ld      a, (hl)
    or      a
    jr      z, @done
    ld      c, a
    push    hl
    call    conout_char
    pop     hl
    inc     hl
    jr      @loop
@done:
    pop     hl
    pop     bc
    pop     af
    ret


; =============================================================================
;  SVC IMPLEMENTATIONS
; =============================================================================

_svc_version:
    ld      hl, FID_API
    or      a
    ret

_svc_pmsg:
    call    fid_pmsg
    or      a
    ret

; _svc_alloc -- BC bytes from the segment $04 heap.  HL = address, carry set
; if it will not fit.  A driver uses this for anything only it will touch.
_svc_alloc:
    push    de
    ld      hl, (fid_ptr)
    push    hl
    add     hl, bc
    ld      de, FID_TOP
    or      a
    sbc     hl, de
    jr      z, @fits
    jr      nc, @full
@fits:
    pop     hl
    push    hl
    add     hl, bc
    ld      (fid_ptr), hl
    pop     hl
    pop     de
    or      a
    ret
@full:
    pop     hl
    pop     de
    scf
    ret

; _svc_alloc0 -- BC bytes from the bank-0 heap, for anything the BDOS has to
; reach with a 16-bit address.
_svc_alloc0:
    jp      heap0_alloc

_svc_conout:
    push    bc
    ld      c, a
    call    conout_char
    pop     bc
    or      a
    ret

_svc_conin:
    call    conin_char
    or      a
    ret

_svc_const:
    call    const_char
    or      a
    ret

_svc_mosenter:
    jp      mos_enter

_svc_mosleave:
    jp      mos_leave


; -----------------------------------------------------------------------------
; _svc_chook -- add a character device.  HL points at, in segment $04:
;
;     +00  6 bytes  name, space padded
;     +06  db       mode byte   (System Guide Table 4-7, or modebaud.lib)
;     +07  db       baud byte
;     +08  dl       input routine        -> A = character
;     +0B  dl       output routine       A = character
;     +0E  dl       input status         -> A = 0FFh if ready
;     +11  dl       output status        -> A = 0FFh if ready
;
; Returns A = the device number CP/M will know it by, carry clear.  Carry set
; if no slot is free.
; -----------------------------------------------------------------------------
_svc_chook:
    push    ix
    push    bc
    push    de
    ld      (fid_req), hl

    ld      a, (fid_ndev)
    ld      b, a
    ld      a, (fdesc+3); slots the BIOS reserved
    cp      b
    jr      z, @full
    jr      c, @full

    ld      de, 0       ; handler addresses ->
    ld      a, (fid_ndev)           ; fid_cdev[ndev]
    ld      e, a
    call    mul_de_12
    ld      de, fid_cdev
    add     hl, de
    ex      de, hl
    ld      hl, (fid_req)
    ld      bc, 8
    add     hl, bc
    ld      bc, 12
    ldir

    ; Write the table entry into BOTH bank copies of common.  The
    ; registered mutable region would carry it across on the next
    ; switch, but only in the direction of travel, and relying on
    ; that would make correctness depend on which bank happened to
    ; be current when the driver installed itself.
    ld      a, SEG_BANK0
    call    fid_ctbl_write
    ld      a, SEG_BANK1
    call    fid_ctbl_write

    ld      a, (fdesc+2); assigned device number
    ld      b, a
    ld      a, (fid_ndev)
    add     a, b
    push    af
    ld      a, (fid_ndev)
    inc     a
    ld      (fid_ndev), a
    pop     af
    pop     de
    pop     bc
    pop     ix
    or      a
    ret
@full:
    pop     de
    pop     bc
    pop     ix
    scf
    ret


; -----------------------------------------------------------------------------
; fid_ctbl_write -- copy the eight-byte entry at fid_req into @ctbl in the
; segment named in A, overwriting the terminator and writing a fresh one.
;
; The terminator is moved rather than the spare entries being pre-named, so
; DEVICE shows nothing extra on a system with no drivers loaded.
; -----------------------------------------------------------------------------
fid_ctbl_write:
    push    hl
    push    de
    push    bc
    ld      c, a        ; segment

    ld      hl, 0
    ld      a, (fdesc+1)
    ld      h, a
    ld      a, (fdesc+0)
    ld      l, a
    ld      (ctbl_dst), hl          ; three bytes: segment last
    ld      a, c
    ld      (ctbl_dst+2), a

    ld      a, (fdesc+2); entries already present
    ld      b, a
    ld      a, (fid_ndev)
    add     a, b
    ld      hl, 0
    ld      l, a
    add     hl, hl
    add     hl, hl
    add     hl, hl      ; eight bytes per entry
    ld      de, (ctbl_dst)
    add     hl, de
    ex      de, hl      ; DE = destination

    ld      hl, (fid_req)
    ld      bc, 8
    ldir
    xor     a
    ld      (de), a     ; fresh terminator

    pop     bc
    pop     de
    pop     hl
    ret


; mul_de_12 -- HL = DE * 12.
mul_de_12:
    push    de
    ex      de, hl
    add     hl, hl      ; 2
    add     hl, hl      ; 4
    push    hl
    pop     de
    add     hl, hl      ; 8
    add     hl, de      ; 12
    pop     de
    ret


; -----------------------------------------------------------------------------
; _g_fidcio -- character I/O for a device supplied by a driver.
;
;   A = operation: 0 input, 1 output, 2 input status, 3 output status
;   B = device number as CP/M knows it
;   C = character, for output
;
; The stubs in agonchr.asm come here for any device number at or above the
; built-in count.  An unclaimed number reports not ready and discards output,
; which is what the UART stubs already do, and is safer than jumping through
; a table slot that was never filled in.
; -----------------------------------------------------------------------------
_g_fidcio:
    push    ix
    push    bc
    push    de
    ld      (fid_op), a

    ld      a, (fdesc+2); first driver device number
    ld      e, a
    ld      a, b
    sub     e
    jr      c, @none
    ld      e, a
    ld      a, (fid_ndev)
    cp      e
    jr      z, @none
    jr      c, @none

    ld      d, 0
    ld      a, e
    ld      de, 0
    ld      e, a
    call    mul_de_12
    ld      de, fid_cdev
    add     hl, de

    ld      a, (fid_op)
    or      a
    jr      z, @go
    ld      de, 3
    dec     a
    jr      z, @add
    ld      de, 6
    dec     a
    jr      z, @add
    ld      de, 9
@add:
    add     hl, de
@go:
    ld      hl, (hl)
    ld      a, h
    or      l
    jr      z, @none    ; slot never filled in
    ld      a, c        ; character, for output
    call    fid_call
    pop     de
    pop     bc
    pop     ix
    ret.lil

@none:
    ld      a, (fid_op)
    or      a
    jr      nz, @status
    ld      a, $1A      ; input: immediate end of file
    jr      @out
@status:
    cp      3
    jr      nz, @notready
    ld      a, $FF      ; output status: always ready
    jr      @out
@notready:
    xor     a
@out:
    pop     de
    pop     bc
    pop     ix
    ret.lil


; =============================================================================
;  DRIVES SUPPLIED BY A LOADABLE DRIVER
; -----------------------------------------------------------------------------
;  Everything a drive needs is already built by drvnew_core, which mounts
;  C: through J: on every boot.  Two things separate that from a driver
;  being able to add a drive of its own:
;
;  THE DPB MUST BE IN COMMON.  BDOS function 31 returns the DPB address to
;  the calling program, which runs in bank 1 -- bdos30.asm, func31, is
;  "call curselect / lhld dpbaddr / shld aret" -- so a DPB in bank 0 would
;  leave SHOW, and anything else asking a drive for its parameters, reading
;  whatever bank 1 holds there.  C: through J: share one statically declared
;  DPB, which is legitimate only because their geometry is identical.  A
;  driver's geometry is its own, so agondsk.asm declares a small pool of DPB
;  slots in the BIOS's CSEG and svc_dhook hands them out.
;
;  THE HANDLERS CANNOT GO IN AN XDPH.  An XDPH holds four sixteen-bit
;  addresses that the kernel reaches with PCHL, so whatever it names must be
;  Z80 code in bank 0.  A driver's handlers are twenty-four-bit addresses in
;  segment $04.  So every FID drive's XDPH names ONE SHARED SET of stubs in
;  agondsk.asm, which gate back here with the absolute drive number, and this
;  maps that drive to the right driver.  It is the same shape as
;  ?ci/?co/?cist/?cost reaching _g_fidcio for character devices.
; =============================================================================

; -----------------------------------------------------------------------------
; _svc_dhook -- add a drive.  HL points at, in segment $04:
;
;     +00  db  drive     0 = A: through 15 = P:, or $FF for the first free
;                        letter at or above the BIOS's automatic floor
;     +01  db  unit      relative drive number the driver wants to see.  It
;                        comes back at +00 of the block on every call, so a
;                        driver serving several drives can tell them apart
;     +02  db  flags     reserved, must be zero
;     +03  17 bytes      the DPB, BY VALUE.  Copied into a pool slot in
;                        common memory, so the driver's own copy is not
;                        kept and may be discarded or reused
;     +14  dl  read      handler addresses, 24-bit, in segment $04.
;     +17  dl  write     THE ORDER IS THE OPERATION ORDER -- read, write,
;     +1A  dl  login     login, init -- because _g_fiddio indexes this
;     +1D  dl  init      block, copied verbatim, by operation number.
;                        It is deliberately NOT the order of the four
;                        entries in an XDPH, which is write first.
;
; The block is 32 bytes in all.
;
; Returns A = the drive number, carry clear.  Carry set with A = a DRV_ code
; if the drive cannot be installed.
;
; WHY $FF IS NOT SIMPLY "THE FIRST ZERO @dtbl ENTRY".  A: and B: are zero:
; they are held for floppy drives by intention.  A naive scan would hand the
; first driver that asked A:, silently.  The floor comes from
; the BIOS in fid$ddesc so the policy is stated once, beside the drive map it
; governs.  A driver that genuinely wants A: -- a real floppy driver -- still
; asks for it by number, which skips the floor entirely.
; -----------------------------------------------------------------------------
_svc_dhook:
    push    ix
    push    bc
    push    de
    ld      (dhk_req), hl

    ; dtbl_addr reads @dtbl and the drive out of dreq, so seed it
    ld      a, (fddesc+0)
    ld      (dreq+13), a
    ld      a, (fddesc+1)
    ld      (dreq+14), a

    ld      hl, (dhk_req)
    ld      a, (hl)                 ; +00 requested drive
    cp      $FF
    jr      z, @auto

    ; ---- an explicit letter -------------------------------------
    cp      NDRIVELET
    jp      nc, @badparm
    ld      (dhk_drv), a
    ld      (dreq+0), a
    call    dtbl_addr
    ld      a, (hl)
    inc     hl
    or      (hl)
    jp      nz, @badparm            ; the letter is already taken
    jr      @gotdrive

    ; ---- the first free letter at or above the floor ------------
@auto:
    ld      a, (fddesc+5)           ; FIRSTAUTO
    ld      (dhk_drv), a
@autoloop:
    ld      a, (dhk_drv)
    cp      NDRIVELET
    jp      nc, @badparm            ; no free letter at all
    ld      (dreq+0), a
    call    dtbl_addr
    ld      a, (hl)
    inc     hl
    or      (hl)
    jr      z, @gotdrive
    ld      a, (dhk_drv)
    inc     a
    ld      (dhk_drv), a
    jr      @autoloop

@gotdrive:

    if      FIDDIAG
    ; --- DIAGNOSTIC ------------------------------------------------
    ; Reports the DECISION, before anything is built, rather than the
    ; consequences of it.  Nothing below this point depends on a
    ; register set up above it, so the call cannot disturb what it is
    ; measuring.
    ld      hl, dg_dhook
    call    fid_pmsg
    ld      a, (dhk_drv)
    add     a, 'A'
    call    dg_char
    ld      hl, dg_slot
    call    fid_pmsg
    ld      a, (dpb_used)
    add     a, '0'
    call    dg_char
    ld      a, '/'
    call    dg_char
    ld      a, (fddesc+4)
    add     a, '0'
    call    dg_char
    endif

    ; ---- take a DPB slot ----------------------------------------
    ;
    ; The pool is fixed at assembly time in the BIOS's CSEG.  There is
    ; no allocator because there is nothing to allocate from: GENCPM
    ; owns every byte of common memory.
    ld      a, (dpb_used)
    ld      b, a
    ld      a, (fddesc+4)           ; NDPBSLOT
    cp      b
    jp      z, @nodpb
    jp      c, @nodpb

    ; slot address = pool + used*17.
    ;
    ; mul_de_17 DESTROYS HL, so the pool base is fetched after the
    ; multiply, not before.
    ld      de, 0
    ld      a, (dpb_used)
    ld      e, a
    call    mul_de_17               ; HL = used*17
    ld      de, 0
    ld      a, (fddesc+3)
    ld      d, a
    ld      a, (fddesc+2)
    ld      e, a                    ; DE = pool base, 16-bit
    add     hl, de
    ld      (dhk_dpb), hl

    ; ---- copy the DPB into the slot, IN BOTH BANK COPIES ---------
    ;
    ; Common memory exists as two physical copies on this machine and
    ; only the registered mutable region is carried across on a bank
    ; switch -- and then only in the direction of travel.  Relying on
    ; that would make correctness depend on which bank happened to be
    ; current when the driver installed itself.  _svc_chook's
    ; fid_ctbl_write makes the same argument for @ctbl; this is the
    ; same problem with a different table.
    ld      a, SEG_BANK0
    call    dhk_dpb_write
    ld      a, SEG_BANK1
    call    dhk_dpb_write

    ; ---- record the handlers ------------------------------------
    ;
    ; Copied verbatim, in the operation order the request block
    ; declares them: read, write, login, init.  _g_fiddio indexes
    ; the result by operation number, so the two orders are the same
    ; thing and must not be allowed to diverge.
    ;
    ; Written before the drive is published in @dtbl, so there is no
    ; window in which the BDOS can see a drive whose handlers are
    ; still absent.
    ld      de, 0
    ld      a, (dhk_drv)
    ld      e, a
    call    mul_de_12
    ld      de, fid_ddrv
    add     hl, de
    push    hl
    pop     de                      ; DE = fid_ddrv[drive], all 24 bits.
                                    ; "ld d,h / ld e,l" would copy only
                                    ; sixteen and LDIR would write into
                                    ; whatever segment DEU held.
    ld      hl, (dhk_req)
    ld      bc, $14
    add     hl, bc                  ; HL = the four handler addresses
    ld      bc, 12
    ldir

    ; ---- build the drvnew request -------------------------------
    ;
    ; dreq+0 and dreq+13/14 are already set.  The four entry points
    ; are the SHARED STUBS from fid$ddesc, NOT the driver's handlers:
    ; see the note at the head of this section for why they cannot be.
    ld      hl, (dhk_req)
    inc     hl
    ld      a, (hl)
    ld      (dreq+1), a             ; unit
    xor     a
    ld      (dreq+2), a             ; flags: there is no image to verify

    ld      hl, fddesc+6            ; write, read, login, init
    ld      de, dreq+3
    ld      bc, 8
    ldir

    ld      hl, (dhk_dpb)
    ld      a, l
    ld      (dreq+11), a
    ld      a, h
    ld      (dreq+12), a            ; the pool slot, in common

    call    drvnew_core
    or      a
    jr      nz, @failed

    ; ---- commit -------------------------------------------------
    ld      a, (dpb_used)
    inc     a
    ld      (dpb_used), a
    ld      a, (fid_ndrv)
    inc     a
    ld      (fid_ndrv), a

    if      FIDDIAG
    ld      hl, dg_ok
    call    fid_pmsg
    endif

    ld      a, (dhk_drv)
    pop     de
    pop     bc
    pop     ix
    or      a                       ; carry clear = installed
    ret

@failed:
    ; drvnew_core failed after the DPB was copied.  dpb_used is not
    ; advanced, so the next caller reuses the slot, and nothing was
    ; published to the BDOS, so the system is exactly as it was.
    if      FIDDIAG
    push    af
    ld      hl, dg_fail
    call    fid_pmsg
    pop     af
    push    af
    add     a, '0'
    call    dg_char
    pop     af
    endif
    jr      @out
@badparm:
    ld      a, DRV_BADPARM
    jr      @out
@nodpb:
    ld      a, DRV_NODPB
@out:
    if      FIDDIAG
    push    af
    ld      hl, fidcrlf
    call    fid_pmsg
    pop     af
    endif
    pop     de
    pop     bc
    pop     ix
    scf
    ret


; -----------------------------------------------------------------------------
; dhk_dpb_write -- copy the seventeen-byte DPB from the request block into the
; pool slot at dhk_dpb, in the segment named in A.
; -----------------------------------------------------------------------------
dhk_dpb_write:
    push    hl
    push    de
    push    bc
    ld      hl, (dhk_dpb)
    ld      (tmp_dst), hl
    ld      (tmp_dst+2), a
    ld      hl, (dhk_req)
    ld      de, 3                   ; the DPB starts at +03
    add     hl, de
    ld      de, (tmp_dst)
    ld      bc, 17
    ldir
    pop     bc
    pop     de
    pop     hl
    ret


; -----------------------------------------------------------------------------
; mul_de_17 -- HL = DE * 17, for stepping through the DPB pool.  DE preserved.
; -----------------------------------------------------------------------------
mul_de_17:
    push    de
    ex      de, hl                  ; HL = n
    push    hl
    add     hl, hl                  ; 2
    add     hl, hl                  ; 4
    add     hl, hl                  ; 8
    add     hl, hl                  ; 16
    pop     de                      ; DE = n
    add     hl, de                  ; 17n
    pop     de
    ret


; -----------------------------------------------------------------------------
; _g_fiddio -- disk I/O for a drive supplied by a driver.
;
;   A  = operation: 0 read, 1 write, 2 login, 3 init
;   B  = @adrv, the absolute drive
;   C  = @rdrv, the relative drive
;   HL = the nine-byte parameter block, for read and write only
;
; The four stubs in agondsk.asm come here for every FID drive.  A drive with
; no driver recorded reports a permanent error rather than jumping through a
; table slot that was never filled in -- the same choice _g_fidcio makes for
; an unclaimed device number.
;
; THE DMA BANK IS RESOLVED HERE, not by the driver.  A driver has no business
; knowing that CP/M banks are eZ80 segments, and bank_map is not exported to
; it, so what it receives is a finished 24-bit address it can LDIR to or from.
; It also means a driver written today keeps working if that mapping ever
; changes.
;
; THE RESOLVED BLOCK IS THE SAME NINE BYTES, not a larger one.  A two-byte DMA
; address plus a one-byte bank is three bytes at +05, and a 24-bit address is
; three bytes at +05.  Only the MEANING of +07 changes, from bank number to
; segment number, so the block is copied whole and one byte is rewritten.
;
; Returns A = 0 on success, non-zero for a permanent error.
; -----------------------------------------------------------------------------
_g_fiddio:
    push    ix
    push    bc
    push    de
    ld      (fdio_blk), hl          ; the caller's block, in the CP/M segment
    ld      (fdio_op), a
    ld      a, c
    ld      (fdio_unit), a
    ld      a, b
    cp      NDRIVELET
    jp      nc, @nodrv
    ld      (fdio_drv), a

    ld      a, (fdio_op)
    cp      4
    jp      nc, @nodrv

    ; handler = fid_ddrv[drive] + op*3
    ld      de, 0
    ld      a, (fdio_drv)
    ld      e, a
    call    mul_de_12
    ld      de, fid_ddrv
    add     hl, de
    ld      de, 0
    ld      a, (fdio_op)
    ld      e, a
    add     hl, de
    add     hl, de
    add     hl, de                  ; three bytes per handler
    ld      hl, (hl)
    ld      (fdio_hand), hl

    ; a 24-bit zero means no driver on this drive
    ld      a, h
    or      l
    jr      nz, @have
    ld      a, (fdio_hand+2)
    or      a
    jp      z, @nodrv
@have:

    ld      a, (fdio_op)
    cp      2
    jr      nc, @simple             ; login and init take no transfer

    ; ---- read and write: copy the block and resolve the bank ----
    ld      hl, (fdio_blk)
    ld      (tmp_src), hl
    ld      a, (cur_seg)
    ld      (tmp_src+2), a
    ld      hl, (tmp_src)
    ld      de, fdio_req
    ld      bc, 9
    ldir

    ld      a, (fdio_req+7)         ; bank number ->
    call    bank_to_seg
    ld      (fdio_req+7), a         ; -> segment number

    if      FIDDIAG
    ; --- DIAGNOSTIC ------------------------------------------------
    ; After the block is complete and before the handler is called,
    ; so it reports exactly what the driver is about to be given.
    ld      hl, dg_dio
    call    fid_pmsg
    ld      a, (fdio_drv)
    add     a, 'A'
    call    dg_char
    ld      a, (fdio_op)
    add     a, '0'
    call    dg_char
    endif

    call    fdio_call
    jr      @done

@simple:
    ; The driver is given a block here too, so that all four handlers
    ; have one calling convention.  Only +00, the relative drive, is
    ; meaningful.
    ld      a, (fdio_unit)
    ld      (fdio_req+0), a
    call    fdio_call
@done:
    pop     de
    pop     bc
    pop     ix
    or      a
    ret.lil

@nodrv:
    pop     de
    pop     bc
    pop     ix
    ld      a, 1                    ; permanent error
    or      a
    ret.lil


; -----------------------------------------------------------------------------
; fdio_call -- call the handler at fdio_hand with HL = fdio_req.
;
; fid_call cannot be used: it takes its entry point in HL, which is needed
; here to carry the argument.  There is no CALL (HL) on this processor either,
; so the return address and the entry are both pushed and the RET does the
; jump -- RET pops the entry into PC, leaving @back beneath it as the
; handler's own return address.  Both pushes and the RET move three bytes in
; ADL mode, so the stack stays consistent.
;
; A is not preserved and need not be: every handler returns a status in it.
; -----------------------------------------------------------------------------
fdio_call:
    ld      hl, @back
    push    hl                      ; the handler's return address
    ld      hl, (fdio_hand)
    push    hl                      ; the handler itself
    ld      hl, fdio_req            ; the argument
    ret
@back:
    ret


    if      FIDDIAG
; -----------------------------------------------------------------------------
; dg_char -- print the character in A.  DIAGNOSTIC ONLY; the whole of this
; block goes when FIDDIAG is set to 0.
; -----------------------------------------------------------------------------
dg_char:
    push    bc
    push    hl
    ld      c, a
    call    conout_char
    pop     hl
    pop     bc
    ret

dg_dhook:       .db     13, 10, "FID: drive ", 0
dg_slot:        .db     " dpb ", 0
dg_ok:          .db     " ok", 0
dg_fail:        .db     " FAILED rc=", 0
dg_dio:         .db     13, 10, "FID: io ", 0
    endif


; handle_addr and drv_handles are GONE.
;
; They held one MOS file handle per drive for the whole session.  MOS allows
; only a fixed number of files open at once -- eight, on the evidence -- so
; with eight images mounted there was no handle left for anything else, and
; the FID loader's attempt to open FID.INI failed for want of one.
; Confirmed on hardware: renaming one image freed a handle and the driver
; loaded.
;
; The array is replaced by cur_unit and cur_handle: ONE image open at a time,
; opened on demand, exactly as the CP/M 2.2 port does.  See drv_open.
;
; The 24-bit clear this routine documented still matters elsewhere, so the
; note has been kept at the sites that rely on it rather than lost with the
; code.

; -----------------------------------------------------------------------------
; mos_enter / mos_leave -- MOS requires MBASE to be zero for its API calls, as
; it uses MBASE to decide whether the caller is a Z80-mode program.  These
; bracket every MOS call and restore the CP/M segment afterwards, which matters
; because a gate's RET.LIL resumes Z80 execution in whatever segment MBASE then
; names.
; -----------------------------------------------------------------------------
mos_enter:
    push    af
    xor     a
    ld      mb, a
    pop     af
    ret
mos_leave:
    push    af
    ld      a, (cur_seg)
    ld      mb, a
    pop     af
    ret


; -----------------------------------------------------------------------------
; _g_ldccp -- put the CCP into the TPA at 0100h in bank 1.
;
; The CCP image was read from the SD card at startup and parked in segment $07,
; so this is a block copy rather than a file read.  That makes warm boots
; effectively instant, which is the optimisation flagged in agonini.asm.
;
; Note this deviates from a stock CP/M 3, where the CCP is read from A:CCP.COM
; inside the file system.  Reading it from the SD card instead avoids having to
; parse a CP/M directory from the BIOS, at the cost of CCP.COM not appearing in
; a DIR of drive A:.
; -----------------------------------------------------------------------------
_g_ldccp:
    push    hl
    push    de
    push    bc

    ld      hl, (ccp_len)
    ld      a, h
    or      l
    jr      z, @fail    ; no CCP was loaded

    ld      bc, (ccp_len)
    ld      hl, CCP_STORE
    ld      (tmp_src), hl
    ld      hl, $0100
    ld      (tmp_dst), hl
    ld      a, SEG_BANK1
    ld      (tmp_dst+2), a
    ld      hl, CCP_STORE           ; source: parked CCP image
    ld      de, (tmp_dst)           ; destination: 0100h in bank 1
    ldir

    pop     bc
    pop     de
    pop     hl
    xor     a
    ret.lil
@fail:
    pop     bc
    pop     de
    pop     hl
    ld      a, 1
    or      a
    ret.lil

; =============================================================================
;  UNIMPLEMENTED GATES
; -----------------------------------------------------------------------------
;  Returning a non-zero A means "permanent error" to the BIOS disk routines, so
;  a premature call fails visibly rather than quietly corrupting something.
; =============================================================================
_g_notimp:
    ld      a, 1
    or      a
    ret.lil

; =============================================================================
;  STARTUP
; =============================================================================

_start:
    push    ix
    push    iy
    ld      (save_spl), sp

    ; NO mos_enter / mos_leave HERE.  THIS IS NOT A STYLE CHOICE.
    ;
    ; There are two regimes in this file and they have OPPOSITE
    ; rules about MBASE:
    ;
    ;   THE LOADER, everything from _start down to the jump into
    ;   CP/M, runs with MB = 0 and calls MOS BARE.  load_system and
    ;   load_ccp below use MOSCALL with no bracketing at all, and
    ;   the banner a few lines down uses rst.lil $18 the same way.
    ;
    ;   THE GATES, which run after CP/M is up, are entered with
    ;   MB = cur_seg, so they must bracket every MOS call with
    ;   mos_enter / mos_leave to drop MB to 0 and put it back.
    ;
    ; Calling mos_leave here sets MB to cur_seg, which is $05 at
    ; this point, and that is CATASTROPHIC rather than merely
    ; wrong.  MOS's _rst_18_handler (src_startup/vectors16.asm)
    ; begins:
    ;
    ;       LD   A, MB
    ;       OR   A, A
    ;       CALL NZ, SET_AHL24      ; create a 24-bit pointer
    ;
    ; so a non-zero MB makes MOS OVERWRITE HLU with it.  The banner
    ; call below passes BC = 0, which selects delimited mode: MOS
    ; then loops fetching and printing bytes until it finds a zero.
    ; With MB = $05 that loop runs through uninitialised CP/M bank 1
    ; SDRAM and prints thousands of arbitrary characters.  Every
    ; bare MOSCALL after it has its pointer redirected the same way,
    ; so CPM3.SYS cannot be opened either and the program falls back
    ; to MOS.
    ;
    ; mos_api_sysvars is "LD IX,_sysvars / RET" (mos_api.asm line
    ; 562) -- two instructions, no pointer arguments, nothing that
    ; consults MB -- so calling it bare is correct here.  _sysvars
    ; is an absolute 24-bit address, so the cached pointer stays
    ; valid whatever MB is set to later.
    MOSCALL mos_sysvars     ; -> IX = sysvars, in segment 0
    push    ix
    pop     hl
    ld      (sysvars), hl

    ; READ THE ESP32'S CLOCK NOW, WHILE IT IS STILL POSSIBLE.
    ;
    ; This is the only moment in the whole session when the clock
    ; can be reached.  MOS's UART0 receive interrupt is still armed
    ; and vdp_protocol is still running, so rtc_update()'s round
    ; trip works exactly as it does at the MOS prompt.  console_init
    ; below turns that interrupt off and puts the VDP into terminal
    ; mode, and from that point the clock is unreachable by any
    ; route -- see the note by clock_init.
    ;
    ; It is done before load_system rather than after so that a
    ; future change to the loader cannot quietly move console_init
    ; ahead of it.
    call    zero_ccp    ; the CCP buffer is not part of
; the loaded image, so clear it
; before anything can read it

    call    format_m    ; give M: an empty directory;
; nothing else ever will

    ld      hl, msg_banner
    ld      bc, 0
    xor     a
    rst.lil $18

    ; READ THE ESP32'S CLOCK NOW, WHILE IT IS STILL POSSIBLE.
    ;
    ; This is the only moment in the session when it can be reached.
    ; MOS's UART0 receive interrupt is still armed and vdp_protocol
    ; is still running, so rtc_update()'s round trip behaves exactly
    ; as it does at the MOS prompt.  console_init below turns that
    ; interrupt off and puts the VDP into terminal mode, and from
    ; that point the clock is unreachable by any route -- see the
    ; note by clock_init.
    ;
    ; AFTER THE BANNER, NOT BEFORE IT, so that the banner is proof
    ; the loader started.  If anything here misbehaves, the banner
    ; has already been printed and how far the boot got is visible
    ; rather than guessed at.
    call    clock_init

    call    load_system
    jr      nz, @failed

    ; The bank-0 heap's ceiling is the base of the banked system,
    ; which is only known once the CPM3.SYS header has been read.
    call    heap0_init

    ; A FAILED CCP LOAD MUST BE FATAL, AND MUST BE FATAL HERE.
    ;
    ; The kernel's boot$1 is, verbatim from DRI's bioskrnl.asm,
    ;
    ;       call ?ldccp
    ;       jmp ccp
    ;
    ; with no test of the return value.  So if ?ldccp cannot
    ; produce a CCP, the kernel jumps to 0100h regardless and the
    ; machine dies there with no message and no clue -- the fault
    ; is invisible by design.  Catching it at this point instead
    ; costs one test and leaves MOS's console still working, so
    ; the message can actually be read and we can return to MOS.
    call    load_ccp
    jr      nz, @noccp

    ; Only now take the console over.  Doing this earlier -- as the
    ; first version did -- disables MOS's UART0 receive interrupt,
    ; which is how MOS gets its keystrokes.  If the load then
    ; failed and we returned, MOS came back with no keyboard and
    ; looked like a hang.  Nothing below this point returns to MOS.
    call    console_init

    ; Everything is in place.  Enter CP/M.
    ;
    ; Bank 0 must be selected: the kernel's cold boot code lives in
    ; the BIOS's DSEG, which GENCPM placed in the banked region, and
    ; the first thing it does is set its own stack -- so we do not
    ; need to establish SPS ourselves.
    di
    ld      a, SEG_BANK0
    ld      (cur_seg), a
    ld      mb, a
    ei
    ; JP.SIS mn assembles as 40 C3 nn mm, so the 16-bit operand
    ; begins at +2.  It has to be written as two single-byte stores:
    ; LD (Mmn),HL in ADL mode would write three bytes and overrun
    ; into the instruction that follows.
    ld      hl, (sys_entry)
    ld      a, l
    ld      (@jump+2), a
    ld      a, h
    ld      (@jump+3), a
@jump:
    jp.sis  $0000       ; operand patched above

@failed:
    ld      hl, msg_failed
    jr      @abort
@noccp:
    ld      hl, msg_noccp
@abort:
    ld      bc, 0
    xor     a
    rst.lil $18

    xor     a
    ld      mb, a       ; MOS API needs MBASE = 0
    ld      sp, (save_spl)
    pop     iy
    pop     ix
    ld      hl, 19      ; MOS "invalid parameter"-ish
    ret


; -----------------------------------------------------------------------------
; load_system -- read CPM3.SYS and place it in memory.
;
; Appendix D of the CP/M 3 System Guide, Tables D-1 and D-2:
;
;   Record 0        header, 128 bytes
;   Record 1        print record: the load table in ASCII, terminated by '$'
;   Records 2..n    the operating system IN REVERSE ORDER, TOP DOWN
;
;   Header byte 0   top page plus one for the RESIDENT portion
;   Header byte 1   length of the resident portion in 256-byte pages
;   Header byte 2   top page plus one for the BANKED portion
;   Header byte 3   length of the banked portion in pages
;   Header bytes 4-5 cold boot entry point
;
; "Reverse order, top down" is the part that matters and the part that is easy
; to get wrong: record 2 holds the HIGHEST 128 bytes of the resident portion,
; record 3 the 128 below that, and so on.  So the destination address for
; record i of a portion whose top page plus one is T is:
;
;       T*256 - 128*(i+1)
;
; Verified against a generated image by locating known strings and checking
; they land where the linked SPR says they should.
;
; The resident portion is written into BOTH segments.  That is the whole
; reason this loader exists rather than a stock CPMLDR: common memory has to be
; physically present in each bank because eZ80 segments cannot overlap.
;
; Returns Z set on success.
; -----------------------------------------------------------------------------
load_system:
    ld      hl, sysfile
    ld      bc, 0       ; 24-bit clear before setting C
    ld      c, fa_read
    MOSCALL mos_fopen
    or      a
    jr      nz, @opened
    or      1           ; handle 0: return NZ = failure
    ret     ; (returning Z here read as OK)
@opened:
    ld      (filehandle), a

    ; --- record 0: the header ------------------------------------
    call    read_record
    jp      nz, @bad

    ; Each value is built by clearing all 24 bits of HL first and
    ; only then setting the bytes that matter.  "ld h,a / ld l,0"
    ; on its own leaves HLU holding whatever the last full 24-bit
    ; load put there, and since these are now three-byte variables
    ; that stale byte would be stored along with the value.
    ld      hl, 0       ; clears HLU as well as H and L
    ld      a, (recbuf+0)           ; resident top page plus one
    ld      h, a        ; HL = top address
    or      a
    jr      nz, @res_top_ok
    ; A page-plus-one of 00 means one past 0FFH, i.e. 10000h -- the
    ; resident portion reaches the very top of memory.  "ld h,a"
    ; alone leaves HL = 0000, and the subtraction that derives the
    ; base then wraps to 0FFxxxxh.  The low 16 bits would still come
    ; out right, but the 24-bit value would not, and any arithmetic
    ; that does not truncate to 16 bits -- such as deriving a length
    ; from the top of memory below -- would inherit the error.
    ld      hl, $010000
@res_top_ok:
    ld      (res_top), hl

    ld      hl, 0
    ld      a, (recbuf+1)
    ld      (res_len), a
    ld      h, a        ; pages -> bytes
    ld      (res_len_bytes), hl

    ld      hl, 0
    ld      a, (recbuf+2)           ; banked top page plus one
    ld      h, a
    ld      (bnk_top), hl

    ld      a, (recbuf+3)
    ld      (bnk_len), a

    ld      hl, 0       ; cold boot entry point.  A
    ld      a, (recbuf+5)           ; plain "ld hl,(recbuf+4)"
    ld      h, a        ; would read three bytes and
    ld      a, (recbuf+4)           ; pick up recbuf+6 as HLU.
    ld      l, a
    ld      (sys_entry), hl

    ; --- record 1: the print record, discarded -------------------
    call    read_record
    jp      nz, @bad

    ; --- resident portion, into both segments --------------------
    ld      hl, (res_top)
    ld      (dst_top), hl
    ld      a, (res_len)
    add     a, a        ; pages -> 128-byte records
    ld      b, a
    ld      a, 1        ; flag: write to both segments
    ld      (both_seg), a
    call    load_portion
    jp      nz, @bad

    ; --- banked portion, into bank 0 only ------------------------
    ld      hl, (bnk_top)
    ld      (dst_top), hl
    ld      a, (bnk_len)
    add     a, a
    ld      b, a
    xor     a
    ld      (both_seg), a
    call    load_portion
    jp      nz, @bad

    ; --- declare the mutable common region -----------------------
    ;
    ; For the first working system this registers the ENTIRE
    ; resident portion, which is provably correct and needs no
    ; knowledge of the internal layout: everything mutable in
    ; common is by definition somewhere inside it, and copying the
    ; static code along with it is harmless because both segments
    ; hold identical copies anyway.
    ;
    ; It is not the cheapest rule.  The resident portion is 9 pages
    ; here, about 2.3K, which at the measured 5-6 MB/s costs some
    ; 390-460 us per switch against the 110-130 us a tight region
    ; would cost.  The narrowing is known and can be applied once
    ; the system boots and the cost can be measured rather than
    ; predicted:
    ;
    ;   sys_entry is the BIOS jump table, i.e. the first byte of
    ;   the BIOS resident region, so that region is
    ;   sys_entry..FFFF.  RESBDOS sits immediately below it, and
    ;   only its top 512 bytes are mutable -- its data block, the
    ;   local stack, and the SCB, which GENCPM places in the last
    ;   100 bytes of the module (verified: it rewrote this BIOS's
    ;   0FExx markers to 0FC9Ch+offset).  Two fragments of 200h and
    ;   (10000h - sys_entry) would roughly halve the cost.
    ;
    ; Getting this wrong is not a performance bug, it is a crash:
    ; too small a region and the first bank switch returns through
    ; a stack that was never copied.  Hence the cautious rule first.

    ; REGISTER TO THE TOP OF MEMORY, NOT JUST THE RESIDENT LENGTH.
    ;
    ; The base of the resident portion is also the base of common
    ; memory (GENCPM's COMBAS), but the resident portion does not
    ; necessarily REACH the top of memory: GENCPM places disk
    ; buffers in common too, above the system image, whenever
    ; "Allocate buffers outside of Common" is answered N.
    ;
    ; That gap is mutable.  With COMBAS=F2 the layout is
    ;
    ;   F200-FDFF  resident system   (12 pages, res_len_bytes)
    ;   FE00-FFFF  A: data deblocking buffer (512 bytes)
    ;
    ; and registering only the resident portion leaves the buffer
    ; and its control blocks out of the copy, so the two segments
    ; disagree about them from the first bank switch onwards.
    ;
    ; This was a real hang.  It did not show up earlier only
    ; because the previous system had COMBAS=F7 with a resident
    ; portion that ran to FFFF exactly, so "base + res_len_bytes"
    ; and "base to top of memory" happened to be the same region.
    ; The old code was right by accident and broke the moment the
    ; common base moved.  Deriving the length from the top of
    ; memory removes the coincidence.
    ; COMMON MEMORY IS EVERYTHING ABOVE THE BANKED PORTION.
    ;
    ; Derive the base from bnk_top, not from the resident portion.
    ; The resident system image does not necessarily start at the
    ; base of common nor reach the top of it -- GENCPM puts disk
    ; buffers in common on both sides of it when "Allocate buffers
    ; outside of Common" is answered N (which it must be here: A:
    ; has 512-byte physical records and this BIOS has no alternate
    ; bank to put the buffer in).
    ;
    ; With COMBAS=F2 and a correctly [B]-linked BIOS the layout is
    ;
    ;   C000-F1FF  banked portion(bank 0 only)
    ;   F200-F3FF  buffers in common
    ;   F400-FDFF  resident system image     (10 pages)
    ;   FE00-FFFF  buffers in common
    ;
    ; so the mutable common region is F200-FFFF: base = bnk_top,
    ; length = 10000h - bnk_top.  Registering only the resident
    ; image would leave the buffers and their control blocks out of
    ; the copy and the two segments would disagree about them from
    ; the first bank switch onwards.
    ld      hl, (bnk_top)           ; first byte above the banked
; portion = base of common
    ex      de, hl      ; DE = base
    ld      hl, $010000 ; one past the top of memory
    or      a
    sbc     hl, de      ; HL = length, base..FFFF
    ex      de, hl      ; DE = length, HL = base
    call    reg_fragment
    jp      nz, @bad

    ld      bc, 0       ; whole BC is the handle
    ld      a, (filehandle)
    ld      c, a
    MOSCALL mos_fclose
    xor     a           ; Z = success
    ret
@bad:
    ld      bc, 0       ; whole BC is the handle
    ld      a, (filehandle)
    ld      c, a
    MOSCALL mos_fclose
    or      1           ; NZ = failure
    ret


; -----------------------------------------------------------------------------
; load_portion -- read B records into descending addresses below dst_top.
; If both_seg is non-zero each record is written to bank 1 and bank 0 alike.
; -----------------------------------------------------------------------------
load_portion:
    ld      c, 0        ; C = record index
@next:
    push    bc
    call    read_record
    jr      nz, @err

    ; destination offset = dst_top - 128*(index+1)
    pop     bc
    push    bc
    ld      hl, 0       ; 24-bit clear: see handle_addr.
    ld      l, c        ; (masked here because tmp_dst+2
; is overwritten with the segment
; before use, but not worth
; leaving as a trap.)
    inc     hl          ; index + 1
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl
    add     hl, hl      ; x128
    ex      de, hl
    ld      hl, (dst_top)
    or      a
    sbc     hl, de      ; HL = 16-bit destination offset

    ld      (tmp_dst), hl
    ld      a, SEG_BANK0
    ld      (tmp_dst+2), a
    ld      hl, recbuf  ; source
    ld      de, (tmp_dst)           ; destination
    ld      bc, 128
    ldir    ; always into bank 0

    ld      a, (both_seg)
    or      a
    jr      z, @onedone
    ld      a, SEG_BANK1
    ld      (tmp_dst+2), a
    ld      hl, recbuf  ; source
    ld      de, (tmp_dst)           ; destination
    ld      bc, 128
    ldir    ; and into bank 1
@onedone:
    pop     bc
    inc     c
    djnz    @next
    xor     a
    ret
@err:
    pop     bc
    or      1
    ret


; -----------------------------------------------------------------------------
; format_m -- give the M: RAM drive an empty CP/M directory.
;
; Writes 0E5h over the first M_DIRSIZE bytes of the drive.  Nothing else in
; the system does this: agonm$init0 in agondsk.asm is deliberately a no-op,
; and CP/M 3 has no format utility.  Without it the BDOS finds no free
; directory entry and M: accepts no files.
;
; UNCONDITIONAL, AND ONLY HERE.
;
; This routine runs exactly once, from _start, which is reached only when
; MOS loads and runs CPM3.BIN -- that is, on a cold start of CP/M.  A CP/M
; warm boot re-enters the system through the BIOS and never comes back
; here, so M:'s contents survive warm boots, which is the lifetime stated
; in agondsk.asm.  Re-running CPM3.BIN from MOS does wipe the drive; that
; is a cold start and wiping is the correct behaviour for one.
;
; It is deliberately not conditional on the directory "looking valid".  Any
; such test is a guess about bytes left behind by whatever ran before, and
; guessing wrong either wipes live data or leaves an unusable drive.  A
; fixed rule tied to a well-defined event is worth more here than a clever
; one.
;
; The whole 16K is written in one ADL-mode LDIR: this code runs with real
; 24-bit addressing, so it crosses the $07/$08 segment boundary without
; needing to know it is there.  At the 5-6 MB/s measured in Phase 0 this
; costs roughly 3 ms, once, at boot.
; -----------------------------------------------------------------------------
format_m:
    push    bc
    push    de
    push    hl

    ld      hl, RAM_BASE
    ld      (hl), DIR_FREE
    ld      de, RAM_BASE+1
    ld      bc, M_DIRSIZE-1
    ldir    ; propagate the first byte

    pop     hl
    pop     de
    pop     bc
    ret


; -----------------------------------------------------------------------------
; zero_ccp -- clear the CCP buffer.
;
; CCP_STORE is an address past the end of the assembled image rather than a
; .blkb reservation, so the bytes there are whatever the previous occupant of
; that RAM left behind.  MOS's cold boot fills external RAM with $FF (see
; init_params_f92.asm), but a warm boot does not, so this cannot be assumed.
;
; Nothing reads the buffer beyond ccp_len, so this is belt-and-braces rather
; than load-bearing -- but it costs one LDIR once at startup and removes any
; question about what _g_ldccp might copy into the TPA.
; -----------------------------------------------------------------------------
zero_ccp:
    push    bc
    push    de
    push    hl

    ld      hl, CCP_STORE
    ld      (hl), 0
    ld      de, CCP_STORE+1
    ld      bc, CCP_MAX-1
    ldir

    pop     hl
    pop     de
    pop     bc
    ret


; -----------------------------------------------------------------------------
; load_ccp -- read CCP.COM from the SD card into the CCP buffer.
; Parked there rather than loaded straight into the TPA so that warm boots are
; a block copy instead of a file read.
;
; _g_ldccp refuses to copy anything when ccp_len is zero, but that is a second
; line of defence rather than the reporting mechanism: by the time ?ldccp runs
; there is no console left that anyone is reading, and the kernel discards its
; return value anyway.  The failure is caught at startup instead -- see the
; call site in _start.
;
; The buffer sits just above this file's own image in segment $04.  It cannot
; live in segment $07, which is the first segment of the M: RAM drive.
; -----------------------------------------------------------------------------
; Returns Z set on success, NZ on failure.  Both failure modes are covered:
; the file not being there at all, and the file being there but empty.  The
; caller treats either as fatal -- see the note at the call site in _start.
load_ccp:
    ld      hl, ccpfile
    ld      bc, 0       ; 24-bit clear before setting C
    ld      c, fa_read
    MOSCALL mos_fopen
    or      a
    jr      z, @noccp   ; handle 0: could not open
    ld      (filehandle), a

    ld      bc, 0       ; whole BC is the handle
    ld      c, a
    ld      hl, CCP_STORE
    ld      de, CCP_MAX
    MOSCALL mos_fread   ; DEU = bytes actually read
    ld      (ccp_len), de

    ld      bc, 0       ; whole BC is the handle
    ld      a, (filehandle)
    ld      c, a
    MOSCALL mos_fclose

    ; A zero-length read leaves ccp_len at zero, which _g_ldccp
    ; would later report as an error at a point where nothing is
    ; listening.  Treat it as a failure now instead.  ccp_len can
    ; never exceed CCP_MAX (8K), so testing H and L is sufficient.
    ld      hl, (ccp_len)
    ld      a, h
    or      l
    jr      z, @noccp
    xor     a           ; Z = success
    ret
@noccp:
    or      1           ; NZ = failure
    ret


; -----------------------------------------------------------------------------
; reg_fragment -- add HL (start offset) / DE (length) to the mutable common
; fragment table.  Same table _g_setcom appends to, so the BIOS can still
; declare extra fragments of its own later.  Z set on success.
; -----------------------------------------------------------------------------
reg_fragment:
    push    ix
    ld      ix, frag_tbl
    ld      b, MAXFRAG
@find:
    ld      a, (ix+3)
    or      (ix+4)
    jr      z, @store
    lea     ix, ix+6
    djnz    @find
    pop     ix
    or      1           ; table full
    ret
@store:
    ld      (ix+0), hl
    ld      (ix+3), de
    pop     ix
    xor     a
    ret


; -----------------------------------------------------------------------------
; read_record -- read one 128-byte record into recbuf.  Z set on success.
; MOS returns the number of bytes actually read, so a short read is detected
; rather than silently producing a truncated system.
; -----------------------------------------------------------------------------
read_record:
    ld      bc, 0       ; whole BC is the handle
    ld      a, (filehandle)
    ld      c, a
    ld      hl, recbuf
    ld      de, 128
    MOSCALL mos_fread
    ld      a, e        ; DE = bytes read
    cp      128
    ret     nz
    ld      a, d
    or      a
    ret

; -----------------------------------------------------------------------------
; console_init -- hand the console over from MOS to the polled UART routines.
;
; Switching the VDP into terminal emulation mode is the point of no return: it
; changes how the VDP treats the serial stream and MOS's own console handling
; goes with it.
;
; Ownership of UART0 must be taken -- FIFO cleared, receive interrupt off --
; BEFORE waiting for the VDP's handover byte, not after.  Waiting first and
; disabling MOS's receive interrupt afterwards races MOS's own UART0 ISR for
; the same byte: on VDP 2.16.0, fabgl::Terminal::connectSerialPort() sends
; exactly one byte, XON ($11), once the terminal has actually come up (see
; below), and nothing else arrives until a key is pressed.  With MOS's
; interrupt still armed at a one-byte FIFO trigger level, its handler
; (_uart0_handler -> UART0_serial_RX) usually wins the race, reads that $11
; out of the RBR first, and vdp_protocol_state0 discards it as a sub-$80 byte
; -- so the polled wait then sees nothing until a keystroke arrives.  The
; CP/M 2.2 port's _term_init takes the FIFO and the interrupt ahead of its
; wait for the same reason, and this matches that order.
; -----------------------------------------------------------------------------
console_init:
    ; Send the terminal-mode command.  The VDP does NOT switch
    ; mode synchronously: on VDP 2.16.0, VDU 23,0,255 only sets the
    ; terminal state machine to "Enabling", and the
    ; fabgl::Terminal is constructed on a LATER iteration of the
    ; VDP's processLoop, which then moves to "Enabled".  Only from
    ; "Enabled" does the VDP read bytes from the eZ80, and does its
    ; keyboard forward keystrokes back over UART0.  The wait for
    ; the $11 handover byte below is what synchronises the two.
    ;
    ; Nothing but the command itself is sent: see vdu_term.
    ld      hl, vdu_term
    ld      bc, vdu_term_end - vdu_term
    xor     a
    rst.lil $18         ; last console call through MOS

    ; Take sole ownership of UART0 now, before waiting, so MOS's
    ; own receive interrupt cannot steal the handover byte below.
    ; FTC = 3 (FIFO enable + clear RECEIVE fifo only) rather than
    ; the CP/M 2.2 port's 7, so any byte MOS still has queued for
    ; transmission is not thrown away by us.
    ld      a, 3
    out0    (REG_FTC), a
    xor     a
    out0    (REG_IER), a; receive interrupt off

    ; Block until the VDP sends its handover byte, as the CP/M 2.2
    ; port does.  Once terminal mode is fully "Enabled",
    ; Terminal::connectSerialPort() sends exactly one XON ($11)
    ; byte; nothing else arrives until a key is pressed.  Taking
    ; the UART over first (above) means stale VDP protocol traffic
    ; that was in flight when we switched modes could now land in
    ; the FIFO ahead of that byte, so wait specifically for $11
    ; and discard anything else, rather than trusting the first
    ; byte that arrives.
    ;
    ; Intentionally unbounded.  If the VDP never enters terminal
    ; mode -- or never sends $11 -- the machine stalls HERE, at a
    ; known point, rather than booting into a dead-keyboard CP/M
    ; and hanging mysteriously later.
@wait_vdp:
    in0     a, (REG_LSR)
    and     LSR_RDY
    jr      z, @wait_vdp
    in0     a, (REG_RBR)
    cp      $11
    jr      nz, @wait_vdp

    ; A CR/LF, so that if the VDP swallows the first character
    ; after the mode change it is a line ending that is lost
    ; rather than the first character of CP/M's signon.
    ld      c, 13
    call    con_put
    ld      c, 10
    call    con_put
    ret


; -----------------------------------------------------------------------------
; con_put -- send the character in C through the polled UART.
; Used by console_init only; CP/M's own output goes through _g_conout.
; -----------------------------------------------------------------------------
con_put:
    push    de
    ld      de, TX_WAIT
@cpwait:
    in0     a, (REG_LSR)
    and     LSR_ETH
    jr      nz, @cpsend
    dec     de
    ld      a, d
    or      e
    jr      nz, @cpwait
    pop     de
    ret     ; timed out; drop the byte
@cpsend:
    ld      a, c
    out0    (REG_THR), a
    pop     de
    ret

; Switch to terminal mode.  The command and nothing else.
vdu_term:
    .db     23, 0, 255  ; VDP terminal emulation on
vdu_term_end:

msg_banner:
    .db     "CP/M Plus Supervisor for Agon Light", 13, 10
	.db     "(c) 2026 Nick J. Date", 13, 10, 13, 10
	.db     "Portions derived from Agon CPM 2.2 by Aleksandr Sharikhin (nihirash).", 13, 10, 13, 10, 0

msg_failed:
    .db     "Cannot load CPM3.SYS", 13, 10, 0

msg_noccp:
    .db     "Cannot load CCP.COM", 13, 10, 0


; =============================================================================
;  VARIABLES
; =============================================================================

save_spl:       .dl     0

cur_seg:        .db     SEG_BANK1       ; segment currently selected for Z80 code
new_seg:        .db     SEG_BANK1

bank_map:       .db     SEG_BANK0       ; CP/M bank 0 -> segment $06
    .db     SEG_BANK1       ; CP/M bank 1 -> segment $05

xm_armed:       .db     0   ; non-zero: next move is cross-bank
xm_src:         .db     0
xm_dst:         .db     0


tmp_src:        .dl     0   ; 24-bit scratch used to splice a
tmp_dst:        .dl     0   ; segment number onto a 16-bit offset
tmp_len:        .dl     0

; --- clock state ---
;
; sysvars is fetched once at startup.  MOS's mos_api_sysvars is two
; instructions and touches nothing, so calling it is safe at any time, but
; there is no reason to repeat it.
sysvars:        .dl     0   ; MOS system variable base, segment 0

; THESE FOUR MUST STAY ADJACENT AND IN THIS ORDER.  _g_rtcraw copies eight
; bytes starting at rtc_stat straight out to the caller, and GETDATE.COM
; unpacks them by position.
rtc_stat:       .db     0   ; 0 never fetched, 1 packet fetched,
    ; 3 not a usable date
rtc_len:        .db     0   ; payload length of that packet
rtc_pkt:        .blkb   6, 0; the raw clock packet, kept from startup

; Fields decoded once at startup.  Only GETDATE reads these; the running
; clock uses clk_* below.  rtc_yday and rtc_year are .dl for the reason given
; in the loader-state note below: LD (nn),HL writes three bytes in ADL mode
; whether or not that was intended, and .dw would put the third into whatever
; follows.
rtc_day:        .db     0
; RETIRED: rtc_mon (0-11, as the VDP reports it) and rtc_dow (0 = Sunday),
; decoded only for CHCKDATE.COM.
;   rtc_mon:    .db     0
;   rtc_dow:    .db     0
rtc_yday:       .dl     0   ; 0-365, zero-based
rtc_year:       .dl     0   ; full year

; The clock blocks.  Each is six bytes in the BLK_ layout: a three-byte day
; count in CP/M's own terms -- days since 31 December 1977 -- then hour,
; minute and second.  Crossing midnight is one increment of the day count and
; no calendar arithmetic is ever needed after startup.
;
; THE FIELDS OF EACH BLOCK MUST STAY ADJACENT AND IN THIS ORDER; blk_tick,
; blk_addsec and blk_pack address them through IX at the BLK_ offsets.
clock_ok:       .db     0   ; non-zero once the running clock holds a real time
clk_blk:
clk_date:       .dl     0   ; .dl: LD (nn),HL moves three bytes here
clk_hour:       .db     0
clk_min:        .db     0
clk_sec:        .db     0

; RETIRED: the ESP32's reckoning, a second block advanced in step with
; clk_blk so that GETDATE.COM could restore the clock to it.
;
;   esp_ok:     .db     0   ; non-zero if the startup fetch was usable
;   esp_blk:
;   esp_date:   .dl     0
;   esp_hour:   .db     0
;   esp_min:    .db     0
;   esp_sec:    .db     0

; tick_base is the reading of MOS's counter at the moment clk_* was correct.
; tick_frac carries the counts left over after the last whole second, so that
; nothing is lost between calls however often ?time is asked.
tick_base:      .dl     0
tick_frac:      .db     0

; The five bytes handed back to ?time: @date low, @date high, then hour,
; minute and second in BCD.  Six are reserved because the @date store is a
; three-byte LD (nn),HL whose top byte lands on +2 before the BCD hour
; overwrites it.
time_res:       .blkb   6, 0

; Mutable common fragments: 6 bytes each, offset (3) then length (3).
; A zero length terminates the list.
frag_tbl:       .blkb   MAXFRAG*6, 0

; --- loader state ---
;
; EVERY MULTI-BYTE VARIABLE HERE IS THREE BYTES WIDE, DELIBERATELY.
;
; In ADL mode HL, DE and BC are 24-bit registers, so LD (nn),HL writes
; THREE bytes and LD HL,(nn) reads three.  UM0077 Table 10: the .L half of
; the mode makes "the CPU data block operate in ADL mode using 24-bit
; registers", and it is the default here because of .assume adl = 1.  The
; 16-bit form needs an explicit suffix -- ld (v),hl assembles to 22 nn mm MM
; whereas ld.sis (v),hl assembles to 40 22 nn mm.
;
; Anything a 24-bit register is stored into is therefore declared .dl.  A .dw
; would let each store spill its top byte into the variable declared next --
; "ld (bnk_top), hl" would overwrite res_len with whatever HLU held, so
; load_portion would read the wrong record count and leave most of RESBDOS3
; unloaded.  Declaring them .dl removes the whole class of fault.  The .db
; variables below are only ever accessed a byte at a time, and nothing
; three-byte-wide is declared immediately before them.
filehandle:     .db     0
res_len:        .db     0   ; pages
bnk_len:        .db     0   ; pages
both_seg:       .db     0
res_top:        .dl     0   ; top address plus one, resident
bnk_top:        .dl     0   ; top address plus one, banked
sys_entry:      .dl     0   ; cold boot entry point
dst_top:        .dl     0
res_len_bytes:  .dl     0
sysfile:        .db     "CPM3.SYS", 0
ccpfile:        .db     "CCP.COM", 0

; --- disk state ---
drv_name:       .db     "cpm"
drv_letter:     .db     "a.dsk", 0      ; letter patched per drive
cur_unit:       .db     $FF ; relative drive whose image is open,
    ; $FF if none
cur_handle:     .db     0   ; its MOS file handle, 0 if none
parm:           .blkb   9, 0; parameter block copied from the BIOS
io_func:        .db     0
io_handle:      .db     0
ccp_len:        .dl     0   ; .dl for the reason given above: DE is
    ; 24 bits, so "ld (ccp_len),de" writes
    ; three bytes, and as a .dw the top one
    ; would land in recbuf.  _g_ldccp does
    ; "ld bc,(ccp_len)" and drives an LDIR
    ; with it, which is not a margin to
    ; leave a block move standing on.
recbuf:         .blkb   128, 0

; --- bank-0 heap and dynamic drive state ---
;
; Three bytes wide throughout, for the reason given in the loader-state note
; above: these hold 24-bit addresses and are read and written with LD HL,(nn)
; and LD (nn),HL, which move three bytes in ADL mode.
heap0_ptr:      .dl     0   ; next free byte, {segment, offset}
heap0_end:      .dl     0   ; first byte NOT available

dreq:           .blkb   15, 0           ; request block copied from the BIOS
dreq_slot:      .dl     0   ; address of the @dtbl entry
dreq_dsm:       .dl     0   ; DSM taken from the DPB
dreq_recsz:     .dl     0   ; physical record size, 128 << PSH
dreq_alv:       .dl     0
dreq_dirbcb:    .dl     0
dreq_dtabcb:    .dl     0
dreq_xdph:      .dl     0
bcb_buf:        .dl     0   ; build_bcb scratch
bcb_ptr:        .dl     0
dreq_psh:       .db     0

; --- FID loader state ---
FID_SEG:        .equ    $04 ; drivers live in segment $04
FID_TOP:        .equ    $050000         ; one past its last byte
FIDLBUF_MAX:    .equ    512 ; FID.INI is read in one go
FIDNAME_MAX:    .equ    64      ; a line may carry a directory as well as
    ; a name, so this is not just 8.3
MAXFIDS:        .equ    16  ; modules that may be loaded in one boot

fdesc:          .blkb   6, 0; character half of the BIOS descriptor,
    ; fid$desc in agonchr.asm.  SIX bytes;
    ; _g_fidinit's copy length must match.
fddesc:         .blkb   14, 0           ; disc half, fid$ddesc in agondsk.asm,
    ; read through the pointer at fdesc+4.
    ; FOURTEEN bytes, likewise.
fid_ptr:        .dl     0   ; next free byte of the $04 heap
fidbase:        .dl     0   ; base of the module being loaded
fid_next:       .dl     0   ; where the next one would go
fid_flen:       .dl     0   ; bytes read from the file
fid_delta:      .dl     0   ; relocation delta
fid_rcnt:       .dl     0   ; fixups left to apply
fid_rptr:       .dl     0   ; position in the fixup table
fid_entry:      .dl     0   ; fid_call's indirect jump cell
fid_req:        .dl     0   ; request block passed to an SVC
fid_sum:        .dl     0   ; checksum scratch
ctbl_dst:       .dl     0   ; @ctbl address in one segment
fidl_ptr:       .dl     0   ; position in the list buffer
fidl_end:       .dl     0   ; one past its last byte
fid_count:      .db     0   ; modules installed
fid_ndev:       .db     0   ; character devices added
fid_op:         .db     0   ; operation for _g_fidcio
fidhandle:      .db     0

fid_cdev:       .blkb   MAXFIDDEV*12, 0 ; four 24-bit handlers per device

; --- drives supplied by a loadable driver ---
fid_ndrv:       .db     0   ; drives added
dpb_used:       .db     0   ; DPB pool slots handed out
dhk_req:        .dl     0   ; request block passed to svc_dhook
dhk_dpb:        .dl     0   ; pool slot chosen for it
dhk_drv:        .db     0   ; drive letter chosen for it
fdio_blk:       .dl     0   ; caller's parameter block, in the CP/M segment
fdio_hand:      .dl     0   ; handler selected for this call
fdio_op:        .db     0   ; 0 read, 1 write, 2 login, 3 init
fdio_drv:       .db     0   ; @adrv
fdio_unit:      .db     0   ; @rdrv
fdio_req:       .blkb   9, 0            ; the block handed to the driver, with
    ; the DMA bank already resolved to a
    ; segment.  Same nine bytes as the block
    ; the stub built; only +07 changes meaning.

; Handlers indexed straight by drive letter: write, read, login and init, four
; 24-bit addresses each.  Indexing by letter rather than through a map costs
; 192 bytes of segment $04 and saves the code a map would need, along with its
; failure modes.  A zero entry means no driver owns that drive.
fid_ddrv:       .blkb   NDRIVELET*12, 0
fidname:        .blkb   FIDNAME_MAX, 0
fid_pat:        .blkb   FIDNAME_MAX, 0  ; the pattern, kept while fidname is
    ; reused for each result
fid_path:       .db     ".", 0          ; the current directory.
    ;
    ; AN EMPTY STRING DOES NOT WORK, even
    ; though FatFS's follow_path reads as
    ; though it should treat one as "the
    ; origin directory itself".  On
    ; hardware it returned FR_NO_PATH.
    ; "." works.  The reason for the
    ; difference is not established; the
    ; behaviour is, by measurement.
fid_dir:        .blkb   FIDNAME_MAX, 0  ; directory part of the current line
fid_sep:        .dl     0   ; last separator seen in it
fid_hassep:     .db     0
fid_dirbuf:     .blkb   DIRBUF_SIZE, 0  ; FatFS DIR
fid_finfo:      .blkb   FINFO_SIZE, 0   ; FatFS FILINFO
fid_list:       .blkb   MAXFIDS*FIDNAME_MAX, 0  ; what to load, in order, with
    ; duplicates already dropped
fid_canon:      .blkb   FIDNAME_MAX, 0  ; canonical form of a candidate
fid_canon2:     .blkb   FIDNAME_MAX, 0  ; and of the entry it is compared with
fid_cstart:     .dl     0   ; where fid_canon started writing
fid_cwd:        .blkb   FIDNAME_MAX, 0  ; working directory, from MOS
fid_nlist:      .db     0
fidlbuf:        .blkb   FIDLBUF_MAX, 0

fidlist:        .db     "FID.INI", 0
fidsig:         .db     "AGONFID1"
fidcrlf:        .db     13, 10, 0
msg_fidopen:    .db     ": not found", 0
msg_fidshort:   .db     ": too short to be a driver", 0
msg_fidsig:     .db     ": not a driver", 0
msg_fidsum:     .db     ": checksum failed", 0
msg_fidapi:     .db     ": built for a different SVC version", 0

; --- M: RAM drive state ---
;
; A separate parameter-block copy from parm above, so a transfer on M: cannot
; disturb one in progress on a card drive.  The three-byte widths are for the
; reason given in the loader-state note above: HL and DE are 24-bit registers
; here, so "ld (mio_off),hl" writes three bytes whether or not that was
; intended.  Declaring them .dl makes the declaration match the instruction.
parm_m:         .blkb   9, 0; parameter block copied from the BIOS
mio_dir:        .db     0   ; 0 = read, 1 = write
mio_off:        .dl     0   ; byte offset from RAM_BASE
mio_len:        .dl     0   ; transfer length in bytes
mio_ram:        .dl     0   ; absolute address within the RAM drive
mio_dma:        .dl     0   ; {segment, offset} of the CP/M buffer

; --- CCP image ---
;
; Formerly an .equ of $070000, which is now the first byte of the M: RAM
; drive.  It is NOT declared with .blkb: doing so emitted 8K of zeros into
; cpm3.bin, taking the file from about 2K to over 10K, all of it padding
; that the loader would then read off the SD card for no reason.
;
; Instead the buffer is placed immediately after the last byte this file
; actually emits, and cleared at startup by zero_ccp.  Declaring it this way
; costs nothing in the image and nothing at run time beyond one LDIR.
;
; image_end MUST BE THE LAST LABEL IN THIS FILE.  Anything declared after it
; would be overlaid by the buffer.
image_end:
CCP_STORE:      .equ    image_end       ; 24-bit address, as before
CCP_END:        .equ    CCP_STORE+CCP_MAX
