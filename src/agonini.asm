title 'Agon CP/M 3 BIOS: initialisation and CCP loading'

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
public	?init,?ldccp,?rlccp
public	agon$low$common,agon$len$common

extrn	?pmsg				; kernel message printer
extrn	@mxtpa				; SCB: top of the TPA
extrn	agon$setcommon			; declares the mutable region
extrn	agon$newdrv			; installs run-time drives
extrn	agonm$dpb			; M: geometry, for its size
extrn	agon$fidinit			; loads the field installable drivers
extrn	@civec,@covec,@aivec,@aovec,@lovec

maclib	agon


cseg	; ?ldccp and ?rlccp are reached from the kernel's BOOT and
		; WBOOT, both of which run in common memory.


; THE MUTABLE COMMON REGION
; -------------------------
; Every byte of common memory that CHANGES while CP/M runs has
; to be copied from one segment to the other on every ?bank.
; Everything else -- all the common CODE -- is placed identically
; in both segments by the loader and never needs touching.
;
; The mutable bytes are:
;
;   RESBDOS3   res$fx, hash$tbla, bank, aret,           324 bytes
;              commonfcb, common$dma, the 60-byte
;              local stack, and entsp.  One contiguous
;              run at the end of the module, verified
;              against resbdos.asm.
	;   SCB page   the System Control Block proper plus      256 bytes
	;              olog/rlog.  Part of this page is static
;              jump vectors, but it is not worth
;              splitting a single page.
;   Kernel     boot$stack (64) and @cbnk (1)              65 bytes
;   This BIOS  see agon$vars below
;
; The loader is responsible for placing those three blocks
; adjacently so that the whole mutable set is ONE contiguous run
; and ?bank is a single block copy.  If they end up scattered,
; ?bank needs one copy per fragment and the cost rises in
; proportion -- so the layout is a correctness-adjacent concern,
; not just tidiness.
;
; The two symbols below are filled in by the loader before the
; first bank switch, then handed to the supervisor by ?init.
; They are NOT assembly-time constants: the system generator
; decides the final addresses.
;
; NAMED agon$low$common / agon$len$common, not agon$common$low /
; agon$common$len: RMAC/LINK truncate external symbols to six
; significant characters (ignoring $), so agon$common$low and
; agon$common$len both truncated to AGONCO and LINK refused to
; combine this module with the rest of the BIOS.  Putting the
; distinguishing word first fixes it -- AGONLO vs AGONLE -- without
; changing what either symbol means.  If anything else in this
; source starts with agon$ and shares its first six significant
; characters with agon$setcommon, agon$dph0, or these two, it will
; fail the same way; this collision is a property of the two names
; chosen, not of $ specifically.

agon$low$common:
	dw	0			; first mutable byte, patched by loader
agon$len$common:
	dw	0			; length in bytes, patched by loader


; ?init
;	General initialisation and sign on.  Called once from the
;	kernel's BOOT, before any bank switch can happen.
;
;	IN THE BANKED SEGMENT, NOT COMMON.  BOOT is itself in the
;	kernel's DSEG and runs with bank 0 selected, so everything
;	?init needs can be banked -- which matters, because the
;	status line below carries a decimal conversion routine and
;	its buffers, and common memory is the one resource here
;	that is genuinely scarce.  ?ldccp and ?rlccp stay in
;	common: WBOOT calls them and WBOOT is common.

dseg

?init:
; Hand the mutable common extents to the supervisor FIRST.
; Until this call has been made a ?bank would copy nothing and
; the system would come apart on the first BDOS disk call, so
; nothing here may switch banks before it completes.
;
; Both words are still zero: nothing patches them, despite what
; the comment above them says, and g$setcom ignores a
; zero-length request outright.  The region that actually gets
; registered is the one the supervisor's loader declares for
; itself from bnk_top.  Left in place because it is the hook a
; narrower region would use.
	lhld	agon$low$common
	xchg				; DE = start
	lhld	agon$len$common
	xchg				; HL = start, DE = length
	call	agon$setcommon

; Default I/O redirection: console in and out on device 0 (VDP),
; auxiliary and list likewise, so that a system generated without
; a DEVICE command still talks to the screen.
;
; THE BIT ORDER IS REVERSED FROM THE OBVIOUS ONE.  System Guide
; 3.4.2: "bit 15 corresponds to device zero, and bit 4 is device
; eleven.  Bits 0 through 3 are reserved for future system use."
; The kernel agrees -- out$scan, ist$scan and in$scan in
; bioskrnl.asm all start at device 0 and shift LEFT with DAD H,
; so the first bit tested is bit 15.
;
; 0001h therefore selects device 15, which does not exist.  With
; that value ?co discards every character through the co$uart stub
; (invisible signon) and, worse, in$scan spins forever because
; cist$uart never reports ready -- a silent permanent hang with no
; crash.  That was the boot symptom.
	lxi	h,8000h			; bit 15 = device 0, the VDP
	shld	@civec
	shld	@covec
	shld	@aivec
	shld	@aovec
	shld	@lovec

	lxi	h,signon
	call	?pmsg

; Install any drive the system generator does not know about.
; This must happen HERE, inside ?init, and not earlier or later:
; the kernel's BOOT walks @dtbl immediately after ?init returns
; and calls each drive's init entry, so a drive added now is
; initialised with the rest, while one added afterwards would
; never see its init call.
;
; It returns the number of hard drives present, which the status
; line reports, so the install has to come first.
	call	agon$newdrv
	sta	nhard

; ---------------------------------------------------------------
; Status line.  Every figure is derived at run time; the only
; constant is the version, and nothing here needs editing when the
; memory layout or a drive geometry changes.
; ---------------------------------------------------------------

	lxi	h,vermsg
	call	?pmsg

; --- TPA in K ---
;
; @MXTPA is the top of the transient program area: the address
; in the JMP at 0005h, which is what every program reads to find
; out how much memory it has.  The TPA starts at 0100h, so the
; size is @MXTPA - 0100h bytes.
;
; Dividing that by 1024 needs only the high byte.  Writing the
; high byte as H and the low as L, the size is (H-1)*256 + L, and
; L cannot carry the sum across a multiple of 1024 because L is
; always below 256 while the step is 1024.  So (H-1)/4 is exact
; rather than approximate, and costs two shifts instead of a
; 16-bit divide.
;
; THIS REPORTS 61K, AND 61K IS RIGHT.  Earlier notes in this
; project put the figure at 60.25K by taking COMBAS (F200h) as
; the ceiling, and a draft of this comment went further and
; called GENCPM's own "61K TPA" the odd one out.  Both were
; wrong.  COMBAS is where common memory is allowed to begin, not
; where it does: GENCPM placed RESBDOS3 at F500h, so F200h-F4FFh
; holds nothing.  In bank 1 that gap is ordinary free memory
; below the BDOS entry, and the supervisor's mutable-common copy
; carries it across bank switches in both directions, so a
; program may use it.  Measured on the generated system:
; @MXTPA = F506h, giving 62,470 bytes, which is 61.0K.  GENCPM
; and the SCB agree; only the old note disagreed.
	lda	@mxtpa+1	; high byte of the TPA top
	dcr	a			; less the 0100h base page
	ora	a			; clear carry so RAR shifts in a zero
	rar
	ora	a
	rar				; A = TPA in K
	mov	l,a
	mvi	h,0
	call	decout
	lxi	h,tpamsg
	call	?pmsg

	; --- hard drives, including the boot drive ---
	lda	nhard
	mov	l,a
	mvi	h,0
	call	decout
	lda	nhard
	cpi	1
	lxi	h,drvmsg1		; "hard drive" for exactly one
	jz	init$drvmsg
	lxi	h,drvmsgn		; "hard drives" otherwise

init$drvmsg:
	call	?pmsg

	; --- size of M: in K ---
	;
	; Taken from M:'s own DPB rather than from any constant, so it
	; follows the drive if the geometry ever changes:
	;
	;   capacity = (DSM + 1) blocks * 128 * 2^BSH bytes
	;   in K     = (DSM + 1) * 2^BSH / 8
	;            = (DSM + 1) shifted left by BSH - 3
	;
	; BSH is at DPB offset 2 and DSM at offset 5.  BSH is 3 or more
	; for every block size CP/M 3 supports -- 1024 bytes upwards --
	; so the shift count cannot go negative.
	lhld	agonm$dpb+5		; DSM, highest block number
	inx	h			; number of blocks
	lda	agonm$dpb+2		; BSH
	sui	3
	jz	init$msize
	mov	b,a

init$mshift:
	dad	h
	dcr	b
	jnz	init$mshift

init$msize:
	call	decout
	lxi	h,rammsg
	call	?pmsg

	; Field installable drivers, last of all.  They are loaded AFTER the
	; status line so that each driver's own sign-on follows the system's,
	; and after agon$newdrv so that a driver sees the finished drive map.
	; Still inside ?init, so a driver that adds a drive would have its
	; init entry called by the kernel's loop like any other.
	call	agon$fidinit
	ret


	; decout
	;	Print <HL> in decimal, no leading zeros.
	;
	;	Repeated subtraction against a table of powers of ten:
	;	no division, and the 8080 has no 16-bit subtract, so each
	;	step is done as SUB then SBB with the borrow deciding
	;	when to stop.
	;
	;	The digits are assembled into a buffer and printed with
	;	one ?pmsg call rather than a character at a time, because
	;	the kernel exports ?pmsg but no single-character entry.
	;
	;	A value of zero prints as "0": the leading-zero
	;	suppression would otherwise emit nothing at all.

decout:
	shld	dec$val
	lxi	h,dec$buf
	shld	dec$ptr
	lxi	h,dectab
	shld	dec$pos
	xra	a
	sta	dec$flag

dec$place:
	lhld	dec$pos
	mov	e,m			; DE = this power of ten
	inx	h
	mov	d,m
	inx	h
	shld	dec$pos

	lhld	dec$val
	mvi	a,'0'
	sta	dec$digit

dec$sub:
	mov	a,l			; HL - DE, low half
	sub	e
	mov	c,a
	mov	a,h			; and high half, with borrow
	sbb	d
	jc	dec$done		; borrowed: the power no longer fits
	mov	h,a
	mov	l,c
	lda	dec$digit
	inr	a
	sta	dec$digit
	jmp	dec$sub

dec$done:
	shld	dec$val			; remainder carries to the next place

	lda	dec$digit
	cpi	'0'
	jnz	dec$emit		; a significant digit
	lda	dec$flag
	ora	a
	jz	dec$next		; still leading, suppress it
	lda	dec$digit

dec$emit:
	lhld	dec$ptr
	mov	m,a
	inx	h
	shld	dec$ptr
	mvi	a,1
	sta	dec$flag

dec$next:
	lhld	dec$pos
	lxi	d,dectab$end
	mov	a,l
	cmp	e
	jnz	dec$place
	mov	a,h
	cmp	d
	jnz	dec$place

	lda	dec$flag		; nothing emitted: the value was zero
	ora	a
	jnz	dec$term
	lhld	dec$ptr
	mvi	m,'0'
	inx	h
	shld	dec$ptr

dec$term:
	lhld	dec$ptr
	mvi	m,0
	lxi	h,dec$buf
	call	?pmsg
	ret

dectab:
	dw	10000
	dw	1000
	dw	100
	dw	10
	dw	1
	
dectab$end:

dec$val:	ds	2		; value still to be converted
dec$ptr:	ds	2		; next free byte of dec$buf
dec$pos:	ds	2		; position in dectab.  NAMED dec$pos, NOT
				; dec$tab: RMAC ignores '$' entirely, so
				; dec$tab and dectab are ONE symbol and the
				; assembler reported a phase error on the
				; table rather than a duplicate definition.
				; Same trap as agon$common$low in this BIOS,
				; and it will catch anything else whose name
				; collides once the dollars are removed.
dec$flag:	ds	1		; non-zero once a digit has been emitted
dec$digit:	ds	1
dec$buf:	ds	6		; five digits and a terminator

nhard:		ds	1		; hard drives present, boot drive included


	; THE VERSION NUMBER LIVES HERE, and nowhere else on the CP/M
	; side.  The supervisor prints its own banner from cpm3.asm
	; before CP/M starts; that one is a MOS-level loader message and
	; is deliberately separate, since the two are built by different
	; toolchains and cannot share an include file.

signon:
	; NO LEADING CRLF.  Entering terminal mode clears the screen and
	; leaves the cursor at the top left, so anything emitted here
	; before the text pushes it down a row for nothing.  The two
	; trailing CRLFs are kept: they are what separates this line from
	; the status line below it.
	db	'CP/M Plus for Agon Light',13,10
	db	'(c) 2026 Nick J. Date',13,10,13,10,0

vermsg:
	db	'v 1.0, ',0

tpamsg:
	db	'K TPA, ',0

drvmsg1:
	db	' hard drive, ',0

drvmsgn:
	db	' hard drives, ',0

rammsg:
	db	'K drive M:',13,10,0

	cseg	; ?ldccp and ?rlccp are reached from the kernel's WBOOT,
		; which runs in common memory.

	; ?ldccp
	;	Load the CCP into the TPA at 0100h for the first time.
	;	Under CP/M 3 the CCP is an ordinary transient rather than a
	;	resident part of the system, which is why the TPA figure is
	;	not reduced by its size.  It is read from the SD card by the
	;	supervisor through MOS, NOT from a CP/M drive, so moving the
	;	boot drive to C: does not affect it.

?ldccp:
	GATE	g$ldccp
	ret

	; ?rlccp
	;	Reload the CCP for a warm boot.
	;
	;	A system with memory to spare is expected to keep a copy
	;	of the CCP somewhere and restore it rather than re-reading
	;	the file.  With four spare 64K segments this machine has
	;	room for that several times over, and it would make warm
	;	boots essentially instant.  Not yet done: for now this
	;	simply re-reads the file, which is correct but slower.

?rlccp:
	GATE	g$ldccp
	ret

	end
