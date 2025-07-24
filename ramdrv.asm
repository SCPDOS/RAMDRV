; Join!

[map all ./lst/ramdrv.map]
[DEFAULT REL]

;A device driver for a RAM disk
;v1 creates a fixed 10Mb Ram Disk

BITS 64
%include "./inc/dosMacro.mac"
%include "./inc/dosError.inc"
%include "./inc/fatStruc.inc"
%include "./inc/drvStruc.inc"

;---------------------
; Static data tables :
;---------------------

header:
    dq -1
    dw 00840h
    dq strategy
    dq interrupt
    db 8 dup (0)

dispTbl:
    dw init - dispTbl
    dw medCheck - dispTbl
    dw buildBpb - dispTbl
    dw 0    ;ioctlRead
    dw read - dispTbl
    dw 0    ;ND read
    dw 0    ;input status
    dw 0    ;Flush input buffer
    dw write - dispTbl
    dw write - dispTbl  ;Write with verify, which is just write for us
    dw 0    ;Output status
    dw 0    ;Flush Output buffer
    dw 0    ;ioctlWrite
    dw open - dispTbl
    dw close - dispTbl
    dw remmed - dispTbl
    dw 0    ;Out until busy
    dw 0    ;Reserved (func 17)
    dw 0    ;Reserved (func 18)
    dw ioctl - dispTbl
    dw getDrvMap - dispTbl
    dw 0    ;Set Drive map (Does nothing as we have one unit)

ramBpb:
    istruc bpb              ;Fat 16 image
        at .bytsPerSec, dw 512   ;Bytes per sector
        at .secPerClus, db 2     ;Sectors per cluster (1Kb clusters)
        at .revdSecCnt, dw 1     ;Number of reserved sectors, in volume
        at .numFATs,    db 1     ;Number of FATs on media
        at .rootEntCnt, dw 512   ;512 entries in Root directory
        at .totSec16,   dw 4E7Fh ;Number of sectors on medium (~10Mb)
        at .media,      db 0FAh  ;Media descriptor byte
        at .FATsz16,    dw 40    ;Number of sectors per FAT
        at .secPerTrk,  dw 3Fh   ;Number of sectors per "track"
        at .numHeads,   dw 0FFh  ;Number of read "heads"
        at .hiddSec,    dd 0     ;Number of hidden sectors, preceeding volume start
        at .totSec32,   dd 0     ;32 bit count of sectors
    iend
;Reference BPB from dummy hard disk image. 
;Clearly a bug in FORMAT that always places total sector count in totSec32
;0200
;02
;0001
;02
;0200h
;0000
;F8
;0028
;003F
;00FF
;00000040
;00004E7F

;------------
; Variables :
;------------

bDrvInit    db 0        ;Set to -1 if we have been initialised.
pReqPkt     dq 0        ;Ptr to request packet
pAlloc      dq 0        ;Ptr to allocated ram for ramdisk
wOpenCnt    dw 0        ;Open counter
qMaxSector  dq 0        ;The maximum sector address
bUnitNumber db -1       ;DOS Unit number for this drive

;-------------------------
; Common error functions :
;-------------------------

errBadCmd:
;Called if the command code is bad or IOCTL command issued.
    mov word [rbx + ioctlReqPkt.status], drvErrStatus | drvBadCmd
    jmp short interrupt.exit

errBadReqLen:
;Jumped to if req packet length is bad on a request we handle.
;Only accessed from within a function, so returns.
    mov word [rbx + ioctlReqPkt.status], drvErrStatus | drvBadDrvReq
    return

;-------------------------------
; Strat and Interrupt routines :
;-------------------------------

strategy:
;Input: rbx -> Request packet to execute!
    mov qword [pReqPkt], rbx
    return

interrupt:
;All registers used must be preserved.
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov rbx, qword [pReqPkt]
    mov word [rbx + drvReqPkt.status], 0    ;Clear the status word
    movzx eax, byte [rbx + drvReqPkt.cmdcde]  ;Get the command code
    cmp eax, drvMAXCMD
    ja errBadCmd
    lea rsi, dispTbl
    lea rdi, word [rsi + 2*rax]   ;Point rdi to the entry
    movzx eax, word [rdi]   ;Read the word from the table
    test eax, eax           ;If the word is 0, we silently return ok!
    jz .exit            
    add rsi, rax            ;Add to rsi to get the pointer to the routine
    call rsi                ;Call the routine
.exit:
    or word [rbx + drvReqPkt.status], drvDonStatus  ;Set packet processed bit!
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    return
.checkUnit:
;Does nothing during device init. Else checks the unit requested is ours.
    cmp eax, drvINIT
    rete
    movzx eax, byte [rbx + drvReqPkt.unitnm]    ;Get unit requested on
    cmp byte [bUnitNumber], al
    rete
    pop rax ;Pop original return address off of stack
    mov word [rbx + ioctlReqPkt.status], drvErrStatus | drvBadUnit
    jmp short .exit

;----------------
; Main routines :
;----------------

medCheck:
;Returns media ok
    cmp byte [rbx + mediaCheckReqPkt.hdrlen], mediaCheckReqPkt_size
    jne errBadReqLen
    mov byte [rbx + mediaCheckReqPkt.medret], 1 ;Report no media change
    return

buildBpb:
;Always returns the BPB above
    cmp byte [rbx + bpbBuildReqPkt.hdrlen], bpbBuildReqPkt_size
    jne errBadReqLen
    lea rsi, ramBpb
    mov qword [rbx + bpbBuildReqPkt.bpbptr], rsi
    return

read:
    cmp byte [rbx + ioReqPkt.hdrlen], ioReqPkt_size
    jne errBadReqLen
    call write.checkRange   ;Check IO range ok.
    retc
;Here rax and rcx set with bytes for xfr
    mov rsi, qword [pAlloc]
    mov rdi, qword [rbx + ioReqPkt.bufptr]
    add rsi, rax
    rep movsb
    return
write:
    cmp byte [rbx + ioReqPkt.hdrlen], ioReqPkt_size
    jne errBadReqLen
    call .checkRange    ;Check IO range ok.
    retc
;Here rax and rcx set with bytes for xfr
    mov rsi, qword [rbx + ioReqPkt.bufptr]
    mov rdi, qword [pAlloc]
    add rdi, rax
    rep movsb
    return
.checkRange:
;Checks the range of the xfr is ok.
;Returns: CF=NC: Range ok. 
;           rax = Byte to start xfr on
;           rcx = Number of bytes to xft
;         CF=CY: Range not ok! Error bit and code set in status word
    mov rax, qword [rbx + ioReqPkt.strtsc]  ;Get the starting sector
    cmp rax, qword [qMaxSector]
    ja .badSector
    mov ecx, dword [rbx + ioReqPkt.tfrlen]
    push rax
    add rax, rcx
    dec rax         ;Decrement by 1 as ecx countains count!
    cmp rax, qword [qMaxSector]
    pop rax
    ja .badSector
    shl rax, 9  ;Multiply by 9 to get the byte to start xfr at 
    shl rcx, 9  ;Multiply by 9 to get number of bytes to transfer
    return
.badSector:
;Set the error code and return
    mov word [rbx + ioctlReqPkt.status], drvErrStatus | drvSecNotFnd
    return

open:
    cmp byte [rbx + openReqPkt.hdrlen], openReqPkt_size
    jne errBadReqLen
;Inc past -1 does nothing as DOS never checks error here
    cmp word [wOpenCnt], -1
    rete
    inc word [wOpenCnt]
    return
close:
    cmp byte [rbx + closeReqPkt.hdrlen], closeReqPkt_size
    jne errBadReqLen
;Dec past zero does nothing as DOS never checks error here
    cmp word [wOpenCnt], 0
    rete
    dec word [wOpenCnt]
    return
remmed:
    cmp byte [rbx + remMediaReqPkt.hdrlen], remMediaReqPkt_size
    jne errBadReqLen
;Return indicator that we are a fixed disk
    mov word [rbx + remMediaReqPkt.status], drvBsyStatus
    return

ioctl:
;All IOCTL calls fail as if the driver didnt understand the command!
    pop rax ;Pop the return address off the stack
    jmp errBadCmd

getDrvMap:
;Returns an indication that we do not have multiple units
    cmp byte [rbx + getDevReqPkt.hdrlen], getDevReqPkt_size
    jne errBadReqLen
    mov byte [rbx + getDevReqPkt.unitnm], 0
    return

;------------------
; Init trampoline :
;------------------
init:
    test byte [bDrvInit], -1
    jnz ioctl   ;Once initialised, we return bad command. Behave like ioctl.
;Else, fall through to the initialisation routine (which we eject)
eject:
;-------------------------
; Initialisation routine :
;-------------------------
initMain:
    cmp byte [rbx + initReqPkt.hdrlen], initReqPkt_size
    jne errBadReqLen
;Start by trying to allocate memory.
    push rdx
    lea rdx, initStr
    mov eax, 0900h
    int 21h

    lea rsi, ramBpb ;Point rsi to the ram bpb
;Here we parse the input string. Values get copied into the bpb.
;In v1 there is nothing so we do nothing here.

;First compute the max sector address!!
    movzx eax, word [rsi + bpb.totSec16]
    dec eax
    mov qword [qMaxSector], rax     ;In v1 this should be 4E7Eh
;Now compute the bytes per sector shift. We only accept sector sizes of
; 128, 256, 512 or 1024. Default to 512 if something weird found.
    movzx eax, word [rsi + bpb.bytsPerSec]
    cmp eax, 128
    jne .not128
    mov byte [bBytSectShft], 7
    jmp short .shiftOk
.not128:
    cmp eax, 256
    jne .not256
    mov byte [bBytSectShft], 8
    jmp short .shiftOk
.not256:
    cmp eax, 1024
    jne .not1024
    mov byte [bBytSectShft], 10
    jmp short .shiftOk
.not1024:
    mov byte [bBytSectShft], 9  ;Default value
.shiftOk:
;Now we allocate our "disk" in RAM
    movzx eax, word [rsi + bpb.totSec16]    ;Allocation size in sectors
    movzx ecx, byte [bBytSectShft]          ;Get shift value
    sub ecx, 4      ;Turn sector->byte shift to sector->paragraphs shift
    shl eax, cl     ;Get number of paragraphs for these sectors
    push rbx        ;Save the request packet pointer on the stack
    mov ebx, eax    ;Move paragraphs into ebx for DOS call
    mov eax, 4800h
    int 21h
    pop rbx         ;Get the request packet pointer from the stack
    jc .failinit

    mov qword [pAlloc], rax ;Save the pointer to our ramdrive
    mov rdi, rax            ;Move pointer to rdi

    push rdi                                ;Save the pointer on stack
    movzx ecx, word [rsi + bpb.FATsz16]     ;#of sectors for the fat
    movzx eax, word [rsi + bpb.revdSecCnt]  ;Get reserved sector count
    add eax, ecx                            ;Add Reserved sector
    movzx ecx, byte [bBytSectShft]          ;Get the shift value
    shl eax, cl                             ;Get bytes
    mov ecx, eax                            ;Store it in ecx
;We ensure # of root dir entries fill up sector
    movzx eax, word [rsi + bpb.rootEntCnt]  ;Get # of 32 byte entries
    shl eax, 5                              ;Multiply by 32 to get bytes
    add ecx, eax                            ;Sum them together
    xor eax, eax
    rep stosb       ;Clean memory
    pop rdi         ;Point back to the start of the in memory ram

    push rdi        ;And save this pointer one more time
    push rsi        ;Push pointer to BPB 
    lea rsi, OEMstring
    add rdi, 3      ;Go past the jump bytes
    movsq           ;Move the string over
    pop rsi         ;Point rsi back to the BPB
    push rsi        ;And save it once more
    mov ecx, bpb_size
    rep movsb       ;Now copy the BPB over
    pop rsi         ;Move rsi back to the start of the bpb
    pop rdi         ;and move rdi back to the start of the arena
    movzx ecx, word [rsi + bpb.bytsPerSec]
    add rdi, rcx    ;Move rdi to the start of the next "sector"
    mov rax, 0FFFFFFFAh ;Store the initial Qword of the FAT
    stosq
    lea rdx, initDoneStr
    mov eax, 0900h
    int 21h
;Now setup return values in the packet and read the unit number from it
; and finish by setting the init lock
    lea rsi, ramBpb                 ;Should be ok to remove this!!
    mov qword [pBpbArray], rsi
    lea rsi, pBpbArray
    mov qword [rbx + initReqPkt.optptr], rsi    ;Move pointer
    lea rsi, eject
    mov qword [rbx + initReqPkt.endptr], rsi    ;Eject all this code
    mov byte [rbx + initReqPkt.numunt], 1       ;Have 1 block unit
    movzx eax, byte [rbx + initReqPkt.drvnum]   ;Get the unit number
    mov byte [bUnitNumber], al
    mov byte [bDrvInit], -1                     ;Set init lock
    pop rdx
    return
.failinit:
    lea rdx, initFailStr
    mov eax, 0900h
    int 21h
    lea rsi, header
    mov qword [rbx + initReqPkt.endptr], rsi    ;Free the driver allocation
    mov byte [rbx + initReqPkt.numunt], 0       ;Have no block units
    pop rdx
    return

;Temp vars and data that are ejected after alloc
pBpbArray   dq 0
initStr     db 0Ah,0Dh,"Initialising RAM drive...$"
initDoneStr db " done. Allocated: 10Mb",0Ah,0Dh,"$"
initFailStr db " failed.",0Ah,0Dh,"$"
OEMstring   db "RAMDRIVE"

bBytSectShft    db 9    ;Shift value to convert bytes to sectors
