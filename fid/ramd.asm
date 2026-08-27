;=====================================================================
; ramd.asm -- example Field Installable Device Driver: a disc drive
;=====================================================================
;
; (c) 2026 Nick J. Date. Released under the MIT Licence. See the
; accompanying LICENSE file for details.
;
;
; Adds a 32K RAM disc as drive K:, carved out of the free tail of
; segment $04 with svc_alloc.
;
; WHY A RAM DISC RATHER THAN SOMETHING USEFUL.  This is a worked
; example: a complete, working disc driver small enough to read in one
; sitting, written so that a driver for real hardware can be built by
; following it.  It makes no MOS calls, needs no image format and does
; not touch M:, so nothing in it distracts from the interface itself.
;
; It also shows the branch a card drive does not use: PSH and PHM of
; zero mean 128-byte physical records, so the supervisor gives the
; drive no data deblocking buffer, exactly as it does for M:.
;
; The disc arrives FORMATTED AND EMPTY.  rd_format fills the whole
; allocation with E5, which is what an empty CP/M directory is, so the
; drive is usable the moment it is hooked:
;
;       K:
;       DIR             -- reports no file
;       PIP K:=C:FOO.COM
;
; All 32 blocks are free, so copying a file onto the drive exercises
; the write path.
;
; Build:
;       python3 mkfid.py ramd.asm RAMD.FID
; then name RAMD.FID in FID.INI, in the directory CP/M is started from.

                include "fid.inc"

                FIDHDR  fid_ems


; ---------------------------------------------------------------------
; GEOMETRY
;
; Checked against the System Guide:
;
;   BLS 1024        -> BSH 3, BLM 7            (Table 3-4)
;   BLS 1024, DSM<256 -> EXM 0                 (Table 3-5)
;   BLS 1024        -> DSM must be <= 255      (section 3.3.2)
;   32 dir entries  -> 1024 bytes = one block  -> AL0 = 80h
;   DRM <= (BLS/32*16)-1 = 511                 (section 3.3.2)
;
; SPT is free, as it is for M:: nothing seeks on a RAM disc, so the
; track and sector split is chosen for cheap arithmetic rather than
; for any physical reason.  32 records per track makes a track 4096
; bytes and the drive exactly 8 tracks, with both figures powers of
; two, so the byte offset is two shifts and an add with no multiply.
; ---------------------------------------------------------------------

RD_SPT:         equ     32              ; 128-byte records per track
RD_TRACKS:      equ     8
RD_BLS:         equ     1024            ; bytes per allocation block
RD_SIZE:        equ     RD_SPT*RD_TRACKS*128    ; 32768
RD_TRKLEN:      equ     RD_SPT*128      ; 4096
RD_DRIVE:       equ     10              ; K:.  Asked for by name rather
                                        ; than with $FF so that the
                                        ; drive letter in this comment
                                        ; and the one on screen are the
                                        ; same.

; --- DIAGNOSTICS -----------------------------------------------------
;
; Set to 0 and not one byte of the tracing remains.
;
; A driver can only be run on the machine itself, so the tracing is
; built in rather than added when something fails.  Each marker is
; printed AFTER the step it names has completed, so the LAST MARKER ON
; SCREEN IS THE LAST STEP THAT WORKED and the fault is in whatever
; comes next.
;
;   RD1     entered
;   RD2=    svc_alloc returned, followed by the address it gave
;   RD3     the address is above this module, so it is safe to write
;   F1      the disc filled with E5
;   RD4     rd_format returned
;   RD5     svc_dhook returned without an error
;
; The helpers preserve every register including the flags, so they can
; be dropped in anywhere without disturbing what they are measuring.

RDDIAG:         equ     0


; ---------------------------------------------------------------------
; fid_ems -- entry point, called once by the loader.
;
; Returns A = 0 to stay resident, HL = sign-on message.
;
; THE DISC IS FORMATTED HERE, not in dev_init.  The kernel calls a
; drive's init entry from BOOT, and BOOT runs on every warm start as
; well as the cold one, so formatting there would wipe the drive every
; time a program exited.  agonm$init0 in agondsk.asm documents the
; same trap for M:.
; ---------------------------------------------------------------------
fid_ems:
    if RDDIAG
                ld      hl, dg_1
                call    dg_msg
    endif
                ld      bc, RD_SIZE
                call    svc_alloc
                jr      c, @nomem
    if RDDIAG
                ; dg_msg and dg_hl preserve every register and the
                ; flags, so HL still holds the block afterwards
                ld      (rd_base), hl
                ld      hl, dg_2
                call    dg_msg
                ld      hl, (rd_base)
                call    dg_hl
    endif

                ; SAFETY CHECK.
                ;
                ; A driver handed a block that overlaps its own image
                ; would fill 32K with E5 starting inside itself,
                ; overwriting the LDIR doing the filling and taking the
                ; machine with it.  Six instructions turn that into a
                ; driver that declines and says so.
                push    hl
                ld      de, mod_end
                or      a
                sbc     hl, de
                pop     hl
                jr      c, @overlap
    if RDDIAG
                ld      hl, dg_3
                call    dg_msg
                ld      hl, (rd_base)
    endif

                ld      (rd_base), hl

                call    rd_format
    if RDDIAG
                ld      hl, dg_4
                call    dg_msg
    endif

                ld      hl, drvblk
                call    svc_dhook
                jr      c, @nodrive
    if RDDIAG
                push    af
                ld      hl, dg_5
                call    dg_msg
                pop     af
    endif

                ; Report the letter the system actually gave us, so
                ; the sign-on can be checked against DIR rather than
                ; taken on trust.
                add     a, 'A'
                ld      (signon_drv), a

                ld      hl, signon
                xor     a                       ; stay resident
                ret


@nomem:
                ld      hl, nomem
                ld      a, 1                    ; discard me
                ret

@overlap:
                ld      hl, overlap
                ld      a, 1                    ; discard me
                ret

@nodrive:
                ; A is the reason code from svc_dhook.  Printed as a
                ; digit rather than decoded, so that a code this
                ; driver has never heard of still reaches the screen.
                add     a, '0'
                ld      (nodrive_rc), a
                ld      hl, nodrive
                ld      a, 1                    ; discard me
                ret


; ---------------------------------------------------------------------
; rd_format -- fill the whole disc with E5.
;
; That is all a CP/M format is: E5 through the directory blocks is an
; empty directory, and E5 through the data blocks is never read,
; because nothing is allocated to point at it.  Block 0 is the
; directory (AL0 = 80h) and blocks 1 to 31 are free.
;
; Called once, from fid_ems.
; ---------------------------------------------------------------------
rd_format:
                push    af
                push    bc
                push    de
                push    hl

                ; ---- the whole disc to E5 ----
                ;
                ; PUSH HL / POP DE, not "ld d,h / ld e,l": the latter
                ; copies sixteen bits and LDIR in ADL mode uses all
                ; twenty-four, so the fill would land in whatever
                ; segment DEU happened to hold.
                ld      hl, (rd_base)
                ld      (hl), $E5
                push    hl
                pop     de
                inc     de
                ld      bc, RD_SIZE-1
                ldir
    if RDDIAG
                ld      hl, dg_f1
                call    dg_msg
    endif

                pop     hl
                pop     de
                pop     bc
                pop     af
                ret


; ---------------------------------------------------------------------
; rd_addr -- HL = the address inside the disc for the request at IX.
;
; offset = track*RD_TRKLEN + sector*128, and both multipliers are
; powers of two, so this is shifts and an add.
;
; Carry set, HL undefined, if the request falls outside the drive.
; That is a bug in the caller rather than a medium fault, but it is
; reported the same way: better a clean error than a transfer into
; whatever lies past the end of the allocation.
; ---------------------------------------------------------------------
rd_addr:
                push    de
                push    bc

                ; HL = track
                ld      hl, 0
                ld      a, (ix+2)
                ld      h, a
                ld      a, (ix+1)
                ld      l, a
                ld      a, h
                or      a
                jr      nz, @out                ; track >= 256: impossible
                ld      a, l
                cp      RD_TRACKS
                jr      nc, @out

                ld      b, 12                   ; * 4096
@trk:
                add     hl, hl
                djnz    @trk
                push    hl

                ; DE = sector
                ld      hl, 0
                ld      a, (ix+4)
                ld      h, a
                ld      a, (ix+3)
                ld      l, a
                ld      a, h
                or      a
                jr      nz, @outpop
                ld      a, l
                cp      RD_SPT
                jr      nc, @outpop

                ld      b, 7                    ; * 128
@sec:
                add     hl, hl
                djnz    @sec
                push    hl
                pop     de
                pop     hl
                add     hl, de                  ; HL = byte offset

                ld      de, (rd_base)
                add     hl, de

                pop     bc
                pop     de
                or      a                       ; carry clear
                ret

@outpop:
                pop     hl                      ; discard the track part
@out:
                pop     bc
                pop     de
                scf
                ret


; ---------------------------------------------------------------------
; The four handlers.
;
; Each is entered with HL pointing at the nine-byte request block, and
; returns A = 0 for success or non-zero for a permanent error.
;
; The DMA address at +05 is already a full 24-bit address: the
; supervisor resolved the CP/M bank into a segment before calling, so
; there is nothing here that knows or cares how banks are mapped.
; ---------------------------------------------------------------------

; read -- disc to memory
dev_read:
                push    ix
                push    hl
                pop     ix
                call    rd_addr
                jr      c, @bad
                ld      de, (ix+5)              ; DMA, 24 bits
                ld      bc, 128
                ldir
                pop     ix
                xor     a
                ret
@bad:
                pop     ix
                ld      a, 1
                ret


; write -- memory to disc
dev_write:
                push    ix
                push    hl
                pop     ix
                call    rd_addr
                jr      c, @bad
                push    hl
                pop     de                      ; DE = disc address
                ld      hl, (ix+5)              ; HL = DMA, 24 bits
                ld      bc, 128
                ldir
                pop     ix
                xor     a
                ret
@bad:
                pop     ix
                ld      a, 1
                ret


; login -- nothing can change under us, so this always succeeds
dev_login:
                xor     a
                ret


; init -- nothing to do.  See the note on fid_ems: this must NOT
; format, because BOOT calls it on every warm start.
dev_init:
                xor     a
                ret


; ---------------------------------------------------------------------
; The drive request block, in the shape svc_dhook expects.
; ---------------------------------------------------------------------
drvblk:
                db      RD_DRIVE                ; +00 drive, K:
                db      0                       ; +01 unit
                db      0                       ; +02 flags, reserved

                ; DPB -- see the geometry note at the head of the file
                dw      RD_SPT                  ; SPT 128-byte records/track
                db      3                       ; BSH 1024-byte blocks
                db      7                       ; BLM block mask
                db      0                       ; EXM extent mask
                dw      31                      ; DSM highest block number
                dw      31                      ; DRM highest directory entry
                db      $80                     ; AL0 one directory block
                db      $00                     ; AL1
                dw      $8000                   ; CKS permanently mounted --
                                                ;     REQUIRED, see fid.inc
                dw      0                       ; OFF reserved tracks
                db      0                       ; PSH 128-byte records
                db      0                       ; PHM no blocking

                dl      dev_read                ; +14 operation order, NOT
                dl      dev_write               ; +17 XDPH order
                dl      dev_login               ; +1A
                dl      dev_init                ; +1D


signon:
                db      "RAMD: 32K RAM disc, drive "
signon_drv:
                db      "?", ":", 0

nomem:
                db      "RAMD: not enough room in segment $04", 0

overlap:
                db      "RAMD: allocation overlaps the driver -- not safe", 0

nodrive:
                db      "RAMD: no drive installed, reason "
nodrive_rc:
                db      "0", 0


; ---------------------------------------------------------------------
; The disc itself is allocated at load time; only its address is here.
; ---------------------------------------------------------------------
rd_base:
                dl      0


    if RDDIAG
; =====================================================================
; DIAGNOSTICS.  All of this goes when RDDIAG is 0.
;
; Both helpers preserve EVERY register and the flags, so a marker can
; be dropped between a computation and its use without changing what
; is being measured.
; =====================================================================

; dg_msg -- print the null-terminated string at HL.
dg_msg:
                push    af
                push    hl
                call    svc_pmsg
                pop     hl
                pop     af
                ret

; dg_hl -- print HL as six hex digits.
dg_hl:
                push    af
                push    bc
                push    de
                push    hl
                ld      (dg_val), hl
                ld      a, (dg_val+2)
                call    dg_byte
                ld      a, (dg_val+1)
                call    dg_byte
                ld      a, (dg_val+0)
                call    dg_byte
                pop     hl
                pop     de
                pop     bc
                pop     af
                ret

dg_byte:
                push    af
                rrca
                rrca
                rrca
                rrca
                call    dg_nib
                pop     af
                ; fall through for the low nibble
dg_nib:
                and     $0F
                add     a, '0'
                cp      '9'+1
                jr      c, @put
                add     a, 7
@put:
                call    svc_conout
                ret

dg_val:         dl      0

dg_1:           db      13, 10, "RD1", 0
dg_2:           db      " RD2=", 0
dg_3:           db      " RD3", 0
dg_f1:          db      " F1", 0
dg_4:           db      " RD4", 0
dg_5:           db      " RD5", 0
    endif


; mod_end -- one past the last byte of the module.  Used by the safety
; check in fid_ems, which refuses to run if the block svc_alloc handed
; back starts below here.  It must stay the LAST label in the file.
mod_end:
