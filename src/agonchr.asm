title 'Agon CP/M 3 BIOS: character I/O'

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
; Character devices.  Two are provided:
; 0  VDP   the Agon's own screen and keyboard, via MOS
; 1  UART  the serial port on the GPIO header
;
; The kernel handles all redirection through @civec/@covec, so these
; routines only ever deal with one physical device at a time, with
; the device number in <B>.

public	@ctbl
public	?ci,?co,?cist,?cost,?cinit
public	agon$fidinit		; loads the field installable drivers

extrn	fid$ddesc		; the disc half of the FID descriptor,
				; assembled in agondsk.asm

maclib	agon
maclib	modebaud		; mode bits and baud rate codes


cseg	; The resident BDOS calls console I/O through intercept
		; vectors in common memory without switching banks, so
		; these routines must be common too.  Keeping them here
		; is also what makes BDOS functions 3-10 free of any bank
		; switch at all.


; @ctbl -- physical character device table.
;
; ENTRIES ARE EIGHT BYTES, NOT TEN: six bytes of name padded
; with spaces, a mode byte, then a baud rate byte.  A zero byte
; terminates the table.
;
; This previously carried two trailing reserved bytes per entry,
; which is wrong twice over.  The sample CHARIO listing in the
; System Guide (Appendix I.2) uses eight, and more to the point
; the kernel hard-codes the stride: coster in bioskrnl.asm does
;
;	 mov l,b / mvi h,0
;	 dad h / dad h / dad h		(device number * 8)
;	 lxi d,@ctbl+6 / dad d		(-> mode byte)
;
; (slashes above stand for the exclamation-mark separator used in
; the kernel source.  RMAC ends a comment at that character and
; assembles whatever follows it,
; so quoting kernel lines verbatim inside a comment is unsafe.)
;
; so a ten-byte stride would have made every device above 0 read
; its mode byte out of the middle of another entry's name.  It
; caused no trouble yet only because device 0 is at offset zero
; either way.
;
; The mode bit VALUES were wrong too -- they had been written as
; 80h/40h/20h/10h/08h, whereas Table 4-7 gives input as 01h and
; output as 02h.  They now come from modebaud.lib.

@ctbl:
	db	'VDP   '		; device 0
	db	mb$in$out
	db	baud$none		; not a rate CP/M can select

	db	'UART  '		; device 1
	db	mb$in$out+mb$serial
	; MOS runs the GPIO serial port at 115200, which Table 4-8 has no
	; encoding for -- the table stops at 19200.  Claiming any of the
	; listed rates would be a lie that DEVICE would repeat, and the
	; soft-baud bit is deliberately NOT set because ?cinit cannot
	; change the rate anyway.  baud$none is the honest entry.
	db	baud$none

	db	0			; end of table


	; Room for devices added at run time by a loadable driver.
	;
	; The slots are left BLANK, not pre-named.  agon$fidinit passes the
	; table address and this count to the supervisor, which overwrites
	; the terminator above with a real entry and writes a fresh one
	; after it.  Pre-naming them would make DEVICE list phantom devices
	; on a system with no drivers loaded.

NBUILTIN equ	2			; VDP and UART
NFIDDEV	 equ	4			; must match MAXFIDDEV in cpm3.asm; the
					; supervisor takes the smaller of the two,
					; so a mismatch loses devices rather than
					; corrupting the table

	db	0,0,0,0,0,0,0,0		; slot 0
	db	0,0,0,0,0,0,0,0		; slot 1
	db	0,0,0,0,0,0,0,0		; slot 2
	db	0,0,0,0,0,0,0,0		; slot 3
	db	0			; terminator for the last slot


	; Descriptor handed to the supervisor.  Kept here rather than in
	; agonini.asm because @ctbl and the two counts are defined here and
	; RMAC cannot import an equate from another module.

fid$desc:
	dw	@ctbl			; +0  the table itself
	db	NBUILTIN		; +2  devices this BIOS provides
	db	NFIDDEV			; +3  spare slots reserved above
	dw	fid$ddesc		; +4  the disc half, in agondsk.asm.
					;
					; @dtbl, the DPB pool, the drive-letter
					; floor and the drive stubs all live in
					; agondsk.asm, and its NDPBSLOT and
					; FIRSTAUTO are equates that RMAC
					; cannot export.  Rather than duplicate
					; those constants here and rely on two
					; copies staying equal, the supervisor
					; is given a pointer and reads the
					; second descriptor itself.
					;
					; THE SUPERVISOR'S COPY LENGTH IN
					; _g_fidinit MUST MATCH THIS BLOCK'S
					; SIZE.  It is six bytes now, not four.


	; agon$fidinit
	;	Load and start the drivers named in FIDCONF.INI.  Called
	;	from ?init, and returns the number installed in <A>.

agon$fidinit:
	lxi	h,fid$desc
	GATE	g$fidinit
	ret


	; ?cinit
	;	(Re)initialise the physical device whose number is in <C>.
	;	Neither device needs setting up from here: the VDP is
	;	brought up by MOS before CP/M is loaded, and the serial
	;	port is configured by MOS from its own settings.  Changing
	;	the UART rate from inside CP/M would desynchronise MOS's
	;	own use of it, so this is deliberately a no-operation
	;	rather than an oversight.

?cinit:
	ret


	; ?ci -- read a character from device <B>, returned in <A>.
	;	Blocks until one is available.

?ci:
	mov	a,b
	cpi	NBUILTIN
	jnc	ci$fid
	ora	a
	jnz	ci$uart
	GATE	g$conin
	ret
ci$fid:
	xra	a			; operation 0 = input
	GATE	g$fidcio
	ret
ci$uart:
	; TODO: serial input is not yet wired up.  Returning ^Z rather
	; than blocking forever means a mis-set @civec shows up as an
	; immediate end of file instead of an apparent hang.
	mvi	a,1Ah
	ret


	; ?co -- send the character in <C> to device <B>.

?co:
	mov	a,b
	cpi	NBUILTIN
	jnc	co$fid
	ora	a
	jnz	co$uart
	GATE	g$conout
	ret
co$fid:
	mvi	a,1			; operation 1 = output
	GATE	g$fidcio
	ret
co$uart:
	; TODO: serial output is not yet wired up.  Discard rather than
	; fall through to the VDP, so that redirection failures are
	; visible instead of silently working.
	ret


	; ?cist -- input status of device <B>.
	;	<A> = 0FFh if a character is waiting, 0 if not.

?cist:
	mov	a,b
	cpi	NBUILTIN
	jnc	cist$fid
	ora	a
	jnz	cist$uart
	GATE	g$const
	ret
cist$fid:
	mvi	a,2			; operation 2 = input status
	GATE	g$fidcio
	ret
cist$uart:
	xra	a			; never ready
	ret


	; ?cost -- output status of device <B>.
	;	<A> = 0FFh if the device can accept a character.
	;	Both paths are effectively always ready: MOS buffers VDP
	;	output, and the discard stub above cannot block.

?cost:
	mov	a,b
	cpi	NBUILTIN
	jnc	cost$fid
	mvi	a,0FFh
	ret
cost$fid:
	mvi	a,3			; operation 3 = output status
	GATE	g$fidcio
	ret


end
