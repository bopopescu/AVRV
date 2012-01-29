;Bot Initial Draft MCP.
;
;    This program is free software: you can redistribute it and/or modify
;    it under the terms of the GNU General Public License as published by
;    the Free Software Foundation, either version 3 of the License, or
;    (at your option) any later version.
;
;    This program is distributed in the hope that it will be useful,
;    but WITHOUT ANY WARRANTY; without even the implied warranty of
;    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;    GNU General Public License for more details.
;
;    You should have received a copy of the GNU General Public License
;    along with this program.  If not, see <http://www.gnu.org/licenses/>.
;

.nolist
.include "m328Pdef.inc"
.list
.listmac

; Keep the top two items (bytes) on the stack in the X register.
.def TOS = r27 ; XH
.def TOSL = r26 ; XL

; Y register is our Data Stack Pointer.
; Z register will be used for diggin around in the dictionary.

; Buffer pointers
.def Current_key = r14
.def Buffer_top = r15

.def Working = r16

; Registers used by WORD word.
.def word_temp = r17

; Registers used by FIND word.
.def find_buffer_char = r10
.def find_name_char = r11
.def find_temp_offset = r12
.def find_temp_length = r13

; Registers used by "to PFA" word.
.def tpfa_temp_high = r22
.def tpfa_temp_low = r23

.equ IMMED = 0x80

;#######################################################################
; Storage for variables in the SRAM.
; Create a 256-byte heap at the bottom of RAM and allot some initial
; system variables.

.dseg
heap: .org 0x0100 ; On the ATmega328P the SRAM proper begins at 0x100.
State_mem: .byte 1
Latest_mem: .byte 2
Here_mem: .byte 1


;#######################################################################
; Next we have a buffer for input. For now, 128 bytes.
.dseg
.org 0x0200
buffer: .byte 0x80

;#######################################################################
; The Parameter (Data) Stack begins just after the buffer and grows upward
; towards the Return Stack at the top of RAM. Note that the first two bytes
; of stack are kept in the X register. Due to this the initial two bytes of
; the data stack will be filled with whatever was in X before the first
; push, unless you load X (i.e. TOS and Just-Under-TOS) "manually" before
; dropping into the interpreter loop.
.dseg
data_stack: .org 0x0280


;#######################################################################
; From jonesforth.S, some of the Forth standard system vars for
; reference:
;        STATE           Is the interpreter executing code (0) or compiling a word (non-zero)?
;        LATEST          Points to the latest (most recently defined) word in the dictionary.
;        HERE            Points to the next free byte of memory.  When compiling, compiled words go here.
;        S0              Stores the address of the top of the parameter stack.
;        BASE            The current base for printing and reading numbers.

.cseg
;#######################################################################
.org 0x0000            ; Interupt Vectors
  jmp RESET
  jmp BAD_INTERUPT ; INT0 External Interrupt Request 0
  jmp BAD_INTERUPT ; INT1 External Interrupt Request 1
  jmp BAD_INTERUPT ; PCINT0 Pin Change Interrupt Request 0
  jmp BAD_INTERUPT ; PCINT1 Pin Change Interrupt Request 1
  jmp BAD_INTERUPT ; PCINT2 Pin Change Interrupt Request 2
  jmp BAD_INTERUPT ; WDT Watchdog Time-out Interrupt
  jmp BAD_INTERUPT ; TIMER2 COMPA Timer/Counter2 Compare Match A
  jmp BAD_INTERUPT ; TIMER2 COMPB Timer/Counter2 Compare Match B
  jmp BAD_INTERUPT ; TIMER2 OVF Timer/Counter2 Overflow
  jmp BAD_INTERUPT ; TIMER1 CAPT Timer/Counter1 Capture Event
  jmp BAD_INTERUPT ; TIMER1 COMPA Timer/Counter1 Compare Match A
  jmp BAD_INTERUPT ; TIMER1 COMPB Timer/Coutner1 Compare Match B
  jmp BAD_INTERUPT ; TIMER1 OVF Timer/Counter1 Overflow
  jmp BAD_INTERUPT ; TIMER0 COMPA Timer/Counter0 Compare Match A
  jmp BAD_INTERUPT ; TIMER0 COMPB Timer/Counter0 Compare Match B
  jmp BAD_INTERUPT ; TIMER0 OVF Timer/Counter0 Overflow
  jmp BAD_INTERUPT ; SPI, STC SPI Serial Transfer Complete
  jmp BAD_INTERUPT ; USART, RX USART Rx Complete
  jmp BAD_INTERUPT ; USART, UDRE USART, Data Register Empty
  jmp BAD_INTERUPT ; USART, TX USART, Tx Complete
  jmp BAD_INTERUPT ; ADC ADC Conversion Complete
  jmp BAD_INTERUPT ; EE READY EEPROM Ready
  jmp BAD_INTERUPT ; ANALOG COMP Analog Comparator
  jmp BAD_INTERUPT ; TWI 2-wire Serial Interface
  jmp BAD_INTERUPT ; SPM READY Store Program Memory Ready
BAD_INTERUPT:
  jmp 0x0000

;#######################################################################
RESET:
  cli

  ldi Working, low(RAMEND) ; Set up the stack.
  out SPL, Working
  ldi Working, high(RAMEND)
  out SPH, Working

  ldi YL, low(data_stack) ; Initialize Data Stack Pointer.
  ldi YH, high(data_stack)

  ldi Working, low(Here_mem) + 1 ; Set HERE to point to just after itself.
  ldi ZL, low(Here_mem)
  ldi ZH, high(Here_mem)
  st Z, Working

  ldi Working, low(buffer) ; Reset input buffer
  mov Current_key, Working
  mov Buffer_top, Working

  ; Initialize latest
  ldi ZL, low(Latest_mem)
  ldi ZH, high(Latest_mem)
  ldi Working, low(CURRENT_KEY_WORD) ; Current_key is currently Latest.
  st Z+, Working
  ldi Working, high(CURRENT_KEY_WORD)
  st Z, Working


  sei

; TODO: Set up a Stack Overflow Handler and put its address at RAMEND
; and set initial stack pointer to RAMEND - 2 (or would it be 1?)
; That way if we RET from somewhere and the stack is underflowed we'll
; trigger the handler instead of just freaking out.


;#######################################################################
; Some data stack manipulation macros to ease readability.

; Make room on TOS and TOSL by pushing everything down two cells.
.MACRO pushdownw
  st Y+, TOSL ; push TOSL onto data stack
  st Y+, TOS  ; push TOS onto data stack
.ENDMACRO

.MACRO popup
  ld TOSL, -Y ; pop from data stack to TOSL register.
.ENDMACRO
; Note that you are responsible for preserving the previous value of TOSL
; if you still want it after using the macro. (I.e. mov TOS, TOSL)

; Essentially "drop drop".
.MACRO popupw
  ld TOS, -Y
  ld TOSL, -Y
.ENDMACRO

; Load Z register pair with SRAM address of next free byte in heap.
.MACRO z_here
  ldi ZL, low(Here_mem)
  ldi ZH, high(Here_mem)
  ld ZL, Z
  ldi ZH, high(heap)
.ENDMACRO

;#######################################################################
MAIN:
  rcall CHECKIT
  rjmp MAIN


; This is a test/exercise subroutine for tracing in the debugger.
CHECKIT:
  rcall HERE_PFA ; Put address of Here_mem onto the stack
; rcall DUP_PFA
; inc TOS
; rcall SWAP_PFA
; rcall DROP_PFA
  rcall FILL_BUFFER
  rcall INTERPRET_PFA
  ret

COMMAND: .db 9, " tcd : b "

FILL_BUFFER:
  ldi Working, low(buffer)
  mov Current_key, Working
  mov Buffer_top, Working
  pushdownw
  ldi TOSL, low(COMMAND)
  ldi TOS, high(COMMAND)
  rcall LEFT_SHIFT_WORD_PFA
  movw Z, X
  ldi TOSL, low(buffer)
  ldi TOS, high(buffer)
  lpm r0, Z+ ; count
  add Buffer_top, r0 ; set the buffer_top to the end of the string.
_fill_buffer_loop:
  lpm Working, Z+
  st X+, Working
  dec r0
  brne _fill_buffer_loop
  popupw
  ret


;#######################################################################
; Let's make words.

DROP: ; ----------------------------------------------------------------
  .dw 0 ; Initial link field is null.
  .db 4, "drop"
DROP_PFA:
  mov TOS, TOSL
  popup
  ret

SWAP_: ; ---------------------------------------------------------------
  .dw DROP
  .db 4, "swap"
SWAP_PFA:
  mov Working, TOS
  mov TOS, TOSL
  mov TOSL, Working
  ret

DUP: ; -----------------------------------------------------------------
  .dw SWAP_
  .db 3, "dup"
DUP_PFA:
  st Y+, TOSL ; push TOSL onto data stack
  mov TOSL, TOS
  ret

KEY: ; -----------------------------------------------------------------
  .dw DUP
  .db 3, "key"
KEY_PFA:
  cp Current_key, Buffer_top ; If they're the same we're out of input data.
  breq Out_of_input
  ldi ZH, high(buffer) ; Load the char's address in the buffer into Z.
  mov ZL, Current_key
  rcall DUP_PFA
  ld TOS, Z ; Get char from buffer
  inc Current_key
  ret
Out_of_input:
  rcall DUP_PFA
  ldi TOS, 0x15 ; ASCII NACK byte.
  ret

WORD: ; ----------------------------------------------------------------
  .dw KEY
  .db 4, "word"
WORD_PFA:
  rcall KEY_PFA ; Get next char (or NACK, 0x15) onto stack.

  cpi TOS, 0x15 ; Check for error, EOF.
  breq Out_of_input ; This leaves TOSL with an extra copy but should work.

  ; valid char, is it blank?
  cpi TOS, ' '
  brne _a_key
  rcall DROP_PFA ; remove the space
  rjmp WORD_PFA ; get the next char.

_a_key:
  ; put the start offset into a register for later
  mov word_temp, Current_key
  rcall DROP_PFA ; clear the char from the stack.

_find_length:
  rcall KEY_PFA
  cpi TOS, 0x15
  breq Out_of_input
  cpi TOS, ' '
  breq _done_finding
  rcall DROP_PFA ; ditch the char from the stack
  rjmp _find_length ; continue searching for end of word.

_done_finding:
  rcall DUP_PFA ; make room on the stack
  mov TOS, word_temp ; start offset in TOS
  dec TOS ; one less than current key.
  mov TOSL, Current_key ; length in TOSL (replacing leftover last char)
  clc ; clear carry bit just in case
  sbc TOSL, word_temp ; subtract old from new to get length
  ret

LEFT_SHIFT_WORD: ; -----------------------------------------------------
  .dw WORD
  .db 3, "<<w"
LEFT_SHIFT_WORD_PFA:
  mov Working, TOS
  clc ; clear carry flag
  clr TOS ; clear TOS
  lsl TOSL
  brcc _no_carry_var_does ; If the carry bit is clear skip incrementing TOS
  inc TOS ; copy carry flag to TOS[0]
_no_carry_var_does:
  lsl Working
  or TOS, Working
  ; X now contains left-shifted word, and carry bit reflects TOS carry.
  ret

DATA_FETCH: ; ----------------------------------------------------------
  .dw LEFT_SHIFT_WORD
  .db 1, "@"
DATA_FETCH_PFA:
  ldi ZH, high(heap)
  mov ZL, TOS
  ld TOS, Z ; Get byte from heap.
  ret

CREATE: ; --------------------------------------------------------------
  .dw DATA_FETCH
  .db 6, "create"
CREATE_PFA:
  ; offset in TOS, length in TOSL, of new word's name

  z_here ; Z now points to next free byte on heap.
  adiw Z, 2 ; reserve space for the link to Latest

  st Y+, TOSL ; store for later
  mov word_temp, TOSL ; count
  st Z+, TOSL ; store name length in compiling word
  mov TOSL, TOS
  ldi TOS, high(buffer)
  ; X now points to the name in the buffer, Z to the destination

_create_char_xfer:
  ld Working, X+
  st Z+, Working
  dec word_temp
  brne _create_char_xfer

  ld TOSL, -Y ; pop length
  lsr TOSL
  brcs _word_aligned ; odd number, no alignment byte needed
  clr TOSL
  st Z+, TOSL ; write alignment byte
_word_aligned:
  ; The name has been laid down in SRAM.
  ; Write ZL to Here_mem and we're done.
  ldi TOSL, low(Here_mem)
  ldi TOS, high(Here_mem)
  st X, ZL
  popupw ; ditch offset and (right-shifted) length
  ret

FIND: ; ----------------------------------------------------------------
  .dw CREATE
  .db 4, "find"
FIND_PFA:
  ; TOS holds the offset in the buffer of the word to search for and TOSL
  ; holds the length.
  mov find_temp_offset, TOS
  mov find_temp_length, TOSL
  ldi ZH, high(Latest_mem)
  ldi ZL, low(Latest_mem)
  ld TOSL, Z+
  ld TOS, Z

_look_up_word:
; LFA in TOS:TOSL, Z is free

; Check if TOS:TOSL == 0x0000
  cpi TOSL, 0
  brne _non_zero
  cpse TOSL, TOS ; ComPare Skip Equal
  rjmp _non_zero
  ; if TOS:TOSL == 0x0000 we're done.
  ldi TOS, 0xff ; consume TOS/TOSL and return 0xffff (we don't have that
  ldi TOSL, 0xff ; much RAM so this is not a valid address value.)
  ret

_non_zero:
  ; Save current addy
  pushdownw
  ; now stack has ( - LFA, LFA)

  ; Load Link Field Address of next word in the dictionary
  ; into the X register pair.
  rcall LEFT_SHIFT_WORD_PFA
  movw Z, X
  lpm TOSL, Z+
  lpm TOS, Z+
  ; now stack has ( - LFA_next, LFA_current)

  lpm Working, Z+ ; Load length-of-name byte into a register
  cp Working, find_temp_length
  breq _same_length

  ; Well, it ain't this one...
  ; ditch LFA_current
  sbiw Y, 2
  rjmp _look_up_word

_same_length:
  ; If they're the same length walk through both and compare them ;
  ; character by character.
  ;
  ; Buffer offset is in find_temp_offset
  ; length is in Working and find_temp_length
  ; Z holds current word's name's first byte's address in program RAM.
  ; TOS:TOSL have the address of the next word's LFA.
  ; stack has ( - LFA_next, LFA_current)

  ; Put address of search term in buffer into X (TOS:TOSL).
  pushdownw
  ldi TOS, high(buffer) ; Going to look up bytes in the buffer.
  mov TOSL, find_temp_offset
  ; stack ( - &search_term, LFA_next, LFA_current)

_compare_name_and_target_byte:
  ld find_buffer_char, X+ ; from buffer
  lpm find_name_char, Z+ ; from program RAM
  cp find_buffer_char, find_name_char
  breq _okay_dokay

  ; not equal, clean up and go to next word.
  popupw ; ditch search term address
  sbiw Y, 2 ; ditch LFA_current
  rjmp _look_up_word

_okay_dokay:
  ; The chars are the same
  dec Working
  brne _compare_name_and_target_byte ; More to do?

  ; If we get here we've checked that every character in the name and the
  ; target term match.
  popupw ; ditch search term address
  popupw ; ditch LFA_next
  ret

TPFA: ; ----------------------------------------------------------------
  .dw FIND
  .db 4, ">pfa"
TPFA_PFA:
  ; LFA of word should be on the stack (i.e. in X.)
  adiw X, 1         ; point to name length.
  movw tpfa_temp_high:tpfa_temp_low, X   ; set prog mem pointer value aside for later.
  rcall LEFT_SHIFT_WORD_PFA ; Adjust the address
  movw Z, X         ; and put it into our prog-mem-addressing Z register.
  movw X, tpfa_temp_high:tpfa_temp_low
  lpm Working, Z    ; get the length.
                    ; We need to map from length in bytes to length in words
  lsr Working       ; while allowing for the padding bytes in even-length names.
  inc Working       ; n <- (n >> 1) + 1
  add TOSL, Working ; Add the adjusted name length to our prog mem pointer.
  brcc _done_adding
  inc TOS           ; Account for the carry bit if set.
_done_adding:
  ret

INTERPRET: ; -----------------------------------------------------------
  .dw TPFA
  .db 9, "interpret"
INTERPRET_PFA:
  rcall WORD_PFA ; get offset and length of next word in buffer.
  cpi TOS, 0x15
  breq _byee
  rcall FIND_PFA ; find it in the dictionary, (X <- LFA)
  cpi TOS, 0xff
  breq _byee
  pushdownw ; save a copy of LFA on the stack

  ; Calculate PFA and save it in Z.
  rcall TPFA_PFA ; get the PFA address (X <- PFA)
  movw Z, X

  ; Check if the word is flagged as immediate.
  popupw ; get the LFA again
  st Y+, ZL ; save PFA on stack to clear Z for IMMEDIATE_P
  st Y+, ZH
  rcall IMMEDIATE_P_PFA ; stack is one (byte) cell less ( LFA:LFA - imm? )
  mov ZH, TOSL ; restore PFA to Z from stack
  ld ZL, -Y
  breq _execute_it

  ; word is not immediate, check State and act accordingly
  st Y+, TOSL ; free up X register pair (Z still holds PFA)
  ldi TOSL, low(State_mem)
  ldi TOS, high(State_mem)
  ld TOS, X
  popup
  cpi TOS, 0x00 ; immediate mode?
  breq _execute_it

  ; compile mode
  st Y+, TOSL
  movw X, Z ; PFA on stack
  z_here
  st Z+, TOSL ; write PFA to 'here'
  st Z, TOS
  mov Working, ZL ; set here to, uh, here
  ldi ZL, low(Here_mem)
  ldi ZH, high(Here_mem)
  st Z, Working
  ret

_execute_it:
  mov TOS, TOSL ; clear the stack for the "client" word
  popup
  icall ; and execute it.
  rjmp INTERPRET_PFA
_byee:
  popupw ; ditch the "error message"
  ret

IMMEDIATE_P:
  .dw INTERPRET
  .db 4, "imm?"
IMMEDIATE_P_PFA:
  ; LFA on stack
  adiw X, 1
  rcall LEFT_SHIFT_WORD_PFA
  movw Z, X
  lpm TOS, Z
  popup
  andi TOS, IMMED
  cpi TOS, IMMED
  ret

COLON_DOES: ; ----------------------------------------------------------
  .dw IMMEDIATE_P
  .db 10, "colon_does"
COLON_DOES_PFA:
  pop ZH
  pop ZL
_aaagain:
  push ZL
  push ZH
  pushdownw
  movw X, Z
  rcall LEFT_SHIFT_WORD_PFA
  movw Z, X
  popupw
  lpm Working, Z+
  lpm ZH, Z
  mov ZL, Working
  icall
  pop ZH
  pop ZL
  adiw Z, 1
  rjmp _aaagain

EXIT: ; ----------------------------------------------------------------
  .dw COLON_DOES
  .db 4, "exit"
EXIT_PFA:
  ; ditch return PC from the icall and the stored pointer to next PFA.
  in ZL, SPL
  in ZH, SPH
  adiw Z, 4
  out SPL, ZL
  out SPH, ZH
  ret

TEST_COL_D: ; ----------------------------------------------------------
  .dw EXIT
  .db 3, "tcd"
TCD_PFA:
  rcall COLON_DOES_PFA
  .dw DUP_PFA
  .dw EXIT_PFA

LBRAC: ; ---------------------------------------------------------------
  .dw TEST_COL_D
  .db 1, "["
LBRAC_PFA:
  ldi ZL, low(State_mem)
  ldi ZH, high(State_mem)
  ldi Working, 0x00
  st Z, Working
  ret

RBRAC: ; ---------------------------------------------------------------
  .dw LBRAC
  .db 1, "]"
RBRAC_PFA:
  ldi ZL, low(State_mem)
  ldi ZH, high(State_mem)
  ldi Working, 0x01
  st Z, Working
  ret

COLON:
  .dw RBRAC
  .db 1, ":"
COLON_PFA:
  rcall WORD_PFA
  rcall CREATE_PFA
  ; Write COLON_DOES_PFA to HERE and update HERE
  z_here
  ldi Working, low(COLON_DOES_PFA)
  st Z+, Working
  ldi Working, high(COLON_DOES_PFA)
  st Z+, Working
  ; Write ZL to Here_mem
  mov Working, ZL
  ldi ZL, low(Here_mem)
  ldi ZH, high(Here_mem)
  st Z, Working
  ; switch to compiling mode
  rcall RBRAC_PFA
  ret

;#######################################################################
; Variables and system variable words.

VAR_DOES: ; ------------------------------------------------------------
  .dw COLON
  .db 8, "var_does"
VAR_DOES_PFA:
  ; Get the address of the calling variable word's parameter field off
  ; the return stack.  Pop the address to cancel the call to VAR_DOES by
  ; the "instance" variable word.
  pushdownw
  pop TOS
  pop TOSL
  rcall LEFT_SHIFT_WORD_PFA
  ; Stack now contains left-shifted PFA address.

  ; Use it to look up the variable's memory address (in SRAM heap)
  ; Put that address on the data stack (TOS). We only use the low byte
  ; because we'll restrict access to SRAM in the fetch ("@") word.
             ;
  movw Z, X  ; Copy address to Z
  popup      ; adjust the stack
  lpm TOS, Z ; and use Z (PFA of variable instance word) to get the SRAM
             ; offset of the variable's storage.

  ret ; to the word that called the variable word.

HERE_WORD: ; -----------------------------------------------------------
  .dw VAR_DOES
  .db 4, "here"
HERE_PFA:
  rcall VAR_DOES_PFA
  .db low(Here_mem), high(Here_mem) ; Note: I'm putting the full address
                   ; here but the VAR_DOES machinery only uses low byte.
  ; We don't need to ret here because VAR_DOES will consume the top of
  ; the return stack. (I.e. the address of the Here_mem byte above.)

LATEST_WORD: ; ---------------------------------------------------------
  .dw HERE_WORD
  .db 6, "latest"
Latest_PFA:
  rcall VAR_DOES_PFA
  .db low(Latest_mem), high(Latest_mem)

STATE_WORD: ; ----------------------------------------------------------
  .dw LATEST_WORD
  .db 5, "state"
STATE_PFA:
  rcall VAR_DOES_PFA
  .db low(State_mem), high(State_mem)

CURRENT_KEY_WORD: ; ----------------------------------------------------
  .dw STATE_WORD
  .db 4, "ckey"
CURRENT_KEY_PFA:
  rcall DUP_PFA
  mov TOS, Current_key
  ret


;#######################################################################
