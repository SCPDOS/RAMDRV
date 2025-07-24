;The following are Driver error codes + 19
errWpd      equ 0  ;Attempt to write on write protected disk
errUnkUnt   equ 1  ;Unknown Unit
errDrvNR    equ 2  ;Drive not ready
errUnkCmd   equ 3  ;Unknown Command
errCRCerr   equ 4  ;Data (CRC) error
errBadRLn   equ 5  ;Bad request structure length
errSekErr   equ 6  ;Seek error
errUnkMed   equ 7  ;Unknown media type
errSecNF    equ 8  ;Sector not Found
errNoPap    equ 9  ;Printer out of paper
errWF       equ 10  ;Write fault
errRF       equ 11  ;Read fault
errGF       equ 12  ;General fault