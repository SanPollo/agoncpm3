title 'Agon CP/M 3 BIOS: disk I/O'

; =====================================================================
;  CP/M-80 Version 3  --  Modular BIOS  --  Agon Light
; =====================================================================
;
; (c) 2026 Nick J. Date. Released under the MIT Licence. See the accompanying
; LICENSE file for details.
;
; CP/M 3 code:
;     Copyright (C) 1978-1982 Digital Research, Inc.
;
; CP/M and its derivatives are used and distributed under the
; CP/M Licence 2022, with permission granted by DRDOS, Inc.,
; successor in interest to Digital Research.
;
;
; Drives are plain files on the SD card, reached through MOS's file
; API by way of the ADL-mode supervisor.  This module defines the
; drive table and one drive; the remaining drives are added by
; repeating the XDPH once the first one works.
;
; PHYSICAL SECTOR SIZE
; --------------------
; CP/M 2.2 forced the BIOS to deal in 128-byte sectors.  CP/M 3 will
; do its own blocking and deblocking if PSH and PHM in the DPB say
; the medium has larger physical sectors, so this driver works in
; 512-byte sectors and lets the BDOS assemble the 128-byte records.
; That turns four MOS read calls into one, which is the single
; largest performance difference between this and the CP/M 2.2 port.

public	@dtbl
public	agon$dph0
public	agon$newdrv
public	agonm$dpb		; ?init derives the M: size from it
public	fid$ddesc		; the disc half of the FID descriptor.
				;
				; RMAC IGNORES '$' AND KEEPS SIX SIGNIFICANT
				; CHARACTERS, so this exports as FIDDDE.  No
				; other public symbol here or in agonchr.asm
				; collides with it -- checked, because
				; agon$common$low and agon$common$len once
				; both became AGONCO and cost a debugging
				; session.

extrn	@adrv,@rdrv			; BDOS disk parameters
extrn	@trk,@sect,@dma,@dbnk,@cnt
extrn	?pderr,?pmsg			; kernel error reporting

maclib	agon


dseg	; Drive tables and driver code may be banked.  Only the
		; DPB itself has to be resident -- see below.


	; @dtbl -- one word per drive letter, pointing at that drive's
	; DPH, or zero if the letter is not present.  Sixteen entries,
	; A: through P:.

@dtbl:
	dw	0,0			; A:, B:  reserved for physical floppy
					;         drives, to be installed by a
					;         loadable driver
	dw	agon$dph0		; C:  the boot drive, cpmc.dsk
	dw	0,0,0,0,0,0,0		; D: - J:  cpmd.dsk to cpmj.dsk, each
					;          installed at ?init if its
					;          image is present
	dw	0,0			; K:, L:  free for loadable drivers
	dw	agonm$dph		; M:  RAM drive
	dw	0,0,0			; N: - P:  free for loadable drivers


	; Extended Disk Parameter Header for drive C:, the boot drive.
	;
	; The four driver pointers and the relative drive number sit
	; immediately BEFORE the DPH label -- the BDOS is handed the
	; address of the DPH proper and the kernel reaches backwards for
	; the driver entries.

	dw	agon$write
	dw	agon$read
	dw	agon$login
	dw	agon$init0
	db	2,0			; RELATIVE DRIVE 2, not 0.  The
					; relative drive number is also the
					; image letter: the supervisor forms
					; the filename as 'a' + unit, so unit
					; 2 is cpmc.dsk.  Drive letter, unit
					; and image letter are all the same
					; value, and there is no offset
					; between them to keep in step.

agon$dph0:
	DPH	0,agon$dpb0,0,0		; no skew, permanent medium;
					; GENCPM fills CSV and ALV


	; Extended Disk Parameter Header for drive M:, the RAM drive.
	;
	; Same shape as A:, but the driver entries below point at the
	; RAM-drive routines and the relative drive number is meaningless
	; (there is no image file and no MOS handle), so it is left zero.

	dw	agonm$write
	dw	agonm$read
	dw	agonm$login
	dw	agonm$init0
	db	0,0			; relative drive number unused

agonm$dph:
	DPH	0,agonm$dpb,0,0		; no skew, permanent medium


	cseg	; THE DPB MUST BE IN COMMON MEMORY.
		;
		; Not because the resident BDOS reads it: RESBDOS3 is built
		; from resbdos.asm alone, which contains only function
		; dispatch, the hash search and the move helpers, and never
		; touches a DPB.  The banked BDOS reads it at select time
		; (bdos30.asm, selectdisk, "lhld dpbaddr ... call move")
		; while running in bank 0, so bank 0 would serve for that.
		;
		; The constraint is BDOS function 31, which returns the DPB
		; address to the CALLING PROGRAM:
		;
		;   func31: call curselect
		;           lhld dpbaddr
		;           shld aret
		;
		; The caller is a transient in bank 1.  A DPB in bank 0 would
		; leave SHOW, and anything else that asks a drive for its
		; parameters, reading whatever bank 1 holds at that address.
		;
		; This matters because the supervisor allocates every OTHER
		; drive structure in bank 0 -- see agon$newdrv below -- and
		; the DPB is the one thing it cannot.

	; Disk Parameter Block for an 8 MB drive image.
	;
	; GEOMETRY: this matches the "nihirash" definition in the cpmtools
	; diskdefs file, so images made by cpmtools with that format are
	; usable here directly:
	;
	;   diskdef nihirash
	;     seclen    128
	;     tracks   1024
	;     sectrk     64
	;     blocksize 8192
	;     maxdir   2048
	;     skew        0
	;     boottrk     0
	;
	; Capacity is 1024 * 64 * 128 = 8388608 bytes, i.e. still exactly
	; 8 MB -- this is a change of shape, not of size.
	;
	; The fields below are derived using the dpb macro given in the
	; CP/M 3 System Guide (Appendix H, GENCPM), invoked as
	;
	;   dpb 512,16,1024,8192,2048,0
	;
	; i.e. 512-byte physical sectors, 16 of them per track, 1024
	; tracks, 8192-byte blocks, 2048 directory entries, 0 reserved
	; tracks.  Working the macro through by hand:
	;
	;   SPT = physical sectors/track * (physical sector size / 128)
	;       = 16 * 4 = 64 records per track
	;   BLS 8192            -> BSH 6, BLM 63
	;   8388608 / 8192      -> 1024 blocks, so DSM = 1023
	;   2048 dir entries    -> DRM = 2047
	;   EXM: for BLS 8192, DSM > 255 gives EXM = 3
	;   AL0/AL1: 2048 entries * 32 bytes = 65536 bytes of directory,
	;            which is eight 8192-byte blocks, so the top EIGHT
	;            bits are set -> AL0 = 0FFh, AL1 = 000h
	;
	; PSH/PHM stay at 2/3.  They describe how this BIOS batches
	; transfers, not the on-disk layout, so keeping 512-byte physical
	; sectors preserves the 4:1 reduction in MOS calls noted at the
	; top of this file without altering the format at all.
	;
	; CKS: a drive is declared permanently mounted by setting BIT 15,
	; not by setting the field to zero.  System Guide: the checksum
	; vector size is CKS AND 7FFFh, and bit 15 set means the drive is
	; permanently mounted and no checksums are taken.  A field of 0
	; does NOT mean permanent: it asks for a zero-length checksum
	; vector on a REMOVABLE drive, which is a different thing.
	; 8000h is the value that states the intent.

	; THERE IS NO RESERVED BYTE IN A CP/M 3 DPB.  A spurious
	; "db 0 ; (reserved)" after EXM would shift every field after it
	; by one byte.  DRI's own dpb.lit gives the offsets and leaves no
	; room for it:
	;
	;   spt$w 0, blkshf$b 2, blkmsk$b 3, extmsk$b 4, blkmax$w 5,
	;   dirmax$w 7, dirblk$w 9, chksiz 11, offset$w 13
	;
	; (so PSH is at 15 and PHM at 16, and the DPB is 17 bytes.)
	;
	; With such a byte the BDOS reads DSM as 65280 rather than 2047
	; -- a 267 MB disk on an 8 MB image -- DRM as 65287 rather than
	; 511, AL0 as 1, and PSH as 0.  GENCPM reports it too, as "The
	; physical record size is 0080H" when this DPB asks for 512.
agon$dpb0:
	dw	64			; SPT  128-byte records per track
	db	6			; BSH  block shift, 8192-byte blocks
	db	63			; BLM  block mask
	db	3			; EXM  extent mask
	dw	1023			; DSM  highest block number
	dw	2047			; DRM  highest directory entry
	db	0FFh			; AL0  eight directory blocks
	db	000h			; AL1
	dw	8000h			; CKS  bit 15 = permanently mounted
	dw	0			; OFF  reserved tracks
	db	2			; PSH  512-byte physical sectors
	db	3			; PHM  physical sector mask


	; Disk Parameter Block for M:, the RAM drive.
	;
	; EXTENT AND DERIVATION
	; ---------------------
	; The drive occupies $070000 through $0BBFFF inclusive.  Those
	; bounds come from the machine, not from choice:
	;
	;   $070000  first segment above CP/M bank 0 ($06)
	;   $0BBFFF  last byte of MOS's USER:LO region
	;
	; MOS 3.0.2's own *MEM command on a stock Agon Light 2 reports
	;
	;   USER:LO  &040000-&0bbfff  507904 bytes
	;   MOS:DATA &0bc000-&0bcbd4    3029 bytes
	;   MOS:HEAP &0bcbd5-&0bf7ff   11307 bytes
	;   STACK24  &0bf800-&0c0000    2048 bytes
	;
	; so $0BC000 is a hard floor: MOS's static data, heap and stack
	; sit above it and back the file API this BIOS calls for every
	; transfer on every OTHER drive.  Writing there would break A:.
	;
	; That gives $0BC000 - $070000 = $4C000 = 311296 bytes, and it is
	; ONE CONTIGUOUS RUN -- segments $07 through $0A plus the $0B0000
	; part-segment are adjacent, and the supervisor addresses them
	; linearly in ADL mode, so no split-region arithmetic is needed.
	;
	; Fields, using the same System Guide macro as A: above:
	;
	;   BLS 2048            -> BSH 4, BLM 15
	;   311296 / 2048       -> 152 blocks, so DSM = 151
	;   512 dir entries     -> DRM = 511
	;   EXM: for BLS 2048, DSM < 256 gives EXM = 1
	;   AL0/AL1: 512 entries * 32 bytes = 16384 bytes of directory,
	;            which is eight 2048-byte blocks -> AL0 = 0FFh
	;
	; SPT is chosen, not forced: nothing seeks on a RAM drive, so the
	; track/sector split is free.  128 records per track makes each
	; track 16384 bytes, and 311296 / 16384 = 19 tracks EXACTLY, with
	; both 128s a power of two.  The supervisor's offset calculation
	; is then two shifts and an add, with no multiply.
	;
	; PSH/PHM are 0/0.  Blocking into 512-byte physical sectors exists
	; to cut the number of MOS calls on a real device; there are no
	; MOS calls here, so it would add deblocking work for nothing.

agonm$dpb:
	dw	128			; SPT  128-byte records per track
	db	4			; BSH  block shift, 2048-byte blocks
	db	15			; BLM  block mask
	db	1			; EXM  extent mask
	dw	151			; DSM  highest block number
	dw	511			; DRM  highest directory entry
	db	0FFh			; AL0  eight directory blocks
	db	000h			; AL1
	dw	8000h			; CKS  bit 15 = permanently mounted
	dw	0			; OFF  reserved tracks
	db	0			; PSH  128-byte records, no blocking
	db	0			; PHM  physical sector mask


	; DPB POOL FOR DRIVES ADDED BY A LOADABLE DRIVER
	; ----------------------------------------------
	; A FID supplies its DPB by value and the supervisor copies it
	; into one of these slots.  THE POOL HAS TO BE HERE, IN COMMON,
	; for exactly the reason given against agon$dpb0 above: BDOS
	; function 31 hands the DPB address to a transient running in
	; bank 1, so a DPB in bank 0 would be read as whatever bank 1
	; happens to hold at that address.
	;
	; C: through J: sidestep the problem by sharing agon$dpb0, which
	; is legitimate only because their geometry is identical.  A
	; driver's geometry is its own, so it needs a DPB of its own,
	; and the supervisor has no common memory to allocate from --
	; GENCPM owns all of it.  Hence a fixed pool, declared here at
	; assembly time.
	;
	; COST, MEASURED: the pool costs 68 bytes of the resident BIOS
	; CSEG, which stands at 960 bytes of the 1,024 in its four-page
	; SPR allocation, so nothing moves in the TPA.  The 64 bytes
	; left over hold three more slots -- SEVEN in all -- before the
	; boundary shifts and a page of TPA goes with it.  NDPBSLOT may
	; be raised that far, but not without checking DRLINK's CODE
	; SIZE and GENCPM's report afterwards.
	;
	; The supervisor is told the address and the slot count through
	; fid$ddesc below; nothing here is hard-coded on the other side.

NDPBSLOT equ	4			; DPB slots for loadable drivers

dpb$pool:
	ds	17*NDPBSLOT


	dseg	; driver code may be banked


	; agon$init0
	;	First-time initialisation, called once from the kernel's
	;	BOOT for each drive.  Nothing to do: the supervisor opens
	;	the drive image lazily on first login.

agon$init0:
	ret


	; agon$login
	;	Called when a drive is logged in, i.e. when the medium may
	;	have changed.  <@rdrv> holds the relative drive number.
	;	The supervisor opens the corresponding image file on the
	;	SD card and keeps the MOS file handle.
	;
	;	Returns with <A> = 0 and Z set on success.

agon$login:
	lda	@rdrv
	mov	c,a
	GATE	g$dlogin
	ora	a
	ret


	; agon$read / agon$write
	;	Transfer @cnt physical sectors starting at track @trk,
	;	sector @sect, to or from @dma in bank @dbnk.
	;
	;	Everything is handed to the supervisor, which computes the
	;	byte offset into the image file, seeks, and transfers.  It
	;	has full 24-bit addressing, so a DMA address in a
	;	different bank costs nothing extra -- no ?xmove dance is
	;	needed on this machine.
	;
	;	Return <A> = 0 and Z set on success, <A> = 1 for a
	;	permanent error, <A> = 0FFh for media change.

agon$read:
	mvi	a,0
	jmp	disk$io

agon$write:
	mvi	a,1
	; fall through

; disk$io -- assemble the parameter block and hand it to the supervisor.
;	<A> = 0 to read, 1 to write.
;
;	The transfer parameters will not fit in registers, so they are gathered
;	into one block whose address goes to the supervisor in <HL>.  The block
;	lives in this module's DSEG, which is in bank 0 -- the bank selected
;	whenever the banked BDOS calls a disk routine, so the supervisor can
;	read it through the currently selected segment.

disk$io:
	sta	io$dir
	lda	@rdrv
	sta	p$drive
	lhld	@trk
	shld	p$trk
	lhld	@sect
	shld	p$sect
	lhld	@dma
	shld	p$dma
	lda	@dbnk
	sta	p$dbnk
	; ONE PHYSICAL SECTOR PER CALL.  @cnt IS NOT A LENGTH.
	;
	; Storing @cnt here and letting the supervisor multiply the
	; transfer length by it is a misreading of @cnt, and a fatal one,
	; because @cnt is normally ZERO.
	;
	; System Guide Table 2-5: SETTRK, SETSEC, SETDMA, SETBNK and
	; READ/WRITE are "called for every read or write of a physical
	; sector".  One call, one sector.  MULTIO is only a HINT that the
	; next n calls will be contiguous, so a BIOS that wants to may
	; fetch them all at once and count down the following calls.  DRI's
	; own disk module, fd1797sd.asm, does not reference @cnt at all.
	;
	; Worse, the BDOS only calls MULTIO when the count is not one.
	; bdos30.asm:
	;   call shr.physhf / mov a,h / cpi 1 / mov c,a / cnz mult.iof
	; (dots stand for the dollar separator).  Directory I/O is always
	; single-sector, so MULTIO is never called before it and @cnt keeps
	; whatever it held -- and bioskrnl.asm declares it as "db 0".
	;
	; So every transfer asked MOS for ZERO bytes.  The read succeeded,
	; moved nothing, and the directory buffer kept its pre-boot
	; contents, which is why DIR reported "No File" on a disk image
	; that CP/M 2.2 reads perfectly.
	mvi	a,1			; exactly one physical sector
	sta	p$cnt

	lxi	h,parm$blk
	lda	io$dir
	ora	a
	jnz	disk$wr
	GATE	g$dread
	ora	a
	rz
	jmp	disk$error
disk$wr:
	GATE	g$dwrite
	ora	a
	rz
	; fall through

disk$error:
	push	psw
	call	?pderr
	lxi	h,err$msg
	call	?pmsg
	pop	psw
	mvi	a,1			; permanent error
	ora	a
	ret

err$msg:
	db	'SD card transfer failed',0

; Parameter block passed to the supervisor.  The layout is fixed and matches
; the comment in cpm3.asm; the two must be changed together.

parm$blk:
p$drive:	ds	1	; +0 relative drive
p$trk:		ds	2	; +1 track
p$sect:		ds	2	; +3 sector
p$dma:		ds	2	; +5 DMA address within the bank at +7
p$dbnk:		ds	1	; +7 DMA bank
p$cnt:		ds	1	; +8 sector count, always 1 (see disk$io)

io$dir:		ds	1	; 0 = read, 1 = write


; =====================================================================
;  DRIVES D: TO J: -- INSTALLED AT RUN TIME
; =====================================================================
;
; None of D: to J: is in @dtbl above, so GENCPM allocated nothing for
; any of them.  Each is built instead by the supervisor at ?init time
; out of bank-0 memory that is not the system generator's to give:
; allocation vector, directory and data buffer control blocks, the
; buffers themselves, and the XDPH.
;
; C: IS DELIBERATELY NOT ONE OF THEM.  It is the boot drive: the CCP
; starts on it, so it has to exist in @dtbl whether or not its image
; opens, and something has to be present at generation time for GENCPM
; to allocate the shared directory and data buffers against.
;
; A drive exists if its image exists.  Bit 0 of the flags byte tells
; the supervisor to open cpm<x>.dsk first and decline to install the
; drive if it is not there, so a letter with no image simply does not
; appear -- which is what CP/M 3 needs, because the kernel's seldsk
; DISCARDS the login routine's return value:
;
;	mov a,e - ani 1 - jnz not$first$select
;	push h - xchg
;	...  call ipchl		; call LOGIN
;	pop h			; recover DPH pointer
;
; HL always comes back holding the DPH, so a failed login cannot make
; a drive report itself absent.  The only way to say "no such drive"
; is a zero @dtbl entry, and the only safe moment to decide that is
; before the BDOS has seen any of them.  This is the CP/M 2.2 port's
; behaviour arrived at by a different route: it closed and reopened a
; single image on every drive change and returned HL = 0 when the open
; failed, which CP/M 2.2 did honour.
;
; THE GEOMETRY AND THE DRIVER ARE A:'s.  Every image is a nihirash
; 8 MB file reached through the same four routines, so the request
; blocks differ only in the drive number.  The DPB is SHARED with A:
; rather than allocated: it has to be in common memory (see the note
; by agon$dpb0 above) and the supervisor has no common memory to hand
; out.  That is not a workaround -- GENCPM does the same for drives of
; identical geometry; in an eight-drive trial generation all eight
; DPHs pointed at one DPB.
;
; COST: nothing at generation time, nothing in common memory, and
; nothing in the TPA.  Each installed drive takes 1,349 bytes of the
; supervisor's 44,800-byte bank-0 heap -- 256 for the allocation
; vector, 529 each for the directory and data buffers with their BCBs
; and list heads, and 35 for the XDPH.  All seven together is 9,443
; bytes, about a fifth of the heap.

FIRSTDYN equ	3		; first dynamic drive, D:
NDYNDRV	equ	10		; one past the last, J:
FIRSTAUTO equ	10		; first letter a LOADABLE DRIVER may be
				; given when it asks for "any free drive",
				; i.e. K:.
				;
				; This constant exists because "free" and
				; "unused" are not the same thing here.  The
				; supervisor decides a letter is free by
				; finding a zero @dtbl entry, and A: and B:
				; ARE zero -- they are held back for floppies
				; by intention.  Without a floor, the first
				; driver to ask for any free drive would
				; silently be handed A:.
				;
				; A driver that genuinely wants A: -- a real
				; floppy driver -- still may: it asks for the
				; letter explicitly, which bypasses this and
				; only fails if the letter is already taken.
				;
				; The floor is passed to the supervisor in
				; fid$ddesc, so the policy is stated once,
				; here, beside the map it governs.
				;
				; A: and B: are left for physical floppy
				; drives supplied by a loadable driver, C:
				; is the static boot drive, M: is the RAM
				; drive, and K:, L: and N: to P: are free
				; for loadable drivers to claim.
				;
				; Eight images are INSTALLED at once (C: to
				; J:), but only ONE IS OPEN at a time: the
				; supervisor opens on demand and closes on a
				; drive change.  There is no handle array and
				; no relation to MOS_maxOpenFiles: holding a
				; handle per drive would exhaust MOS's eight
				; and leave none for the FID loader.  NDRIVES
				; in cpm3.asm is just the range of unit
				; numbers drv_open accepts, and must cover
				; unit 9.


	; agon$newdrv
	;	Install every SD-card drive whose image is present.
	;	Called from ?init, which runs from the kernel's BOOT with
	;	bank 0 selected and BEFORE the kernel's drive
	;	initialisation loop, so a drive installed here still gets
	;	its init entry called.
	;
	;	Returns <A> = the number of hard drives present, counting
	;	the boot drive.  ?init reports that figure; nothing is
	;	printed here except a genuine failure, since a letter with
	;	no image is an ordinary configuration, not a fault.

agon$newdrv:
	; NO HANDLE RESERVATION IS NEEDED HERE.
	;
	; The supervisor holds ONE image open at a time and opens on
	; demand, so there is nothing to run out of and nothing to
	; reserve.  Eight drives each holding a handle would exhaust
	; MOS's eight open files and leave none for the FID loader to
	; open FID.INI with.

	mvi	b,FIRSTDYN		; first dynamic drive, D:
	mvi	c,1			; drives present: the boot drive

newdrv$loop:
	mov	a,b
	sta	drv$req+0		; logical drive
	sta	drv$req+1		; relative drive -- THE SAME VALUE.
					; The supervisor forms the image name
					; as 'a' + unit, so drive letter, unit
					; and image letter agree by
					; construction rather than by an
					; offset someone has to maintain.
	push	b
	lxi	h,drv$req
	GATE	g$drvnew
	pop	b
	ora	a
	jz	newdrv$ok
	cpi	2			; DRV_NOIMAGE -- no image, no drive,
	jz	newdrv$next		; and nothing to say about it
	push	b			; anything else is a real failure
	adi	'0'
	sta	drv$code
	mov	a,b
	adi	'A'
	sta	drv$failltr
	lxi	h,drv$failmsg
	call	?pmsg
	pop	b
	jmp	newdrv$next

newdrv$ok:
	inr	c

newdrv$next:
	inr	b
	mov	a,b
	cpi	NDYNDRV
	jc	newdrv$loop

	mov	a,c			; count, including the boot drive
	ret

drv$failmsg:
	db	13,10
drv$failltr:
	db	'D',': not installed, reason '
drv$code:
	db	'0',13,10,0

; Request block, reused for each drive in turn -- only the two drive
; numbers at +0 and +1 change, and agon$newdrv writes them before each
; call.  Read by the supervisor through the currently selected
; segment, which at ?init time is bank 0, the same arrangement
; parm$blk above relies on.  The layout is fixed and matches the
; comment on _g_drvnew in cpm3.asm; the two must be changed together.

drv$req:
	db	1			; +0  logical drive, patched per drive
	db	1			; +1  relative drive, patched with it
	db	1			; +2  flags: bit 0 = verify the image
	dw	agon$write		; +3  driver entry points, all of
	dw	agon$read		; +5  them the ones A: uses
	dw	agon$login		; +7
	dw	agon$init0		; +9
	dw	agon$dpb0		; +11 shared with A:, in common
	dw	@dtbl			; +13


; =====================================================================
;  M: -- RAM DRIVE
; =====================================================================
;
; The drive is a flat run of RAM at $070000-$0BBFFF (see agonm$dpb
; above for where those bounds come from).  There is no image file and
; no MOS handle, so there is nothing to open and nothing to close: a
; transfer is a block move performed by the supervisor, which has the
; 24-bit addressing needed to reach outside the CP/M segments.
;
; CONTENTS DO NOT SURVIVE A POWER CYCLE.  They do survive a warm boot,
; since nothing in the warm-boot path writes to that range.

	; agonm$init0
	;	First-time initialisation.  Nothing to do -- the RAM is
	;	simply there.
	;
	;	This deliberately does NOT clear the drive.  The kernel
	;	calls every drive's init entry from BOOT, and BOOT runs on
	;	a warm start as well as a cold one, so wiping here would
	;	destroy the contents every time a program exited.
	;
	;	The directory is filled with 0E5h once, by format_m in the
	;	supervisor, which runs only when MOS loads CPM3.BIN.  See
	;	the comment on that routine for why it is done there and
	;	not here.  A: has no equivalent because cpmtools writes an
	;	empty directory into the image when it is created.

agonm$init0:
	ret


	; agonm$login
	;	Called when the drive is logged in.  A RAM drive cannot
	;	have its medium changed, so this always succeeds.
	;
	;	Returns with <A> = 0 and Z set.

agonm$login:
	xra	a
	ret


	; agonm$read / agonm$write
	;	Transfer @cnt 128-byte records between the RAM drive and
	;	@dma in bank @dbnk.
	;
	;	The parameter block is the same shape as the one used for
	;	the SD-card drives, so the supervisor reads it the same
	;	way; only the gate differs.
	;
	;	Return <A> = 0 and Z set on success, <A> = 1 on a
	;	permanent error.  A permanent error here means the request
	;	fell outside the drive, which is a bug rather than a
	;	medium fault, so it is reported the same way.

agonm$read:
	mvi	a,0
	jmp	ram$io

agonm$write:
	mvi	a,1
	; fall through

ram$io:
	sta	m$dir
	lhld	@trk
	shld	mp$trk
	lhld	@sect
	shld	mp$sect
	lhld	@dma
	shld	mp$dma
	lda	@dbnk
	sta	mp$dbnk
	; One 128-byte record per call, for the reason given in disk$io
	; above.  Storing @cnt here was far more damaging than on A:: the
	; supervisor loads the byte count into BC and runs LDIR, and BC is
	; a 24-BIT register in ADL mode, so a count of zero does not copy
	; nothing -- it copies 16,777,216 bytes, straight through MOS's
	; data, heap and stack and on round the address space.  That is
	; the freeze seen on DIR M: and on switching to M:.
	mvi	a,1			; exactly one 128-byte record
	sta	mp$cnt

	lxi	h,mparm$blk
	lda	m$dir			; supervisor takes the direction in A
	GATE	g$mio
	ora	a
	rz
	; fall through

ram$error:
	push	psw
	call	?pderr
	lxi	h,merr$msg
	call	?pmsg
	pop	psw
	mvi	a,1			; permanent error
	ora	a
	ret

merr$msg:
	db	'RAM drive transfer out of range',0

; Parameter block for the RAM drive.  Byte-for-byte the same layout as
; parm$blk above -- the supervisor copies nine bytes either way -- but
; kept separate so a transfer on M: cannot disturb one in progress on
; a card drive.  Offset +0 is unused here and left zero.

mparm$blk:
mp$drive:	db	0	; +0 unused: no image file, no MOS handle
mp$trk:		ds	2	; +1 track
mp$sect:	ds	2	; +3 sector (128-byte record within track)
mp$dma:		ds	2	; +5 DMA address within the bank at +7
mp$dbnk:	ds	1	; +7 DMA bank
mp$cnt:		ds	1	; +8 record count, always 1 (see ram$io)

m$dir:		ds	1	; 0 = read, 1 = write


; =====================================================================
;  DRIVES SUPPLIED BY A LOADABLE DRIVER
; =====================================================================
;
; ONE SET OF STUBS SERVES EVERY FID DRIVE.  This is not an economy, it
; is forced.  An XDPH holds four SIXTEEN-BIT addresses, and the kernel
; reaches them with
;
;	lxi d,-8 ! dad d		; read
;	mov a,m ! inx h ! mov h,m ! mov l,a
;	pchl
;
; so whatever the XDPH names must be Z80 code in bank 0.  A driver's
; handlers are TWENTY-FOUR-BIT addresses in segment $04 and cannot go
; there at all.  So every FID drive's XDPH names these four routines,
; which gather the BDOS parameters and hand them to the supervisor
; along with the absolute drive number; the supervisor maps that drive
; to the right driver and calls it.
;
; This is exactly what ?ci, ?co, ?cist and ?cost in agonchr.asm do for
; character devices through g$fidcio, and deliberately so: one pattern
; to understand rather than two.
;
; THE ABSOLUTE DRIVE IS PASSED IN <B>, NOT IN THE PARAMETER BLOCK.
; The nine-byte block is the same shape g$dread and g$mio already use,
; and the supervisor copies nine bytes for all three, so adding a
; tenth field here would mean touching two working paths for the sake
; of one new one.  @adrv is a single byte and a register carries it
; perfectly well.
;
; bioskrnl.asm sets BOTH @adrv and @rdrv before every entry these
; stubs serve: seldsk stores @adrv then @rdrv before calling LOGIN,
; d$init$loop stores both before calling INIT, and rw$common stores
; @rdrv (@adrv having been set at select time) before jumping to READ
; or WRITE.  So both are valid in all four.

	; fid$read / fid$write
	;	Transfer one physical record for the FID drive currently
	;	selected.  <A> = 0 to read, 1 to write.
	;
	;	Returns <A> = 0 and Z set on success, <A> = 1 for a
	;	permanent error.

fid$read:
	mvi	a,0
	jmp	fid$io

fid$write:
	mvi	a,1
	; fall through

fid$io:
	sta	f$dir
	lda	@rdrv
	sta	fp$drive
	lhld	@trk
	shld	fp$trk
	lhld	@sect
	shld	fp$sect
	lhld	@dma
	shld	fp$dma
	lda	@dbnk
	sta	fp$dbnk
	; One record per call.  @cnt IS NOT A LENGTH -- see the long
	; note in disk$io above.  It is declared "db 0" in bioskrnl.asm
	; and the BDOS never calls MULTIO before directory I/O, so
	; storing it here would ask for a transfer of zero records.
	mvi	a,1
	sta	fp$cnt

	lda	@rdrv
	mov	c,a			; <C> = relative drive
	lda	@adrv
	mov	b,a			; <B> = absolute drive
	lxi	h,fparm$blk
	lda	f$dir			; supervisor takes the operation in A
	GATE	g$fiddio
	ora	a
	rz
	; fall through

fid$error:
	push	psw
	call	?pderr
	lxi	h,ferr$msg
	call	?pmsg
	pop	psw
	mvi	a,1			; permanent error
	ora	a
	ret

ferr$msg:
	db	'Driver drive transfer failed',0


	; fid$login
	;	Called when a FID drive is logged in.  Operation 2.

fid$login:
	lda	@rdrv
	mov	c,a
	lda	@adrv
	mov	b,a
	mvi	a,2
	GATE	g$fiddio
	ret


	; fid$init
	;	Called once per drive from the kernel's BOOT, on warm
	;	starts as well as cold ones.  Operation 3.
	;
	;	A DRIVER MUST NOT USE THIS TO FORMAT ITS MEDIUM, for the
	;	reason agonm$init0 gives above: BOOT runs every time a
	;	program exits, so anything written here is written again
	;	on every warm start.  One-time work belongs in the
	;	driver's load entry.

fid$init:
	lda	@rdrv
	mov	c,a
	lda	@adrv
	mov	b,a
	mvi	a,3
	GATE	g$fiddio
	ret


; Parameter block for FID drives.  Byte-for-byte the same layout as
; parm$blk and mparm$blk above -- the supervisor copies nine bytes for
; all three -- but kept separate so a transfer on a driver's drive
; cannot disturb one in progress on a card drive or on M:.

fparm$blk:
fp$drive:	ds	1	; +0 relative drive, as the driver asked for it
fp$trk:		ds	2	; +1 track
fp$sect:	ds	2	; +3 sector
fp$dma:		ds	2	; +5 DMA address within the bank at +7
fp$dbnk:	ds	1	; +7 DMA bank
fp$cnt:		ds	1	; +8 record count, always 1 (see fid$io)

f$dir:		ds	1	; 0 = read, 1 = write


; ---------------------------------------------------------------------
; fid$ddesc -- the disc half of the descriptor handed to the supervisor
; at ?init, pointed at by fid$desc in agonchr.asm.
;
; WHY TWO DESCRIPTORS.  The supervisor needs @ctbl and the character
; device counts, which are defined in agonchr.asm, AND @dtbl, the DPB
; pool, the drive-letter floor and the four stub addresses, which are
; defined here.  RMAC cannot import an equate from another module, so a
; single flat descriptor would mean duplicating NDPBSLOT and FIRSTAUTO
; as equates in agonchr.asm and keeping the copies in step by hand.
; Two descriptors, each assembled in the module that owns its numbers,
; with one pointer between them, has no such pair to drift apart.
;
; The layout is fixed and matches the comment on _g_fidinit in
; cpm3.asm; the two must be changed together, and the supervisor's
; copy length with them.
; ---------------------------------------------------------------------

fid$ddesc:
	dw	@dtbl			; +0  the drive table
	dw	dpb$pool		; +2  DPB slots, in common
	db	NDPBSLOT		; +4  how many there are
	db	FIRSTAUTO		; +5  lowest letter for automatic
					;     assignment; see the note by
					;     the constant above
	dw	fid$write		; +6  the shared stubs every FID
	dw	fid$read		; +8  drive's XDPH points at
	dw	fid$login		; +10
	dw	fid$init		; +12

end
