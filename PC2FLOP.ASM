;******************************************************************************
;
;  PC2Flop - Transfer disk image from PC to floppy over serial port.
;		(for JADE Double D disk controller)
;
;	This program writes a SSSD soft-sectored 8" floppy with a disk image
;	transmitted from a PC. The image is transmitted through a 2SIO at I/O
;	address 010h or 12h, or an SIO at address 0 using the XMODEM protocol.
;
;	The program talks directly to the Jade Double D controller and does not
;	require CP/M or an OS to function. The only requirement is that DCM
;	must be running on the DD. The JDDUTIL utility can be used for this
;	purpose.
;
;	Since this is a soft sectored controller, the destination disk must
;	have been formatted at some point.
;
;	This program works best if console port and the transfer port
;	are not the same device. Otherwise, most error messages won't
;	be seen as the file transfer dialog box prevents their display.
;
;	The program runs standalone at 0x100 or under CP/M. The program
;	is exited with a CTRL-C and either warm boots CP/M or just starts
;       over when running stand alone.
;
;	Written by Mike Douglas
;	Modified for JADE Double D by Patrick Linstruth
;
;	Rev	 Date	    Desc
;	1.0	 05/23/20   Original
;
;*****************************************************************************

; Disk information equates

NUMTRK	equ	77		;number of tracks
NUMSEC	equ	26		;number of sectors per track
NUMSEC1	equ	50		;number of sectors per track
XTRASEC	equ	(NUMSEC1-NUMSEC);extra sectors to read on first pass
SECLEN	equ	128		;sector length (as transmitted)
MINDRV	equ	0		;first drive number
MAXDRV	equ	3		;max drive number 

TRKLEN	equ	(NUMSEC*SECLEN)	;length of track in bytes
TRKLEN1	equ	(NUMSEC1*SECLEN);length of track in bytes
XTRALEN	equ	(XTRASEC*SECLEN);extra length of track 1
RDTRIES	equ	5		;number of read (verify) attempts
WRTRIES	equ	4		;number of write attempts

; Monitor, CP/M boot entry points

MONITOR	set	init		;no monitor, just start over
CPMBOOT	set	0		;CP/M warm boot jump vector

; XMODEM equates

PKTLEN	equ	128		;128 byte xmodem packet length
SOH	equ	001h
EOT	equ	004h
ACK	equ	006h
NAK	equ	015h
CAN	equ	018h
EOF	equ	01ah		;ctrl-z character

; CP/M Equates

WBOOT	equ	0		;warm boot jump location

; Misc equates

CR	equ	13		;ascii for carriage return
LF	equ	10		;ascii for line feed
DEL	equ	7fh		;ascii DEL
BS	equ	08h		;ascii backspace
CTRLC	equ	03		;ascii for control-c
JMPINST	equ	0c3h		;jump instruction opcode

	org	0100h	
;-----------------------------------------------------------------------------
;  Initialize for transfer
;-----------------------------------------------------------------------------
init	lxi	sp,ourStk	;initialize stack pointer
	call	chkCpm		;set flag for CP/M or not
	call	sizeRam		;determine amount of RAM available
	call	s2Init		;initialize the 88-2SIO ports
	mvi	a,MINDRV	;a=default drive
	sta	drvNum		;need for pgmExit

;  Display welcome message, then get the drive number and port number
;    to use for the transfer from the operator.

	lxi	h,mWelcom	;display welcome message
	call	dispMsg

; getDrv - get drive number or letter from the user.

getDrv	lxi	h,mDrive	;display drive number prompt
	call	dispMsg
	call	rcvCon		;get byte from the console
	ori	20h		;upper case letters to lower case
	cpi	'x'		;exit requested?
	jz	pgmExit		;yes

	lxi	h,baseDrv	;ascii 1st drive - baseDrv = 0
	sub	m
	cpi	MAXDRV-MINDRV+1	;validate >=min drive and <= max drive
	jnc	getDrv		;invalid, prompt again

	adi	MINDRV		;restore offset of 1st drive (if any)
	sta	drvNum		;save the drive number to use

; Check if DCM is running and drive status

	call	INI$DD
	jz	dcmRdy		;DCM found and running
	call	DCM$ER		;display DCM error
	jmp	getDrv

dcmRdy:	call	dChkWP		;check write protect (aborts to getDrv)

; getVrfy - Ask to verify sectors

getVrfy	lxi	h,mVerify	;display verify prompt
	call	dispMsg
	call	rcvCon		;get byte from console
	ori	20h
	cpi	'n'
	mvi	b,0		;set b to 0
	jz	getPort		;do not verify
	cpi	'y'
	jnz	getVrfy		;invalid response - try again
	mvi	b,1

setVrfy	mov	a,b
	sta	vfyFlag		;a to vfyFlag

; getPort - get serial port number from the user.

getPort	lxi	h,mPort		;display transfer port prompt
	call	dispMsg
	call	rcvCon		;get byte from the console
	ori	20h		;upper to lower case, nums not affected
	cpi	'x'		;exit requested?
	jz	pgmExit		;yes

	sui	'1'		;'1' - '3' to bianry 0-2
	cpi	3		;validate ascii 1-3
	jnc	getPort		;invalid, prompt again

	sta	xfrPort		;save the port to use

; Prompt the user to insert the disk to write, initialize, then start
;   sending NAK to start the XMODEM reception.

	lxi	h,mStart	;display start file transfer prompt
	call	dispMsg

	xra	a		;init track we're reading to zero
	sta	trkNum

	inr	a		;init xmodem block number to one
	sta	blkNum

	lxi	h,trkBuf	;trkBuf is initial starting point for
	shld	rcvPtr		;   XMODEM receive

	mvi	a,NAK		;send starting nak after purging input data
	call	purgSio

;-----------------------------------------------------------------------------
;  mainLp - Receive as many packets as will fit into RAM and then write
;      tracks to disk. Repeat until entire disk is written. 
;-----------------------------------------------------------------------------
mainLp	call	bufPkts		;buffer as many packets as possible
	xchg			;de=start of last packet received
	lxi	h,trkBuf	;hl=start of track buffer
	shld	trkPtr		;writing will start from here
	call	cmpDeHl		;compare last packet start - trkBuf
	jc	allDone		;nothing received but an EOT

; trkLoop - write tracks until all disk tracks have been written or all
;    the tracks in the buffer have been written.
	
trkLoop	call	wrtTrk		;write a track (hl returns->next track)

	lda	trkNum		;increment track number (preserve HL)
	inr	a
	sta	trkNum	
	cpi	NUMTRK		;done all tracks?
	jz	allDone		;yes

	xchg			;de=next track pointer
	lhld	rcvPtr		;hl=start of last packet received
	call	cmpHlDe		;compare rcvPtr-start of next track
	jnc	trkLoop		;another track is present

; All the buffered tracks have been written. Move any bytes left over
;    from the xmodem receive to the start of trkbuf. Adjust rcvPtr
;    to the end of that data which is where reception of the next
;    packet will begin.

	call	subHlDe		;hl=hl-de = left over byte count - PKTLEN
	mov	a,l		;a=left over count - PKTLEN
	adi	PKTLEN		;a=left over byte count
	mov	b,a		;b=left over byte count (bytes to move)
	lxi	h,trkBuf	;hl->start of trkBuf
	jz	mvDone		;no bytes to move, we're done
	
; Copy the leftover data to the start of trkBuf. The next XMODEM receive
;   sequence will start at the end of this copied data instead of at the
;   start of trkBuf.

moveLp	ldax	d		;move from end of trkBuf to start of trkBuf
	mov	m,a
	inx	h		;hl->starting bytes of trackbuf
	inx	d		;de->unwritten bytes from end of trkBuf		
	dcr	b
	jnz	moveLp

mvDone	shld	rcvPtr		;save address where to receive next packet

	xchg			;save rcvPtr in de

	lhld	bufEndS		;now that we've written the buffer containing
	shld	bufEnd		;extra track 1 sectors, set bufEnd for 26 sectors

	xchg			;rcvPtr in hl

	mvi	a,ACK		;ACK the last packet or EOT
	call	sndByte

	jmp	mainLp		;go receive more packets

; allDone - The disk is completely written. ACK the final packet (or EOT),
;     display the "transfer complete" message and start the program over.

allDone	mvi	a,ACK		;ACK the final packet or EOT
	call	sndByte

	call	dRestor

	lxi	h,mDone		;hl->done message
	call	dispMsg
	jmp	getDrv		;start over asking for drive num

;-----------------------------------------------------------------------------
; bufPkts - Receive XMODEM packets until we fill all the track buffer
;   space available. Reception starts at the address pointed to by
;   rcvPtr. Reception is stopped when the last packet exactly
;   fills or "crosses" the end of the last track spot in RAM. rcvPtr is
;   updated on exit to point to the start of the last packet received.
;   The disk write routines use this pointer to know where data ends and
;   then update rcvPtr to start to where to begin receiving new packets.
;-----------------------------------------------------------------------------
bufPkts	call	rcvPkt		;receive a packet
	xchg			;de=current xmodem receive pointer
	cpi	EOT		;EOT received?
	jz	bufDone		;yes, buffering is done

	lhld	bufEnd		;hl=end of buffering space	
	call	cmpDeHl		;compare current-end	
	jnc	bufDone		;past or at end, buffering is done

	mvi	a,ACK		;otherwise, ACK the packet
	call	sndByte
	xchg			;put xmodem rcv pointer back in HL
	jmp	bufPkts		;buffer some more

; bufDone - no more room for packets. Update rcvPtr to point to the 
;   start of the last packet received so the disk write routines know
;   where data ends.

bufDone	xchg			;hl=current xmodem receive pointer
	lxi	d,-PKTLEN
	dad	d		;hl=hl-PKTLEN = start of last rcv'd packet
	shld	rcvPtr		;save use by write tracks
	ret

;-----------------------------------------------------------------------------
; rcvPkt - receive an xmodem format 128 byte packet. HL points to the 128 byte
;    buffer to receive. HL is updated by 128 bytes after each succuessful
;    reception of a new 128 byte packet.
;-----------------------------------------------------------------------------
nakPkt	pop	h		;get HL back
	mvi	a,NAK
	call	purgSio		;purge receive for 1s then transmit NAK

;wait for SOH, CAN, or EOT

rcvPkt	push	h		;save HL for retries
waitSoh	call	chkQuit		;check for user abort
	mvi	a,3		;3 second timeout for soh
	call	rcvByte		;receive character with timeout
	jz	nakPkt		;timeout

	cpi	SOH		;SOH received?
	jz	haveSoh

	cpi	CAN		;CAN received?
	jnz	chkEoh		;restart

	lxi	h,mCancel
	call	dispMsg
	jmp	restart

chkEoh	cpi	EOT		;EOT to say we're done?
	jnz	waitSoh		;no, keep looking for SOH

	pop	h		;undo the entry push
	ret			;return with EOT

;  Have SOH, receive block number and not block number

haveSoh	mvi	a,1		;one second timeout once inside a packet
	call	rcvByte		;get the block number
	jz	nakPkt		;timeout, NAK and start over

	sta	rcvBlk		;save the received block number
	mvi	a,1		;one second timeout
	call	rcvByte		;get not block number
	jz	nakPkt		;timeout, NAK and start over

	sta	rcvNBlk		;save not block number

;  Receive the 128 byte block

	mvi	e,0		;init checksum
	mvi	d,pktLen	;d is byte counter
pktLoop	mvi	a,1		;one second timeout
	call	rcvByte		;get next data byte
	jz	nakPkt		;timeout

	mov	m,a		;store the character
	inx	h		;point to next byte
	add	e		;update the checksum
	mov	e,a
	dcr	d		;decrement bytes remaining
	jnz	pktLoop

;  Verify the checksum

	mvi	a,1		;one second timeout
	call	rcvByte		;get the checksum
	jz	nakPkt		;timeout

	cmp	e		;checksum match?
	jnz	nakPkt		;no, packet error

;  Checksum good. Verify block numbers

	lda	rcvNBlk		;verify rcvBlk = not (rcvNBlk)
	cma			;A should = block number now
	mov	b,a		;save in b
	lda	rcvBlk
	cmp	b		;compare rcvBlk = not(rcvNBlk)?
	jnz	nakPkt		;no, error

	lda	blkNum		;compare rcvBlk = expected blkNum
	cmp	b
	jnz	nakPkt		;nak if not the same (also nak's re-send)

	inr	a		;increment expected block number
	sta	blkNum
	pop	b		;get HL off stack, but don't clobber HL
	xra	a		;return a zero
	ret

;-----------------------------------------------------------------------------
; wrtTrk - write and verify NUMSEC sectors to the current track in trkBuf
;   as pointed to by trkPtr. After the track is written, trkPtr is updated
;   by the length of a track to point to the next track buffer. This
;   saved value is also returned in HL.
;-----------------------------------------------------------------------------
wrtTrk	lxi	h,trkNum	;get desired track from trkNum	
	mov	l,m		;and put into l
	call	dSeek		;seek to the track

	mvi	a,WRTRIES	;init write retry counter
	sta	wrRetry

noWrap	mvi	e,0		;reset sector

; rtryWrt - write a track and the retry entry point.

rtryWrt	lda	numSecs
	mov	d,a		;d=count of sectors to write
	
; wrtLoop - write a full track starting after the sector in e.

wrtLoop	call	dNxtSec		;get next sector number and offset
	lhld	trkPtr		;hl->start of current track buffer
	dad	b		;bc has offset of sector within track
	call	dWrite		;write the sector
	jnz	wrtErr		;write failed

	dcr	d		;decrement sector count
	jnz	wrtLoop		;loop until all sectors written

	lda	vfyFlag		;verify track?
	ora	a
	jz	noVfy

; Verify the track just written

	lda	numSecs
	mov	d,a		;d=count of sectors to verify
	mvi	e,0		;reset sector

vfyLoop	call	chkQuit		;check for ctrl-c
	call	dNxtSec		;get next sector number and offset
	lhld	trkPtr		;hl->start of current track buffer
	dad	b		;bc has offset of sector within track
	call	dVerify		;verify the sector
	jnz	vfyRtry		;error, go to retry logic

vfyNext	dcr	d		;decrement sector count
	jnz	vfyLoop		;loop until all sectors verified

; Track verified, increment trkPtr to memory location for next track
;    and exit.

noVfy	lhld	trkPtr		;hl=current track pointer
	lxi	d,TRKLEN1	;de=bytes in a track 1
	lda	trkNum		;track 1?
	cpi	1
	jz	trk1

	lxi	d,TRKLEN	;de=bytes in a track 0,2-76
trk1	dad	d		;hl=start of next track in trkBuf
	shld	trkPtr
	ret

; vfyRtry - verify failed, retry reads followed by a re-write
;   of the track in needed.

vfyRtry	mvi	a,RDTRIES	;init retry counter
	sta	rdRetry

retryLp	call	chkQuit		;check for ctrl-c
	call	dWtSec		;wait for sector specified in e
	lhld	trkPtr		;hl->start of current track buffer
	dad	b		;bc has offset of sector within track
	call	dVerify		;verify the sector
	jz	vfyNext		;success, go verify next sector

; Re-verify failed. Decrement retry count and try again if not zero. Once
;   retry counter expires, do another write.

	lxi	h,rdRetry	;decrement the read retry counter
	dcr	m
	jnz	retryLp		;try again

; read re-tries expired, decrement the write retry count and re-write
;    if not expired

	lxi	h,wrRetry	;decrement the write retry counter
	dcr	m
	jnz	rtryWrt		;retry starting with the write

	jmp	vfyErr		;display the error and restart

;-----------------------------------------------------------------------------
; Disk write verify failure. Display the track and sector with the error. 
;    Restart the program.
;-----------------------------------------------------------------------------
wrtErr	ani	ST$RNF		;sector not found error?
	jz	vfyErr		;no

	lxi	h,mNoSec	;'sector not found, format needed?'
	call	dispMsg

vfyErr	lxi	h,errTrk	;hl->where to put ascii decimal
	lda	trkNum		;a=track with error on it
	call	bin2dec		;track to ascii

	lxi	h,errSec	;hl->where to put ascii sector
	mov	a,e		;a=sector where error occured
	call	bin2dec

	lxi	h,mDskErr	;display the error message
	call	dispMsg
	lxi	sp,ourStk	;initialize stack pointer
	jmp	getDrv		;start over asking for drive num

;-----------------------------------------------------------------------------
; dispMsg - display the null-terminated message passed in hl on the
;    console device. Clobbers b, hl
;-----------------------------------------------------------------------------
dispMsg	mov	a,m		;get the next message byte
	ora	a		;null terminates
	rz

	mov	b,a		;conOut wants character in b
	call	conOut
	inx	h		;move to next byte
	jmp	dispMsg

;-----------------------------------------------------------------------------
; rcvCon - Receive a character from the console device, echo it, then
;   wait for a CR. Exits program if Ctrl-c typed. Returns with invalid
;   character (null) if BS or DEL pressed after 1st character
;   Returns character in a, clobbers b.
;-----------------------------------------------------------------------------
rcvCon	call	conIn		;check for input
	jz	rcvCon		;nothing

	ani	7fh
	cpi	CTRLC		;abort requested?
	jz	pgmExit		;yes

	cpi	CR		;return pressed?
	rz			;yes, don't echo it

	mov	b,a		;conOut needs character in b
	call	conOut		;echo it

; Wait for CR, then return 1st character typed

rcvCr	call	conIn		;check for input
	jz	rcvCr		;nothing

	ani	7fh
	cpi	CTRLC		;abort requested?
	jz	pgmExit		;yes

	cpi	DEL		;delete
	rz			;yes, return DEL character

	cpi	BS		;backspace?
	rz			;yes, return BS character

	cpi	CR		;return pressed?
	jnz	rcvCr		;no, keep waiting

	mov	a,b		;return 1st character typed
	ret

;-----------------------------------------------------------------------------
; purgSio - wait for 1 second of idle time on receive line, then transmit the
;	character passed in A (usually ACK or NAK). Clobbers b
;-----------------------------------------------------------------------------
purgSio	push	a

purge	mvi	a,1		;1 second timeout
	call	rcvByte		;wait for 1 second without activity
	jnz	purge

	pop	a		;get back the character to send
				;fall through to sndByte
;-----------------------------------------------------------------------------
; sndByte - send the byte in a through the specified transfer port. 
;     Clobbers b. (assuming serOut clobbers only a).
;-----------------------------------------------------------------------------
sndByte	mov	b,a		;b=byte to transmit
	lda	xfrPort		;a=port to use for transfer
	jmp	serOut		;send the character

;-----------------------------------------------------------------------------
; rcvByte - Receive a byte from the specified transfer port. A wait timeout
;     in seconds is specified in a. If a timeout occurs, zero is returned in
;     a and the zero flag is true. Otherwise, the character is returned in a 
;     (could be zero) and the zero flag is false. ONESEC must be set based
;     on processor speed and the number of cycles in the serIn call + 59.
;     Clobbers a, b and c.
;-----------------------------------------------------------------------------
rcvByte	push	d		;save d, e
	mov	d,a		;save timeout in d

initSec	lxi	b,ONESEC	;one second timeout 104 cycles per loop

rcvWait	lda	xfrPort		;(13) a=port to use for transfer
	call	serIn		;(17+45) look for a byte
	jnz	haveChr		;(10) byte received

	dcx	b		;(5) otherwise, decrement timer
	mov	a,b		;(5) one second expire?
	ora	c		;(4)
	jnz	rcvWait		;(10) no, keep waiting

; one second timeout has occured. Decrement the seconds counter.

	dcr	d		;decrement seconds counter
	jnz	initSec		;initialize for another 1 second count
haveChr	pop	d		;restore d, e
	ret

;--------------------------------------------------------------
; bin2dec - Binary byte in A to 2 ASCII digits at (HL)
;   HL is preserved
;--------------------------------------------------------------
bin2dec	mvi	m,' '		;assume zero supression
	sui	10		;value less than 10?
	jc	do1s		;yes, leading blank
	mvi	m,'1'		;have one ten already

loop10	sui	10		;count 10s
	jc	do1s		;done with 10s, do 1s
	inr	m
	jmp	loop10

do1s	adi	'0'+10		;form ASCII 1s digit
	inx	h		;move to 1s position
	mov	m,a
	dcx	h		;restore hl
	ret

;--------------------------------------------------------------
; chkQuit - check for the user to request abort (ctrl-c). If
;    a character is present on the console port, read it and
;    see if ctrl-c. Clobbers A
;--------------------------------------------------------------
chkQuit	call	conIn		;check for console input
	rz

	ani	7fh
	cpi	CTRLC		;abort requested?
	rnz			;no

; Ctrl-C typed while program is running. Return to drive prompt.

restart	lxi	sp,ourStk	;initialize stack pointer
	jmp	getDrv		;start over asking for drive num

;--------------------------------------------------------------
; pgmExit - Exit to CP/M or to the monitor ROM based on the
;    CP/M flag
;--------------------------------------------------------------
pgmExit	lda	cpmFlag		;running under CP/M?
	ora	a
	jnz	cpmExit		;yes

; Exit to ROM monitor

	lxi	h,mExit		;display "exiting" message
	call	dispMsg
	jmp	MONITOR		;jump to ROM monitor entry point

; CP/M exit. If boot drive was used, prompt user to insert CP/M disk

cpmExit	lda	drvNum		;boot drive used?
	sui	MINDRV
	jnz	noDisk		;not 1, disk prompt not needed

	lxi	h,mCpm		;display "insert cp/m disk"	
	call	dispMsg
	call	rcvCon		;wait for a character

noDisk	mvi	a,MINDRV	;re-select drive A for CP/M 1.4
	sta	drvNum
	call	dSelDrv

	lxi	h,mExit		;display "exiting" message
	call	dispMsg
	jmp	CPMBOOT		;reboot CP/M

;--------------------------------------------------------------
; chkCpm - check if running under CP/M. CP/M flag is set true
;   (non-zero) if yes, cleared otherwise.
;--------------------------------------------------------------
; First, initialize entries for stand-alone

chkCpm	xra	a
	sta	cpmFlag		;clear CP/M flag
	mvi	a,MINDRV+'0'	;ascii for minimum drive number
	sta	mDrvMin		;store in the drive prompt message
	sta	baseDrv		;ascii 1st drive - baseDrv = 0
	mvi	a,MAXDRV+'0'	;ascii for max drive number
	sta	mDrvMax

; Determine if we're under CP/M or standalone. CP/M is assumed if
;   a jump instruction is present at the CP/M warm start location (0)
;   and five more jumps (e.g., a jump table) is present at the
;   jump-to destination.
		
	lda	WBOOT		;see if jump instruction present for CP/M
	cpi	JMPINST
	rnz			;no, not CP/M

; A jump instruction is present at the CP/M warm boot location (0),
;   now see if that jump points to five more jumps. If so, assume CP/M

	lxi	h,WBOOT+1	;point to lsb of jump address
	mov	e,m		;e=low byte of jump
	inx	h
	mov	d,m		;de=destination of jump
	mvi	b,5		;look for 5 more jumps (a jump table)

jmpTest	ldax	d		;a=opcode at jump destination
	sui	JMPINST		;another jump present?
	rnz			;no, not CP/M

	inx	d		;move to next jump
	inx	d
	inx	d
	dcr	b
	jnz	jmpTest

	dcr	a		;a=0ffh
	sta	cpmFlag		;CP/M flag to non-zero = true

; We're running under CP/M. Change drive prompt message to show drive
;    letters instead of drive numbers and change baseDrv to convert
;    an 'A' to the base drive number (MINDRV).

	mvi	a,'A'		;'A' in drive message instead of number
	sta	mDrvMin
	adi	MAXDRV-MINDRV	;max drive letter
	sta	mDrvMax
	mvi	a,'a'		;ascii 1st drive - baseDrv = 0
	sta	baseDrv
	ret

;------------------------------------------------------------------
; sizeRam - determine how much RAM we have for buffering tracks.
;   Sets the bufEnd variable which points to end address of 
;   the last possible track buffer + 1
;------------------------------------------------------------------
; If running under CP/M, use the BIOS pointer to determine the top
;    of available RAM. Otherwise, size RAM manually.

sizeRam	lhld	WBOOT+1		;get address of BIOS jump table+3
	dcx	h		
	dcx	h
	dcx	h		;hl->top of usable ram+1
	lda	cpmFlag		;running under CP/M?
	ora	a
	jnz	ramEnd		;yes, we have the end of RAM

;  Not under CP/M. Find the end of RAM manually.

	lxi	h,(trkBuf+0ffh) AND 0ff00h   ;next 256 byte boundary

ramLoop	mov	a,m		;a=current RAM content
	inr	m		;change RAM
	cmp	m		;did RAM change?
	mov	m,a		;restore RAM
	jz	ramEnd		;end of RAM found

	inr	h		;next page
	jnz	ramLoop

; ramEnd - end of RAM found. Subtrack 256 bytes from this to make room
;   for xmodem packet overflow at the end. Determine the end address + 1
;   of the last track buffer that will fit in RAM. Store in bufEnd

ramEnd	xchg			;de=end of RAM + 1
	mvi	a,-((TRKLEN SHR 8) + 1) AND 0ffh
	cmp	d		;force de < (10000h - TRKLEN)
	jnc	topOk

	mov	d,a		;limit max address

topOk	dcr	d		;subtract 256 bytes from end of RAM
	lxi	h,trkBuf	;hl=start of track buffer
	lxi	b,TRKLEN	;bc=length of track in bytes

; Loop increasing hl by TRKLEN until hl > end of RAM.

bfEndLp	dad	b		;hl=hl+track length
	call	cmpHlDe		;compare hl-de
	jc	bfEndLp		;still more room, keep going

; Subtrack two track lengths from hl, this will be the end address + 1 of
;   the the last track buffer that will fit in RAM

	lxi	b,-TRKLEN*2	;subtract two track lengths
	dad	b		;hl = end address of last track + 1
	shld	bufEndS		;save non-track 1 bufEnd
	lxi	b,XTRALEN
	dad	b		;hl += extra length for track 1
	shld	bufEnd		;save as bufEnd
	ret

;--------------------------------------------------------------------
; cmHlDe - compare HL-DE. Carry set if HL<DE, carry clear if HL>=DE
;--------------------------------------------------------------------
cmpHlDe	mov	a,l		;compare HL-DE, do lsbs first
	sub	e
	mov	a,h		;do msbs
	sbb	d
	ret			;carry set HL<DE, clear HL>=DE

;--------------------------------------------------------------------
; cmDeHl - compare DE-HL. Carry set if DE<HL, carry clear if DE>=HL
;--------------------------------------------------------------------
cmpDeHl	mov	a,e		;compare DE-HL, do lsbs first
	sub	l
	mov	a,d		;do msbs
	sbb	h
	ret			;carry set DE<HL, clear DE>=HL

;--------------------------------------------------------------------
; subHlDe - HL=HL-DE
;--------------------------------------------------------------------
subHlDe	mov	a,l		;subtract HL-DE, do lsbs first
	sub	e
	mov	l,a		;lsb result in l
	mov	a,h		;do msbs
	sbb	d
	mov	h,a		;msb result in h	
	ret

;-----------------------------------------------------------------------------
;   Data Area
;-----------------------------------------------------------------------------
mWelcom	db	cr,lf,lf
	db 	'===== PC to Floppy Disk Image Transfer =====',cr,lf
	db	'          (JADE Double D, ver 1.0)',cr,lf,lf
	db	'Writes a SSSD 8" floppy with a disk image received via an'
	db	cr,lf
	db	'88-2SIO or 88-SIO serial port using the XMODEM protocol.',0

mDrive	db	cr,lf,lf,'Insert and specify destination drive ('
mDrvMin	db	'x-'
mDrvMax	db	'x) or X to exit: ',0

mVerify	db	cr,lf,'Verify sectors written to disk? ', 0

mPort	db	cr,lf,lf
	db	'Specify the port to use for file transfer',cr,lf
	db	'  1) 88-2SIO port A (which is also the console)',cr,lf
	db	'  2) 88-2SIO port B',cr,lf
	db	'  3) 88-SIO',cr,lf
	db	'Enter 1-3 or X to exit: ',0

mStart	db	cr,lf,lf
	db	'Start XMODEM send now...',0

mCancel	db	cr,lf,lf,'Received CAN from sender.',cr,lf,0

mDone	db	cr,lf,lf,'Creation of new disk successful!',cr,lf,0

mNoTrk0	db	cr,lf,lf,'Seek to track 0 failed',cr,lf,0

mNoSec	db	cr,lf,lf,'Sector not found - disk not formatted?',0

mDskErr	db	cr,lf,lf,'Write failure on track '
errTrk	db	'xx, sector '
errSec	db	'xx. Disk creation aborted.',cr,lf,0

mWrtPrt	db	cr,lf,lf,'Disk is write protected',cr,lf,0

mExit	db	cr,lf,lf,'Exiting...',cr,lf,0

mCpm	db	cr,lf,lf
	db	'Insert CP/M disk into drive A, then press Return...',0

mDDTO	db	cr,lf,lf,'DCM command timeout. Is DCM running?',cr,lf,0

mDNR	db	cr,lf,lf,'Drive Not Ready',cr,lf,0

;****************************************************************************
;
;  Hardware specific console and serial I/O routines. 
;     The following four routines must be written to provide a common
;     interface to the hardware on which this program is running. The
;     port number specified for serIn and serOut matches the port number
;     input from the operator via the port menu.
;
;****************************************************************************

; 88-2SIO Serial Board Equates

s2aCtl	equ	010h		;1st port on 88-2SIO board - control register
s2aDat	equ	011h		;1st port on 88-2SIO board - data register
s2bCtl	equ	012h		;2nd port on 88-2SIO board - control register
s2bDat	equ	013h		;2nd port on 88-2SIO board - data register
s2Rdrf	equ	001h		;read data register full flag
s2Tdre	equ	002h		;transmit data register empty flag
s2Rst	equ	003h		;reset command
s28n1	equ	015h		;8N1 selection
s28n2	equ	011h		;8N2 selection

; 88-SIO Serial board Equates

sioCtl	equ	00h		;control port
sioDat	equ	01h		;data port
sioRdrf	equ	00000001b	;-RX Data register full
sioTdre	equ	10000000b	;-TX Data register empty

; The rcvByte subroutine above times a one second timeout with a code
;    loop that calls the hardware specific serIn routine below. ONESEC
;    must be set based on processor speed and the number of cycles in 
;    the serIn call + 59 cycles for the rcvByte code. 

ONESEC	equ	19231		;rcvByte loop count for 1 second

;----------------------------------------------------------------------------
; s2Init - reset and initialize 88-2SIO ports for 8N1
;----------------------------------------------------------------------------
s2Init	mvi	a,s2Rst		;reset and init 2nd 88-2SIO port
	out	s2bCtl
	mvi	a,s28n1		;transfer port as 8N1
	out	s2bCtl

; if not running under CP/M, reset and init 1st 88-2SIO port

	lda	cpmFlag		;running under CP/M?
	ora	a
	rnz			;yes, 2SIO already initialized

	mvi	a,s2Rst		;reset and init 1st 88-2SIO port
	out	s2aCtl
	mvi	a,s28n2		;configure console for 8N2 in case Teletype
	out	s2aCtl
	ret	

;----------------------------------------------------------------------------
; conIn - input character from console
;    inputs:
;    outputs: z true if no character present
;	      z false if character returned in a
;    clobbers none
;----------------------------------------------------------------------------
conIn	in	s2aCtl		;see if a new character is present
	ani	s2Rdrf
	rz			;no character, return zero status

	in	s2aDat		;return character and non-zero status
	ret	

;----------------------------------------------------------------------------
; conOut - output character to console
;    inputs: b = character to send
;    clobbers none
;----------------------------------------------------------------------------
conOut	in	s2aCtl		;wait for OK to transmit
	ani	s2Tdre
	jz	conOut
	mov	a,b		;a=character to transmit
	out	s2aDat		;send it
	ret

;----------------------------------------------------------------------------
; Hardware specific I/O
; serIn - input character from port specified in a
;       0 = 88-2SIO port A
;       1 = 88-2SIO port B
;       2 = 88-SIO
;    inputs: a = port to read from
;    outputs: z true if no character present
;	      z false if character returned in a
;    clobbers none
; 88-2SIO Port A: 53 cycles including return when no character present
; 88-2SIO Port B: 43 cycles including return when no character present
; 88-SIO: 57 cycles including return when no character present
;-----------------------------------------------------------------------------
serIn	dcr	a		;(5)3-way test
	jz	s2InB		;(10)a was 1: 88-2SIO port B
	jp	sioIn		;(10)a was 2: 88-SIO
				;    a was 0: 88-2SIO port A
; Input from 88-2SIO port A

s2InA	in	s2aCtl		;(10+1)see if a new character is present
	ani	s2Rdrf		;(7)
	rz			;(10)no character, return zero status
	in	s2aDat		;return character and non-zero status
	ret	
	
; Input from 88-2SIO port B

s2InB	in	s2bCtl		;(10+1)see if a new character is present
	ani	s2Rdrf		;(7)
	rz			;(10)no character, return zero status

	in	s2bDat		;return character and non-zero status
	ret	

; Input from 88-SIO

sioIn	in	sioCtl		;(10+1)see if a new character is present
	cma			;(4)invert Rx Data Ready flag
	ani	sioRdrf		;(7)
	rz			;(10)no character, return zero status

	in	sioDat		;return character and non-zero status
	ret	

;-----------------------------------------------------------------------------
; Hardware specific I/O
; serOut - output character to port specified in a
;       0 = 88-2SIO port A
;       1 = 88-2SIO port B
;       2 = 88-SIO
;    inputs: a = port to transmit through
;	     b = character to send
;    clobbers a
;-----------------------------------------------------------------------------
serOut	dcr	a		;3-way test
	jz	s2OutB		;a was 1: 88-2SIO port B
	jp	sioOut		;a was 2: 88-SIO
				;a was 0: 88-2SIO port A

; Send character through 88-2SIO port A

S2OutA	in	s2aCtl		;wait for OK to transmit
	ani	s2Tdre
	jz	S2OutA

	mov	a,b		;a=character to transmit
	out	s2aDat		;send it
	ret

; Send character through 88-2SIO port B

s2OutB	in	s2bCtl		;wait for OK to transmit
	ani	s2Tdre
	jz	s2OutB

	mov	a,b		;a=character to transmit
	out	s2bDat		;send it
	ret

; Send character through 88-SIO

sioOut	in	sioCtl		;wait for OK to transmit
	ani	sioTdre
	jnz	sioOut		;active-low flag

	mov	a,b		;a=character to transmit
	out	sioDat		;send it
	ret

;--------------------------------------------------------------
; dRead - Read sector on current track.
; On Entry:
;    Drive is selected, on proper track, head loaded
;    hl->sector buffer
;    e = sector number to read
; On Exit:
;    Z flag set = good, Z flag clear = error
;    clobbers h,l
;--------------------------------------------------------------
dRead:	push	d		;save d
	mov	a,e		;set sector
	call	SETSEC
	mvi	a,DCM$RDS	;dcm read sector
	call	DSK$EX		;execute on dd
	jnz	dRdone		;exit if error

	push	h		;save dest buffer
	lxi	b,DD$BFL	;number of bytes to move
	lhld	D$ADDR		;dd memory address
	lxi	d,DD$BUF	;sector buffer offset
	dad	d		;hl now pts sector buf
	pop	d		;restore dest buffer
	call	BLK$MV		;perform block move

dRdone	pop	d		;restore d
	xra	a		;clear error
	ret			;error return

;--------------------------------------------------------------
; dVerify - Verify sector on current track. The track is
;    read to verify CRC, but not compared
; On Entry:
;    Drive is selected, on proper track, head loaded
;    e = sector number to verify
; On Exit:
;    Z flag set = good, Z flag clear = error
;    clobbers none
;--------------------------------------------------------------
dVerify	lxi	h,secBuf	;hl=sector buffer, e=sector
	jmp	dRead		;read sector


;--------------------------------------------------------------
; dWrite - Write a sector on current track
; On Entry:
;    Drive is selected, on proper track, head loaded
;    hl->buffer address
;    e = sector number to write
; On Exit:
;    Z flag set = good, Z flag clear = error
;   clobbers h,l
;--------------------------------------------------------------
dWrite:	push	d		;save d
	mov	a,e
	call	SETSEC
	push	h		;save source buffer
	lxi	b,DD$BFL	;number of bytes to move
	lhld	D$ADDR		;DD memory address
	lxi	d,DD$BUF	;sector buffer offset
	dad	d		;hl now pts cmnd blk
	xchg
	pop	h		;restore source buffer
	call	BLK$MV		;perform block move
	
;*******( PERFORM WRITE SECTOR )***********************

	mvi	a,DCM$WRS	;DCM write sector
	call	DSK$EX		;execute
	pop	d		;restore d
	ret			;return A if error
	
;--------------------------------------------------------------
; dChkWP - check if disk is write protected. 
; On Entry:
;    disk already selected
; On Exit:
;    returns if disk is not protected. Otherwise, an error
;    message is displayed and the program started over.
; Clobbers none
;--------------------------------------------------------------
dChkWP	call	GET$CB		;copy control block from DD
	lda	DCM$STS		;get status byte
	ani	ST$WRP		;get write protect bit alone
	rz			;return if not protected

; Disk write protected. Display error and restart program.

	lxi	h,mWrtPrt	;otherwise, display error message
	jmp	errMsg		;display error and restart

;--------------------------------------------------------------
; dSeek - Seek track specified in L. Selects drive and loads
;    head. If the head was not already loaded, then the E bit
;    (wait for head settle one-shot) is set in fWaitHd for
;    OR'ing into the subsequent read/write command.
; On Entry:
;    l = desired track
; On Exit:
;    Z flag set = good, Z flag clear = error
; Clobbers none
;--------------------------------------------------------------
dSeek	push	a
	mov	a,l		;set track number
	call	SETTRK
	pop	a
	ret			;Jade DD will seek on write


;--------------------------------------------------------------
; dRestor - Selects drive, loads heads and restores to track 0.
;    If restore fails, message display and program restarted
;    at getDrv.
; On Entry:
;    drvNum = drive to be selected and restored to track zero
; On Exit:
;    drive selected and on track zero
; Clobbers a
;--------------------------------------------------------------
dRestor	call	dSelDrv		;make sure drive is selected

	xra	a
	sta	DCM$TRK
	inr	a
	sta	DCM$SEC
	mvi	a,DCM$LOG	;logon command seeks to track 0
	call	DSK$EX		;Z clear and error in A
	rz			;success

; restore failed

	lxi	h,mNoTrk0

errMsg	call	dispMsg
	lxi	sp,ourStk	;initialize stack pointer
	jmp	getDrv		;start over asking for drive num

;--------------------------------------------------------------
; dSelDrv - Select and wait for drive specified in drvNum 
;    to be ready.
; On Entry:
;    drvNum = drive to be selected
; On Exit:
;    drive selected and ready, 1771 not busy
; Clobbers a
;--------------------------------------------------------------
dSelDrv	lda	drvNum		;a=desired drive
	call	SETDRV
	ret

;--------------------------------------------------------------
; dNxtSec - wait for next (any) sector. For the 1771, this
;    routine simply increments and wraps the sector number
;    passed in e, then falls into dWtSec to return bc with
;    the offset of the sector within the track buffer.
; On Entry:
;    Drive is selected, motor is running
;    e = most recent sector number
; On Exit:
;    e = next sector sector number
;    bc = byte offset of this sector in a track
;--------------------------------------------------------------
dNxtSec	inr	e		;move to next sector
	inr	e		;skew of 2

	lda	numSecs
	mov	b,a
	inr	b
	mov	a,e		;see if past end
	cmp	b		;verify between 1 and 26/50
	jc	dWtSec		;good sector, compute bc

dSec1	mvi	e,1		;restart at sector 1
				;fall into dWtSec

;--------------------------------------------------------------
; dWtSec - wait for sector specified in e. For the DD
;    controller, this routine simply returns the offset
;    of the sector within this track in bc.
; On Entry:
;    Drive is selected, motor is running
;    e = desired sector number (must be 1-50 for DD)
; On Exit:
;    e = sector number
;    bc = byte offset of this sector in a track
;--------------------------------------------------------------
dWtSec	mov	a,e		;save the computed sector

; compute bc=128*(sector-1)

	sui	1		;zero index and clear carry
	rar
	mov	b,a		;b=sector >> 1

	rar			;put lsbit into msbit	
	ani	80h
	mov	c,a		;bc=128*e
	ret


;**************************************************************************
; 
;  Data area
;
;**************************************************************************
; Disk variables

drvNum	ds	1		;drive number to use
trkNum	ds	1		;track number to read
numSecs	ds	1		;number of sectors in track
fWaitHd	ds	1		;E bit (wait head settle) flag
trkPtr	ds	2		;pointer into trkBuf (start of next track)
bufEnd	ds	2		;end address + 1 of last track spot in RAM
bufEndS	ds	2		;saved buf end for non-track 1 buffer
secBuf	ds	SECLEN		;sector buffer to reads

; Retry logic variables

rdRetry	ds	1		;disk read retry counter
wrRetry	ds	1		;disk write retry counter

; Xmodem variables

xfrPort	ds	1		;pseudo port for file transfer
blkNum	ds	1		;current xmodem block number
rcvBlk	ds	1		;block number received
rcvNBlk	ds	1		;"not" block number received
rcvPtr	ds	2		;pointer for start of XMODEM send

; Misc variables

cpmFlag	ds	1		;non-zero if running under CP/M
vfyFlag	ds	1		;verify flag
baseDrv	ds	1		;ascii 1st drive - baseDrv = 0
	ds	96		;stack space
ourStk	equ	$

;------------------------------------------------------------------------------
; PR$NIB - DISPLAY VALUE IN A AS A SINGLE DIGIT ASCII-HEXIDECIMAL VALUE.
;------------------------------------------------------------------------------
PR$NIB:	PUSH	PSW
	PUSH	B

	CPI	10		;GREATER THAN 9?
	JC	NIBOUT		;0-9
	ADI	007H

NIBOUT	ADI	'0'
	MOV	B,A
	CALL	conOut

	POP	B
	POP	PSW

	RET

;------------------------------------------------------------------------------
; PR$HEX - DISPLAY VALUE IN A AS A TWO DIGIT ASCII-HEXIDECIMAL VALUE.
; CLOBBERS A,B.
;------------------------------------------------------------------------------
PR$BYT	MOV	B,A		;STORE VALUE IN B
	ANI	0F0H		;HIGH NIBBLE
	RRC
	RRC
	RRC
	RRC
	CALL	PR$NIB		;PRINT THE 16'S DIGIT

	MOV	A,B
	ANI	0FH
	JMP	PR$NIB		;PRINT THE 1'S DIGIT

;------------------------------------------------------------------------------
; PR$WRD - DISPLAY VALUE IN HL AS A FOUR DIGIT ASCII-HEXIDECIMAL VALUE.
; CLOBBERS NONE
;------------------------------------------------------------------------------
PR$WRD	PUSH	H		;SAVE HL
	PUSH	B		;SAVE BC
	PUSH	PSW		;SAVE AF
	MOV	A,H		;STORE MSB IN A
	CALL	PR$BYT		;PRINT MSB

	MOV	A,L		;STORE LSB IN A
	CALL	PR$BYT		;PRINT LSB
	POP	PSW
	POP	B
	POP	H
	RET

;******************************************************
;********                                     *********
;********  JADE DOUBLE D ROUTINES START HERE  *********
;********                                     *********
;******************************************************

;******************************************************
; SET DOUBLE D SYSTEM PORT ADDRESS		      *
;******************************************************

D$PORT	EQU	043H	;DOUBLE D PORT ADDRESS.

;*******( SET USER DOUBLE D BOARD REVISION )***********

TRUE	EQU	1	;SET TRUE TO LOGIC ONE.
FALSE	EQU	0	;SET FALSE TO LOGIC ZERO
REV$B	EQU	FALSE	;SET TRUE FOR REV B BOARDS.
REV$C	EQU	TRUE	;SET TRUE FOR REV C BOARDS.
MA10	EQU	FALSE	;TRUE IF MA10 JUMPED (REV-B).

;*******( DEFINE HALT MASK AND BASE ADDRESS)***********

	IF	REV$B
DS$HLT	EQU	002H	;STATUS PORT HALT INDICATOR.
DS$ASW	EQU	00CH	;STATUS PORT ADDR SW MASK.
D$BASE	EQU	0E400H	;SYSTEM WINDOW BASE ADDRESS
	ENDIF

	IF	MA10
D$BASE	EQU	0E000H	;SYSTEM WINDOW BASE ADDRESS
	ENDIF

	IF	REV$C
DS$HLT	EQU	001H	;STATUS PORT HALT INDICATOR.
DS$ASW	EQU	00EH	;STATUS PORT ADDR SW MASK.
D$BASE	EQU	0E000H	;SYSTEM WINDOW BASE ADDRESS
	ENDIF

;*******( BOOTSTRAP LINKAGE ADDRESS )******************

D$ADDR	EQU	0040H	;DOUBLE D ADDRESS POINTER.
D$MASK	EQU	0042H	;DOUBLE D HALT BIT ADDR.

;*******( DCM HARDWARE COMMANDS )**********************

DC$BGN	EQU	080H	;RESET Z80A AND EXECUTE.
DC$MRQ	EQU	001H	;REQUEST MEMORY WINDOW.
DC$MRT	EQU	000H	;RELEASE MEMORY WINDOW.
DC$MB0	EQU	001H	;SELECT MEMORY BANK 0.
DC$MB1	EQU	003H	;SELECT MEMORY BANK 1.
DC$EXC	EQU	002H	;ISSUE DOUBLE D INTERRUPT.

;*******( DCM MEMORY ADDRESSES DEFINED )***************

DD$CBT	EQU	0370H	;COMMAND BLOCK  (BANK 0).
DD$BUF	EQU	0380H	;SECTOR BUFFER  (BANK 0).
DD$BFL	EQU	128	;SECTOR BUFFER LENGTH.
DD$FBF	EQU	0300H	;FORMAT BUFFER	(BANK 1).
DD$FBL	EQU	0100H	;FORMAT BUFFER LENGTH.
DD$DPB	EQU	03A0H	;ID SEC DPB	(BANK 0).
DD$DDF	EQU	03B1H	;ID SEC FLAGS	(BANK 0).

;*******( DCM COMMANDS )*******************************

DCM$LOG	EQU	000H	;LOG ON DISKETTE.
DCM$RDS	EQU	001H	;READ SECTOR.
DCM$WRS	EQU	002H	;WRITE SECTOR.
DCM$FMT	EQU	003H	;FORMAT TRACK.
DCM$ADR	EQU	004H	;ADDRESS.
DCM$LST	EQU	005H	;LIST CHARACTER.
DCM$LCK	EQU	006H	;LIST STATUS.
DCM$IDL	EQU	007H	;IDLE.

;*******( STATUS BIT DEFINITIONS )*********************

ST$DNR	EQU	080H	;DRIVE NOT READY
ST$WRP	EQU	040H	;WRITE PROTECTED
ST$BT5	EQU	020H	;NOT ASSIGNED
ST$RNF	EQU	010H	;RECORD NOT FOUND
ST$CRC	EQU	008H	;CRC ERROR
ST$LDE	EQU	004H	;LOST DATA ERROR
ST$HME	EQU	002H	;DRIVE HOME ERROR
ST$TSD	EQU	001H	;TWO SIDES FLAG (FORMAT)
ST$NOE	EQU	000H	;NO ERROR

;******************************************************
; INIT DOUBLE D AND EXECUTE LOGON COMMAND	      *
;******************************************************

INI$DD:	IN	D$PORT		;INPUT STATUS PORT.
	ANI	DS$ASW		;MASK FOR ADDR SWS.
	RLC			;POSITION BITS.
	ORI     D$BASE SHR 8	;OR IN BASE ADDR.
	MOV	H,A		;HIGH BYTE VALUE.
	MVI	L,0		;LOW BYTE VALUE.
	SHLD    D$ADDR		;STORE THE ADDRESS

	MVI	A,DS$HLT	;LOAD HALT BIT MASK.
	STA	D$MASK		;STORE FOR BIOS USE.

	LDA	drvNum		;SET DRIVE NUMBER
	STA	DCM$DRV

	XRA	A		;SET TRACK NUMBER
	STA	DCM$TRK

	INR	A		;SET SECTOR NUMBER
	STA	DCM$SEC
	
	MOV	A,DCM$LOG	;TRY THE LOGON COMMAND
	CALL	DSK$EX		;Z CLEAR AND ERROR IN A

	RET

;******************************************************
; PUT DCM DISK BUFFER FROM SOURCE IN HL		      *
;******************************************************

PUT$DB:	MVI	A,DC$MB0	;REQUEST BANK 0
	OUT	D$PORT

	XCHG			;HL TO DE
	LXI	B,DD$BFL	;NMBR BYTE TO MOVE.
	LHLD	D$ADDR		;DD SYS ADDRESS.
	LXI	D,DD$CBT	;COMMAND BYTE OFFSET.
	DAD	D		;HL NOW PTS CMND BLK.
	XCHG			;HL=SRC DE=SEC BUF
	CALL	BLK$MV		;PERFORM BLOCK MOVE.
	RET

;******************************************************
; GET DCM DISK BUFFER AND STORE IN HL		      *
;******************************************************

GET$DB:	MVI	A,DC$MB0	;REQUEST BANK 0
	OUT	D$PORT

	XCHG			;HL TO DE
	LXI	B,DD$BFL	;NMBR BYTE TO MOVE.
	LHLD	D$ADDR		;DD SYS ADDRESS.
	LXI	D,DD$CBT	;COMMAND BYTE OFFSET.
	DAD	D		;HL NOW PTS CMND BLK.
	CALL	BLK$MV		;PERFORM BLOCK MOVE.
	RET

;******************************************************
; GET DCM CONTROL BLOCK  			      *
;******************************************************

GET$CB:	MVI	A,DC$MB0	;REQUEST BANK 0
	OUT	D$PORT

	LXI	B,8		;NMBR BYTE TO MOVE.
	LHLD	D$ADDR		;DD SYS ADDRESS.
	LXI	D,DD$CBT	;COMMAND BYTE OFFSET.
	DAD	D		;HL NOW PTS CMND BLK.
	LXI	D,DCM$CMD	;JDDUTIL CMND BLOCK.
	CALL	BLK$MV		;PERFORM BLOCK MOVE.
	RET

;******************************************************
; PUT DCM CONTROL BLOCK  			      *
;******************************************************

PUT$CB:	MVI	A,DC$MB0	;REQUEST BANK 0
	OUT	D$PORT

	LXI	B,7		;NMBR BYTE TO MOVE.
	LHLD	D$ADDR		;DD SYS ADDRESS.
	LXI	D,DD$CBT	;COMMAND BYTE OFFSET.
	DAD	D
	XCHG			;DE NOW PTS CMND BLK.
	LXI	H,DCM$CMD	;PC2FLOP CMND BLOCK.
	CALL	BLK$MV		;PERFORM BLOCK MOVE.
	RET

;******************************************************
; SET COMMAND     				      *
;******************************************************

SETCMD	STA	DCM$CMD		;SAVE DCM COMMAND.
	RET			;RETURN TO CALLER.

;******************************************************
; SET DRIVE NUMBER				      *
;******************************************************

SETDRV	STA	DCM$DRV		;SAVE DRIVE NUMBER.
	RET			;RETURN TO CALLER.

;******************************************************
; SET TRACK NUMBER				      *
;******************************************************

SETTRK	STA	DCM$TRK		;SAVE TRACK NUMBER.

	MVI	C,NUMSEC	;26 SECTORS PER TRACK
	CPI	1		;TRACK 1?
	JNZ	NTRK1		;NOT TRACK 1
	MVI	C,NUMSEC1	;50 SECTORS PER TRACK

NTRK1	MOV	A,C
	STA	numSecs
	RET			;RETURN TO CALLER.

;******************************************************
; SET SECTOR NUMBER				      *
;******************************************************

SETSEC:	STA	DCM$SEC		;SAVE SECTOR NUMBER.
	RET			;RETURN TO CALLER.

;******************************************************
; DOUBLE D EXECUTION SUBROUTINE			      *
;******************************************************

;*******( COMMAND BLOCK TO DOUBLE D AND EXEC )*********

DSK$EX	PUSH	H		;SAVE H
	STA	DCM$CMD		;STORE DCM COMMAND.
	CALL	PUT$CB

	MVI	A,DC$EXC	;LOAD DD INTERRUPT.
	OUT	D$PORT		;ISSUE DD INTERRUPT.

;*******( WAIT FOR DOUBLE D HALT )*********************

	LDA	D$MASK		;LOAD HALT BIT MASK.
	MOV	B,A		;MASK IN B REGISTER.
	LXI	D,0FFFFH	;LOOP COUNTER
WAIT	IN	D$PORT		;READ DD STATUS.
	ANA	B		;TEST HALT* FLAG.
	JZ	HALTED		;TEST UNTIL HALTED.
	DCX	D
	MOV	A,E
	ORA	D
	JNZ	WAIT

	LXI	H,mDDTO		;DISPLAY NO DD FOUND
	CALL	dispMsg
	MVI	A,ST$DNR	;SET DRIVE NOT READY
	ORA	A		;CLEAR ZERO FLAG
	JMP	EX$DONE

;*******( GET DOUBLE D STATUS )************************

HALTED	CALL	GET$CB
	LDA	DCM$STS
	ANA	A		;TEST FOR ERRORS.
EX$DONE	POP	H		;RESTORE H
	RET			;RETURN TO CALLER.

;******************************************************
; BLOCK MOVE SUBROUTINE (Z80 BLOCK MOVE REGISTERS)    *
;******************************************************

BLK$MV:	MOV	A,M		;GET BYTE.
	INX	H		;INC POINTER
	XCHG			;GET DESTINATION.
	MOV	M,A		;PUT BYTE.
	INX	H		;INC POINTER
	XCHG			;GET SOURCE.
	DCX	B		;ONE LESS TO DO.
	MOV	A,B		;GET HI COUNT.
	ORA	C		;GET LO COUNT.
	JNZ	BLK$MV		;FINISH LOADING.
	RET

;******************************************************
; DISPLAY DCM ERROR IN A 			      *
;******************************************************

DCM$ER	LXI	H,mDNR		;DRIVE NOT READY
	ANI	ST$DNR
	JNZ	dispMsg

	RET

;******************************************************
; DOUBLE D - DCM COMMAND BLOCK BUFFER		      *
;******************************************************

DCM$CMD DB	0		;DCM COMMAND.
DCM$DRV DB	0		;DRIVE NUMBER.
DCM$TRK DB	0		;TRACK NUMBER.
DCM$SEC DB	0		;SECTOR NUMBER.
DCM$SP0 DB	0		;SPARE BYTE 0.
DCM$CHR DB	0		;LIST CHARACTER.
DCM$MOD DB	00000000B	;MODE CONTROLS.
DCM$STS DB	0		;COMMAND STATUS.

;******************************************************
; TRACK BUFFER RUNS FROM HERE TO THE END OF MEMORY    *
;******************************************************

trkBuf	equ	$

	end


