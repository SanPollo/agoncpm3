title 'Agon CP/M 3 BIOS: bank switching, memory move, clock'

; =============================================================================
;  CP/M-80 Version 3  --  Modular BIOS  --  Agon Light
; =============================================================================
;
; (c) 2026 Nick J. Date. Released under the MIT Licence. See the accompanying
; LICENSE file for details.
;
;
; This module supplies the four kernel externals that have no
; portable implementation: ?bank, ?move, ?xmove and ?time.
;
; WHY THIS IS THE INTERESTING MODULE
; ----------------------------------
; On a conventional banked CP/M 3 machine the memory banks overlap in
; a region of "common" memory which is physically the same RAM in
; every bank, so ?bank is a single port write and costs nothing.
;
; The eZ80 cannot do that.  Its only banking mechanism is the MBASE
; register, which supplies A23-A16 for every Z80-mode access, so the
; banks are whole 64K segments and cannot overlap.  Common memory
; therefore exists as two physical copies, one per segment, and the
; parts of it that CHANGE have to be copied across on every switch.
;
; Static common code needs no copying: the loader places identical
; copies in both segments and they stay identical.  Only the mutable
; region moves.  Measured on hardware at 5-6 MB/s, a 650-byte mutable
; region costs 110-130 us per switch.
;
; The switch itself is performed by the ADL-mode supervisor, because
; UM0077 states MBASE can only be written in ADL mode.

public	?bank,?move,?xmove,?time
public	agon$setcommon

extrn	@cbnk		; kernel's record of the current bank
extrn	@date,@hour,@min,@sec	; SCB clock fields, written by ?time

maclib	agon


cseg; ALL of this module is common: ?bank must survive the
	; switch it performs, and ?move/?xmove are called by the
	; resident BDOS from common memory.


; ?bank
;	Select bank <A> for processor operations.
;	Called by the kernel's bnksel, and by the resident BDOS
;	via the BIOS ?bnksl entry, on every BDOS call that needs
;	the banked BDOS (functions 0, 1, 2, 11 and 12 upwards).
;
;	The gate below does four things, in this order:
;	  1. maps the CP/M bank number to an MBASE segment
;	  2. returns at once if that segment is already selected
;	  3. copies the mutable common region from the current
;	     segment to the target segment
;	  4. sets MBASE and returns
;
;	Step 3 must precede step 4, and it must include the stack
;	in use at this moment, because the RET below pops its
;	return address from the Z80-mode stack -- which after the
;	switch is the target segment's copy.  The resident BDOS
;	calls us on its own stack in common memory (resbdos.asm
;	does "lxi sp,lstack" before dispatching), so copying the
;	mutable common region copies that stack with it.
;
;	Registers other than A are preserved by the supervisor.

?bank:
	GATE	g$bank		; execution resumes in the new segment
	ret



; ?move
;	Block move: <HL> = destination, <DE> = source,
;	<BC> = count.  On return <HL> and <DE> must point one
;	past the last byte moved, which is what the eZ80's LDIR
;	leaves behind anyway.
;
;	If ?xmove has set up a cross-bank transfer, the supervisor
;	uses the recorded banks and clears them afterwards; a
;	plain ?move with no preceding ?xmove stays within the
;	current segment.  Either way this runs as a 24-bit LDIR in
;	ADL mode, which UM0077 gives as 2 bus cycles per byte --
;	the cheapest form available, since the suffixed LDIR.S and
;	LDIR.L variants both cost 3.

?move:
	GATE	g$move
	ret


; ?xmove
;	Set the banks for the NEXT ?move only.
;	<B> = destination bank, <C> = source bank.
;
;	The BDOS uses this to move data between the TPA bank and
;	its buffers in bank 0 without a processor bank switch.  On
;	this machine that is a straight 24-bit copy between two
;	segments and needs no switching at all, which is why it is
;	cheap here even though the processor switch is not.

?xmove:
	GATE	g$xmove
	ret


; ?time
;	BIOS function 26.  <C> = 0 to read the clock, 0FFh to set
;	it.  System Guide 3.4.5: "Upon exit, you must restore
;	register pairs HL and DE to their entry values."
;
;	The supervisor does the work -- it brackets the VDP's
;	terminal mode, reads the clock packet and converts it --
;	and hands back five ready-to-store bytes.  All this module
;	does is put them in the SCB.
;
;	THE STORES BELOW MUST STAY AS THEY ARE.  System Guide 3.1:
;
;	  "Do not perform assembly-time arithmetic on any
;	   references to the external labels of the SCB.  The
;	   result of the arithmetic could alter the page value to
;	   something other than 0FEH."
;
;	scb.asm defines these as absolute external equates on page
;	0FEh, and it is that page value that GENCPM's relocator
;	recognises and rewrites to the real SCB address.  Arithmetic
;	in the operand can carry the low byte and change the page,
;	after which the reference is silently no longer an SCB
;	reference at all.  @date is therefore stored with a single
;	SHLD on the symbol itself and NEVER as a pair of STA
;	instructions on @date and @date+1; each of the other three
;	has its own symbol and needs no arithmetic either.
;
;	On failure the SCB is left exactly as it was, so a clock
;	that cannot be read shows as unset rather than as wrong.
;
;	NOTE: the Agon's clock is maintained by the VDP and is not
;	battery backed, so unless the user sets it the date will
;	restart from the same value at every power on.  That is a
;	property of the machine, not of this code.

?time:
	push	h			; 3.4.5 requires both restored
	push	d
	mov	a,c
	ora	a
	jnz	time$set

; <C> = 0 -- the BDOS is about to read the SCB, so put the current
; time into it.  The supervisor returns non-zero if it has no clock
; to report, in which case the SCB is left exactly as it was: an
; unreadable clock then shows as unset rather than as some
; arbitrary date.

	lxi	h,time$buf
	GATE	g$time			; <C> passes straight through
	ora	a
	jnz	time$exit

	lhld	time$buf
	shld	@date
	lda	time$buf+2
	sta	@hour
	lda	time$buf+3
	sta	@min
	lda	time$buf+4
	sta	@sec
	jmp	time$exit

; <C> = 0FFh -- the BDOS has just written the SCB (function 104,
; SET DATE AND TIME, which also zeroes the seconds field) and this
; is the BIOS being told to update its clock.  Hand the four fields
; over and the supervisor restarts its count from them.
;
; <C> survives to the GATE below: LHLD, SHLD, LDA and STA touch
; neither B nor C, so the register pair needs no saving.

time$set:
	lhld	@date
	shld	time$buf
	lda	@hour
	sta	time$buf+2
	lda	@min
	sta	time$buf+3
	lda	@sec
	sta	time$buf+4
	lxi	h,time$buf
	GATE	g$time

time$exit:
	pop	d
	pop	h
	ret

; Five bytes: @date low, @date high, then hour, minute and second
; in BCD.  time$buf is a local label, so the arithmetic in the
; LDA operands above is ordinary and carries none of the hazard
; described for the SCB externals.
time$buf:
	ds	5


; agon$setcommon
;	Called once from ?init, before any bank switch can occur.
;	Tells the supervisor which bytes of common memory are
;	mutable and therefore have to be copied on each ?bank.
;
;	<HL> = first mutable byte, <DE> = length in bytes.
;
;	The extents cannot be resolved at assembly time: they
;	depend on where the system generator places RESBDOS, the
;	SCB page and this BIOS's own common data.  They are passed
;	in at run time instead so that there is exactly one place
;	where the layout is stated.

agon$setcommon:
	GATE	g$setcom
	ret

end
