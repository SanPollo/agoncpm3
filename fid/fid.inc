;=====================================================================
; fid.inc -- writing a Field Installable Device Driver for Agon CP/M 3
;=====================================================================
;
; (c) 2026 Nick J. Date. Released under the MIT Licence. See the accompanying
; LICENSE file for details.
;
;
; A FID is an ADL-mode eZ80 module loaded into the free tail of segment
; $04 and reached through the SVC table below.  It is not a CP/M
; program and it is not a PRL: it never runs in a CP/M bank, and it
; must not call the BDOS or the BIOS.  Everything it needs from the
; system comes through the SVC table.
;
; BUILDING
;   ez80asm is an absolute assembler, so a driver is assembled twice at
;   two origins and mkfid.py recovers the relocation information by
;   comparing the two images:
;
;       python3 mkfid.py mydriver.asm MYDRIVER.FID
;
;   Then name MYDRIVER.FID in FIDCONF.INI in the SD card root, one
;   filename per line.  Blank lines and lines starting ';' or '#' are
;   ignored, and load order is the order in the file.
;
; ENTRY
;   The loader calls the module at its base address, which the FIDHDR
;   macro turns into a jump to the label given.  On return:
;
;       A  = 0 to stay resident, non-zero to be discarded
;       HL = a null-terminated sign-on message, or 0 for silence
;
;   A module that declines is dropped and its space reclaimed: the
;   loader puts its heap pointer back to the module's base, which
;   releases both the image and anything the module allocated before
;   it decided to decline.
;
;   NOTE FOR ANYONE WHO READ AN EARLIER VERSION OF THIS FILE.  The
;   loader used to reclaim a declined module by NOT advancing its heap
;   pointer until the entry routine had returned.  That was wrong: it
;   left the pointer aimed at the module itself for the whole of the
;   entry routine, so svc_alloc handed a driver its own code.  The
;   pointer is now advanced BEFORE the module runs, so svc_alloc is
;   safe to call from the entry routine, which is the only place most
;   drivers will want to call it.
;
; ADDRESSES
;   References to SVC entries need no relocation -- the table is at a
;   fixed address for all time.  References to the module's own code
;   and data are fixed up when it is loaded.  This means a driver may
;   use absolute addressing freely.
;
; MOS CALLS
;   MBASE holds the CP/M bank while CP/M is running, so a driver must
;   bracket any MOS call:
;
;       call    svc_mosenter
;       ld      a, mos_function
;       rst.lil $08
;       call    svc_mosleave

; --- the SVC table, fixed address, append only ---
svc_base:       equ     $040180

svc_version:    equ     svc_base+$00    ; -> HL = SVC table version
svc_pmsg:       equ     svc_base+$04    ; HL = null-terminated string
svc_alloc:      equ     svc_base+$08    ; BC = bytes -> HL in segment $04
svc_alloc0:     equ     svc_base+$0C    ; BC = bytes -> HL in CP/M bank 0
svc_chook:      equ     svc_base+$10    ; HL = device block -> A = device
svc_conout:     equ     svc_base+$14    ; A = character, to the console
svc_conin:      equ     svc_base+$18    ; -> A = character
svc_const:      equ     svc_base+$1C    ; -> A = $FF if a character waits
svc_mosenter:   equ     svc_base+$20    ; MBASE = 0, for a MOS call
svc_mosleave:   equ     svc_base+$24    ; MBASE back to the CP/M bank
svc_dhook:      equ     svc_base+$28    ; HL = drive block -> A = drive

FID_API:        equ     1

; --- character device mode bits (System Guide Table 4-7) ---
mb_input:       equ     $01
mb_output:      equ     $02
mb_in_out:      equ     $03
mb_soft_baud:   equ     $04
mb_serial:      equ     $08
mb_xon_xoff:    equ     $10
baud_none:      equ     0

; =====================================================================
; ADDING A DISC DRIVE
; =====================================================================
;
; svc_dhook takes HL pointing at a 32-byte block in segment $04:
;
;   +00  db  drive     0 = A: through 15 = P:, or $FF for the first
;                      free letter the system is willing to assign
;                      automatically.  An explicit letter is refused
;                      if it is already in use; $FF is refused only
;                      if nothing at all is free.
;   +01  db  unit      relative drive number.  It is handed back at
;                      +00 of the request block on every call, so one
;                      driver can serve several drives and tell them
;                      apart.
;   +02  db  flags     reserved, must be zero
;   +03  17 bytes      the DPB, by value.  It is COPIED into common
;                      memory, so this copy may be discarded or
;                      reused afterwards.
;   +14  dl  read      the four handlers, 24-bit, in segment $04, in
;   +17  dl  write     THIS ORDER -- it is the order the system
;   +1A  dl  login     dispatches by, and is not the order the four
;   +1D  dl  init      entries appear in a CP/M 3 XDPH.
;
; Returns A = the drive number and carry clear, or carry set with A
; holding a reason code.
;
; $FF DOES NOT MEAN "THE FIRST LETTER WITH NO DRIVE ON IT".  A: and B:
; have no drive on them and are held back for floppies, so automatic
; assignment starts above them, at whatever floor the BIOS declares.
; A driver that genuinely wants A: -- a real floppy driver -- asks for
; it by number, which ignores the floor.
;
; TWO RULES THE DPB MUST OBEY
;
;   CKS must have bit 15 set: the medium must be permanently mounted.
;   A removable one needs a checksum vector, and there is no common
;   memory left to allocate one from.
;
;   PSH and PHM of 0 mean 128-byte physical records and no data
;   deblocking buffer, which is the simplest thing to write.  Larger
;   physical records work and save transfers on a real device.
;
; THE HANDLERS
;
; All four are called with HL pointing at a nine-byte request block in
; segment $04:
;
;   +00  db  unit      the relative drive, as given at +01 above
;   +01  dw  track
;   +03  dw  sector
;   +05  dl  dma       a FULL 24-BIT ADDRESS.  The CP/M bank has
;                      already been resolved to a segment, so a driver
;                      neither knows nor needs to know how banks map
;                      to memory: this is an address to LDIR to or
;                      from.
;   +08  db  count     records to transfer, always 1
;
; Only +00 is meaningful for login and init.  Every handler returns
; A = 0 for success, non-zero for a permanent error.
;
; A DRIVER MUST NOT FORMAT ITS MEDIUM IN init.  The kernel calls init
; from BOOT, and BOOT runs on every warm start, so anything written
; there is written again each time a program exits.  One-time work
; belongs in the driver's load entry, which runs once.

; --- the header ---
;
; Must be the first thing in the module.  mkfid.py fills in the
; lengths, the fixup table and the checksum; the zeros here are
; placeholders it overwrites.
;
;   FIDHDR entrypoint

                macro   FIDHDR entry
                jp      entry                   ; +00, relocated
                db      "AGONFID1"              ; +04 signature
                dl      0                       ; +0C link base
                dl      0                       ; +0F image length
                dl      0                       ; +12 bss length
                dl      0                       ; +15 reloc offset
                dl      0                       ; +18 reloc count
                dw      FID_API                 ; +1B api version
                dw      0                       ; +1D checksum
                db      0                       ; +1F reserved
                endmacro
