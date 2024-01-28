;ALARM CLOCK on N76E003
;Date: Jan 27, 2024
;Author: Maya Taylor
;Features:
;Can adjust the clocks hours, minutes, seconds and AM/PM
;Can adjust the alarm's hours, minutes, AM/PM and set it/turn it on
;Alarm will not go off if not in "ON" mode
;When alarm goes off it will ask you a boolean algebra question and evaluate your response
;If your response is incorrect, you will receive a "Think Harder!!" message
;Alarm will only turn off if you enter the answer correctly
;Note: buttons can be held down to increase

;using R1 for clk AM/PM
;using R2 for alarm AM/PM
;using R3 for alarm on or off

$NOLIST
$MODN76E003
$LIST

;  N76E003 pinout:
;                               -------
;       PWM2/IC6/T0/AIN4/P0.5 -|1    20|- P0.4/AIN5/STADC/PWM3/IC3
;               TXD/AIN3/P0.6 -|2    19|- P0.3/PWM5/IC5/AIN6
;               RXD/AIN2/P0.7 -|3    18|- P0.2/ICPCK/OCDCK/RXD_1/[SCL]
;                    RST/P2.0 -|4    17|- P0.1/PWM4/IC4/MISO
;        INT0/OSCIN/AIN1/P3.0 -|5    16|- P0.0/PWM3/IC3/MOSI/T1
;              INT1/AIN0/P1.7 -|6    15|- P1.0/PWM2/IC2/SPCLK
;                         GND -|7    14|- P1.1/PWM1/IC1/AIN7/CLO
;[SDA]/TXD_1/ICPDA/OCDDA/P1.6 -|8    13|- P1.2/PWM0/IC0
;                         VDD -|9    12|- P1.3/SCL/[STADC]
;            PWM5/IC7/SS/P1.5 -|10   11|- P1.4/SDA/FB/PWM1
;                               -------
;

CLK           EQU 16600000 ; Microcontroller system frequency in Hz
TIMER0_RATE   EQU 4096     ; 2048Hz squarewave (peak amplitude of CEM-1203 speaker)
TIMER0_RELOAD EQU ((65536-(CLK/TIMER0_RATE)))
TIMER2_RATE   EQU 1000     ; 1000Hz, for a timer tick of 1ms
TIMER2_RELOAD EQU ((65536-(CLK/TIMER2_RATE)))

HR_BUTTON     equ P1.6
MIN_BUTTON    equ P1.5
SEC_BUTTON    equ P1.0 ;also used for inputting alarm answer
AM_PM         equ P1.1
SET_IT		  equ P1.2
SOUND_OUT     equ P1.7

; Reset vector
org 0x0000
    ljmp main

; External interrupt 0 vector (not used in this code)
org 0x0003
	reti

; Timer/Counter 0 overflow interrupt vector
org 0x000B
	ljmp Timer0_ISR

; External interrupt 1 vector (not used in this code)
org 0x0013
	reti

; Timer/Counter 1 overflow interrupt vector (not used in this code)
org 0x001B
	reti

; Serial port receive/transmit interrupt vector (not used in this code)
org 0x0023 
	reti
	
; Timer/Counter 2 overflow interrupt vector
org 0x002B
	ljmp Timer2_ISR

; In the 8051 we can define direct access variables starting at location 0x30 up to location 0x7F
dseg at 0x30
Count1ms:     ds 2 ; Used to determine when half second has passed
BCD_counter:  ds 1 ; The BCD counter incrememted in the ISR and displayed in the main loop
BCD_counter1:  ds 1 ; The BCD counter incrememted minutes
BCD_counter2:  ds 1 ; The BCD counter incrememted hours

BCD_counter_temp:  ds 1 ; The BCD counter incrememted in the ISR and displayed in the main loop
BCD_counter1_temp:  ds 1 ; The BCD counter incrememted minutes
BCD_counter2_temp:  ds 1 ; The BCD counter incrememted hours

BCD_alarm_min:  ds 1 ; The BCD counter incrememted minutes
BCD_alarm_hour:  ds 1 ; The BCD counter incrememted hours

clk_am_pm: ds 1 ;stores whether the clock is in AM or PM mode
alarm_am_pm: ds 1 ;stores whether the alarm is in AM or PM mode

alarm_ans: ds 1 ;stores the answer being entered into the Alarm question
q_count: ds 1 ;keeps track of how which question to ask on the next alarm



bseg
half_seconds_flag: dbit 1 ; Set to one in the ISR every time 500 ms had passed

cseg
; These 'equ' must match the hardware wiring
LCD_RS equ P1.3
;LCD_RW equ PX.X ; Not used in this code, connect the pin to GND
LCD_E  equ P1.4
LCD_D4 equ P0.0
LCD_D5 equ P0.1
LCD_D6 equ P0.2
LCD_D7 equ P0.3

$NOLIST
$include(LCD_4bit.inc) ; A library of LCD related functions and utility macros
$LIST

;                     1234567890123456    <- This helps determine the location of the counter
Initial_Message:  db 'Time  xx:xx:xx A', 0
Initial_Message2: db 'Alarm xx:xx A --', 0
Alarm_On: db         'Alarm xx:xx A on', 0
Alarm_Off: db        'Alarm xx:xx A --', 0
AM : db 'A', 0
PM : db 'P', 0

ALARM_1: db          '  1011 & 1100?   ', 0
ALARM_2: db          'ANSWER IN DEC:     ', 0
	;answer is 1000 which is 8
FAIL_1: db           ' THINK HARDER!!   ', 0
FAIL_2: db           '                  ', 0

ALARM_3: db          '  0011 ^ 0101?  ', 0
ALARM_4: db          'ANSWER IN DEC:  ', 0
;answer is 0110, which is 6

ALARM_5: db          '  0011 | 0101?  ', 0
ALARM_6: db          'ANSWER IN DEC:  ', 0
	;answer is 0111 which is 7
;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 0                     ;
;---------------------------------;

Timer0_Init:
	orl CKCON, #0b00001000 ; Input for timer 0 is sysclk/1
	mov a, TMOD
	anl a, #0xf0 ; 11110000 Clear the bits for timer 0
	orl a, #0x01 ; 00000001 Configure timer 0 as 16-timer
	mov TMOD, a
	mov TH0, #high(TIMER0_RELOAD)
	mov TL0, #low(TIMER0_RELOAD)
	; Enable the timer and interrupts
    ;setb ET0  ; Enable timer 0 interrupt
    setb TR0  ; Start timer 0
	ret

;---------------------------------;
; ISR for timer 0.  Set to execute;
; every 1/4096Hz to generate a    ;
; 2048 Hz wave at pin SOUND_OUT   ;
;---------------------------------;

;This ISR only goes off when the alarm is sounding
Timer0_ISR:
	;clr TF0  ; According to the data sheet this is done for us already.
	; Timer 0 doesn't have 16-bit auto-reload, so
	clr TR0
	mov TH0, #high(TIMER0_RELOAD)
	mov TL0, #low(TIMER0_RELOAD)

	setb TR0	
	cpl SOUND_OUT ; Connect speaker the pin assigned to 'SOUND_OUT'!
	reti

;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 2                     ;
;---------------------------------;
Timer2_Init:
	mov T2CON, #0 ; Stop timer/counter.  Autoreload mode.
	mov TH2, #high(TIMER2_RELOAD)
	mov TL2, #low(TIMER2_RELOAD)
	; Set the reload value
	orl T2MOD, #0x80 ; Enable timer 2 autoreload
	mov RCMP2H, #high(TIMER2_RELOAD)
	mov RCMP2L, #low(TIMER2_RELOAD)
	; Init One millisecond interrupt counter.  It is a 16-bit variable made with two 8-bit parts
	clr a
	mov Count1ms+0, a
	mov Count1ms+1, a
	; Enable the timer and interrupts
	orl EIE, #0x80 ; Enable timer 2 interrupt ET2=1
    setb TR2  ; Enable timer 2
	ret

;---------------------------------;
; ISR for timer 2                 ;
;---------------------------------;
Timer2_ISR:
	clr TF2  ; Timer 2 doesn't clear TF2 automatically. Do it in the ISR.  It is bit addressable.
	cpl P0.4 ; To check the interrupt rate with oscilloscope. It must be precisely a 1 ms pulse.
	
	; The two registers used in the ISR must be saved in the stack
	push acc
	push psw
	
	; Increment the 16-bit one mili second counter
	inc Count1ms+0    ; Increment the low 8-bits first
	mov a, Count1ms+0 ; If the low 8-bits overflow, then increment high 8-bits
	jnz Inc_Done
	inc Count1ms+1

Inc_Done:
	; Check if half second has passed
	mov a, Count1ms+0
	cjne a, #low(1000), Timer2_ISR_done_extend
	sjmp jump_fix_inc
	;CHANGE THIS TO 500 FOR 1/2 A SECOND
Timer2_ISR_done_extend:
	ljmp Timer2_ISR_done
	
jump_fix_inc:
	mov a, Count1ms+1
	cjne a, #high(1000), Timer2_ISR_done
	;CHANGE THIS TO 500 FOR 1/2 A SECOND
	
	; 500 milliseconds have passed.  Set a flag so the main program knows
	setb half_seconds_flag ; Let the main program know half second had passed
	cpl TR0 ; Enable/disable timer/counter 0. This line creates a beep-silence-beep-silence sound.
	; Reset to zero the milli-seconds counter, it is a 16-bit variable
	clr a
	mov Count1ms+0, a
	mov Count1ms+1, a
	; Increment the BCD counter
	mov a, BCD_counter
	;jnb UPDOWN, Timer2_ISR_decrement
	add a, #0x01
	sjmp Timer2_ISR_da

Timer2_ISR_da:
	da a ; Decimal adjust instruction.  Check datasheet for more details!
	mov BCD_counter, a

;this is checking the overflows of the seconds
check_if_60:
	mov a, BCD_counter
	cjne a, #0x60, skip_hours ;number 60
	mov BCD_counter, #0x00
	
continue_check_if_60:
	clr TR2                 ; Stop timer 2
	clr a
	mov Count1ms+0, a
	mov Count1ms+1, a	
	; Now clear the BCD counter (seconds counter)
	
	mov a, BCD_counter1 ;incrementing the minutes
	add a, #0x01
	da a
	
	cjne a, #0x60, do_not_rst_mins ;making it clr if minutes too high
	clr a
	mov a, #0x00
	da a
	mov BCD_counter1, a
	
	;increment hours
	mov a, BCD_counter2
	add a, #0x01
	da a
	cjne a, #0x13, do_not_rst_hours ;making it clr if hours too high
	clr a
	mov a, #0x01
	da a
	mov BCD_counter2, a
	
	clr a
	mov a, clk_am_pm
	cjne a, #0x00, overflow_to_am
	;adding a sequence to chnage from AM to PM
	
overflow_to_pm:
	mov clk_am_pm, #0x01		
	sjmp skip_hours
	
overflow_to_am:
	mov clk_am_pm, #0x00
	sjmp skip_hours

do_not_rst_mins:
	mov BCD_counter1, a
	sjmp skip_hours

do_not_rst_hours:
	mov BCD_counter2, a
	
skip_hours:
	setb TR2                ; Start timer 2


Timer2_ISR_done:
	pop psw
	pop acc
	reti


;---------------------------------;
; Main program. Includes hardware ;
; initialization and 'forever'    ;
; loop.                           ;
;---------------------------------;
main:
	; Initialization
    mov SP, #0x7F
    mov P0M1, #0x00
    mov P0M2, #0x00
    mov P1M1, #0x00
    mov P1M2, #0x00
    mov P3M2, #0x00
    mov P3M2, #0x00
          
    lcall Timer0_Init
    lcall Timer2_Init
    setb EA   ; Enable Global interrupts
    lcall LCD_4BIT
    ; For convenience a few handy macros are included in 'LCD_4bit.inc':
	Set_Cursor(1, 1)
    Send_Constant_String(#Initial_Message)
    
    Set_Cursor(2, 1)
    Send_Constant_String(#Initial_Message2)
    
    setb half_seconds_flag
	mov BCD_counter_temp, #0x00
	mov BCD_counter1_temp, #0x00
	mov BCD_counter2_temp, #0x01

	mov BCD_alarm_min, #0x00
	mov BCD_alarm_hour, #0x01
	
	mov alarm_am_pm, #0x00
	mov clk_am_pm, #0x00
	mov q_count, #0x00
	mov R3, #0x00
	mov R4, #0x00
	
setting_time: ;this is where all the clock times are set
	
check_hour:	
	Set_Cursor(1, 7)
	Display_BCD(BCD_counter2_temp)
	
	jb HR_BUTTON, check_mins  ; if the 'CLEAR' button is not pressed skip
	Wait_Milli_Seconds(#100)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb HR_BUTTON, check_mins ; if the 'CLEAR' button is not pressed skip
	
	mov a, BCD_counter2_temp ;incrementing the minutes
	add a, #0x01
	da a
	
	cjne a, #0x13, no_o_flow_hr  ;making it clr if hour too high
	clr a
	mov a, #0x01
	da a
	mov BCD_counter2_temp, a
	
	sjmp check_mins
	;need to deal with overflow
no_o_flow_hr:
	mov BCD_counter2_temp, a

check_mins:	
	Set_Cursor(1, 10)
	Display_BCD(BCD_counter1_temp)
	
	jb MIN_BUTTON, check_secs  ; if the 'CLEAR' button is not pressed skip
	Wait_Milli_Seconds(#100)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb MIN_BUTTON, check_secs ; if the 'CLEAR' button is not pressed skip
	
	mov a, BCD_counter1_temp ;incrementing the minutes
	add a, #0x01
	da a
	
	cjne a, #0x60, no_o_flow_min  ;making it clr if minutes too high
	clr a
	mov a, #0x00
	da a
	mov BCD_counter1_temp, a
	
no_o_flow_min:
	mov BCD_counter1_temp, a
	
check_secs:	
	Set_Cursor(1, 13)
	Display_BCD(BCD_counter_temp)
	
	jb SEC_BUTTON, check_am_pm  ; if the 'CLEAR' button is not pressed skip
	Wait_Milli_Seconds(#100)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb SEC_BUTTON, check_am_pm ; if the 'CLEAR' button is not pressed skip
	
	mov a, BCD_counter_temp ;incrementing the minutes
	add a, #0x01
	da a
	
	cjne a, #0x60, no_o_flow_sec  ;making it clr if minutes too high
	clr a
	mov a, #0x00
	da a
	mov BCD_counter_temp, a
	
no_o_flow_sec:
	mov BCD_counter_temp, a
	
check_am_pm:
	jb AM_PM, check_set  ; if the 'CLEAR' button is not pressed skip
	Wait_Milli_Seconds(#150)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb AM_PM, check_set ; if the 'CLEAR' button is not pressed skip
	
	;have R1 be whether the clk is AM or PM
	;if R1 is 0 it is AM, if its 1 its PM
	mov a, clk_am_pm
	jnz change_to_am
	
change_to_pm:
	mov clk_am_pm, #0x01
	Set_Cursor(1, 16)
	Display_Char(#'P')		
	sjmp check_set
	
jump_extend: ;extending the jump to setting time
	ljmp setting_time	
	
change_to_am:
	mov clk_am_pm, #0x0
	Set_Cursor(1, 16)
	Display_Char(#'A')
	sjmp check_set
	
check_set:	
	jb SET_IT, jump_extend  ; if the 'SET_IT' button is not pressed skip
	Wait_Milli_Seconds(#50)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb SET_IT, jump_extend ; if the 'SET_IT' button is not pressed skip
	
	mov R3, #0
	
	;moving the counters over to their real counterparts which are used by Timer 2
	;the temp variables helped prevent the timer from increasing them as they were being entered
	Set_Cursor(2, 1)
	mov BCD_Counter, BCD_Counter_temp
	mov BCD_Counter1, BCD_Counter1_temp
	mov BCD_Counter2, BCD_Counter2_temp
    Send_Constant_String(#Alarm_Off);string to say alarm is in off mode
	
	; After initialization the program stays in this 'forever' loop
loop:
		
    
check_clk_am_set:
	mov a, clk_am_pm
	jnz set_clk_pm
	
set_clk_am:	
	Set_Cursor(1, 16)
	Display_Char(#'A')
	sjmp check_alarm_hour
	
set_clk_pm:
	Set_Cursor(1, 16)
	Display_Char(#'P')
	

check_alarm_hour:	
	Set_Cursor(2, 7)
	Display_BCD(BCD_alarm_hour)
	
	jb HR_BUTTON, check_alarm_mins  ; if the 'CLEAR' button is not pressed skip
	Wait_Milli_Seconds(#100)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb HR_BUTTON, check_alarm_mins ; if the 'CLEAR' button is not pressed skip
	
	mov a, BCD_alarm_hour ;incrementing the minutes
	add a, #0x01
	da a
	
	cjne a, #0x13, no_o_flow_alarm_hr  ;making it clr if hour too high
	clr a
	mov a, #0x01
	da a
	mov BCD_alarm_hour, a
	
	sjmp check_alarm_mins
	;need to deal with overflow
no_o_flow_alarm_hr:
	mov BCD_alarm_hour, a

check_alarm_mins:	
	Set_Cursor(2, 10)
	Display_BCD(BCD_alarm_min)
	
	jb MIN_BUTTON, check_alarm_am_pm  ; if the 'CLEAR' button is not pressed skip
	Wait_Milli_Seconds(#100)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb MIN_BUTTON, check_alarm_am_pm ; if the 'CLEAR' button is not pressed skip
	
	mov a, BCD_alarm_min ;incrementing the minutes
	add a, #0x01
	da a
	
	cjne a, #0x60, no_o_flow_alarm_min  ;making it clr if minutes too high
	clr a
	mov a, #0x00
	da a
	mov BCD_alarm_min, a
	
no_o_flow_alarm_min:
	mov BCD_alarm_min, a
	
check_alarm_am_pm:
	jb AM_PM, check_alarm_set  ; if the 'CLEAR' button is not pressed skip
	Wait_Milli_Seconds(#250)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb AM_PM, check_alarm_set ; if the 'CLEAR' button is not pressed skip
	
	;have R1 be whether the clk is AM or PM
	;if R1 is 0 it is AM, if its 1 its PM
	mov a, alarm_am_pm
	jnz change_to_alarm_am
	
change_to_alarm_pm:
	mov alarm_am_pm, #0x1
	Set_Cursor(2, 13)
	Display_Char(#'P')		
	sjmp check_alarm_set

	
change_to_alarm_am:
	mov alarm_am_pm, #0x0
	Set_Cursor(2, 13)
	Display_Char(#'A')
	;sjmp check_set
	
check_alarm_set:
	
	mov a, alarm_am_pm
	jnz set_pm
	
set_am:	
	Set_Cursor(2, 13)
	Display_Char(#'A')
	sjmp display
	
set_pm:
	Set_Cursor(2, 13)
	Display_Char(#'P')
	
	
display:
	Set_Cursor(1, 13)     ; the place in the LCD where we want the BCD counter value
	Display_BCD(BCD_counter) ; This macro is also in 'LCD_4bit.inc'
	
	Set_Cursor(1, 10)
	Display_BCD(BCD_counter1)
	
	Set_Cursor(1, 7)
	Display_BCD(BCD_counter2)
	
	Set_Cursor(2, 10)
	Display_BCD(BCD_alarm_min)
	
	Set_Cursor(2, 7)
	Display_BCD(BCD_alarm_hour)

check_the_alarm:
	;check if AM/PM the same: R2 stores alarm, R1 stores clk
	;check if hours the same
	jb SET_IT, check_if_alarm_set  ; if the 'CLEAR' button is not pressed skip
	Wait_Milli_Seconds(#100)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb SET_IT, check_if_alarm_set
	
	mov a, R3 ;checking whether alarm is set
	cjne a, #1, set_alarm_on
		
turn_alarm_off:
	clr a
	mov a, #0x00
	mov R3, a
	
	Set_Cursor(2, 1)
	Send_Constant_String(#Alarm_Off)
	sjmp check_if_alarm_set
	
set_alarm_on:
	clr a
	mov a, #0x01
	mov R3, a
	
	Set_Cursor(2, 1)
	Send_Constant_String(#Alarm_On)	


check_if_alarm_set:
	mov a, R3
	cjne a, #0x01, no_alarm
		
comp_am_pm: ;whether alarm am and pm are the same as the clock's
	mov a, clk_am_pm
	subb a, alarm_am_pm
	da a 
	cjne a, #0x00, no_alarm
	
	mov a, alarm_am_pm
	subb a, clk_am_pm
	da a 
	cjne a, #0x00, no_alarm

comp_hour:;whether alarm's hours are the same as the clock's
	mov a, BCD_counter2
	subb a, BCD_alarm_hour
	da a 
	cjne a, #0x00, no_alarm
	
	mov a, BCD_alarm_hour
	subb a, BCD_counter2
	da a 
	cjne a, #0x00, no_alarm

comp_min:;whether alarm's minutes are the same as the clock's
	mov a, BCD_counter1
	subb a, BCD_alarm_min
	da a 
	cjne a, #0x00, no_alarm
	sjmp sound_the_alarm
		
no_alarm:
	ljmp loop_a ;skip the alarm sequence
	
	
sound_the_alarm:
	cjne R3, #0x01, no_alarm ;safety measure to ensure alarm does not go off incorrectly
	mov alarm_ans, #0x00
	
	setb ET0  ; Enable timer 0 interrupt, timer zero interrupt sounds the alarm

	;check which message should be displayed
	mov a, q_count
	cjne a, #0x00, question_1_disp
	
question_0_disp:
	Set_Cursor(1, 1)
	Send_Constant_String(#ALARM_1)
	Set_Cursor(2, 1)
	Send_Constant_String(#ALARM_2)
	ljmp check_ans_button
	
question_1_disp:
	cjne a, #0x01, question_2_disp
	Set_Cursor(1, 1)
	Send_Constant_String(#ALARM_3)
	Set_Cursor(2, 1)
	Send_Constant_String(#ALARM_4)
	ljmp check_ans_button
	
question_2_disp:
	Set_Cursor(1, 1)
	Send_Constant_String(#ALARM_5)
	Set_Cursor(2, 1)
	Send_Constant_String(#ALARM_6)
	ljmp check_ans_button		
	
fail_message:
	Set_Cursor(1, 1)
	Send_Constant_String(#FAIL_1)
	Set_Cursor(2, 1)
	Send_Constant_String(#FAIL_2)
	Wait_Milli_Seconds(#200)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'		
	Wait_Milli_Seconds(#200)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	Wait_Milli_Seconds(#200)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	Wait_Milli_Seconds(#200)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	Wait_Milli_Seconds(#200)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	Set_Cursor(1, 1)
	Send_Constant_String(#ALARM_1)
	Set_Cursor(2, 1)
	Send_Constant_String(#ALARM_2)
	
check_ans_button:
	
	Set_Cursor(2, 15)
	Display_BCD(alarm_ans)
	
	jb SEC_BUTTON, check_ans ; if the 'CLEAR' button is not pressed skip
	Wait_Milli_Seconds(#100)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb SEC_BUTTON, check_ans ; if the 'CLEAR' button is not pressed skip
	
	mov a, alarm_ans ;incrementing the minutes
	add a, #0x01
	da a
	
	cjne a, #0x10, no_o_flow_ans  ;making it clr if minutes too high
	clr a
	mov a, #0x00
	da a
	mov alarm_ans, a
	
	
no_o_flow_ans:
	mov alarm_ans, a
	sjmp check_ans
	
check_ans_button_extend:
	ljmp check_ans_button

fail_message_extend: ;can't reach
	ljmp fail_message

check_ans:
	;using the set_button
	jb SET_IT, check_ans_button_extend ; if the 'SET_IT' button is not pressed skip
	Wait_Milli_Seconds(#100)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb SET_IT, check_ans_button_extend ; if the 'SET_IT' button is not pressed skip	
	
	;if answer is right continue
	mov a, q_count
	cjne a, #0x00, question_1_check
	
question_0_check: ;want answer 8	
	mov a, alarm_ans
	subb a, #0x08
	da a 
	cjne a, #0x00, fail_message_extend
	mov a, #0x08
	
	subb a, alarm_ans
	da a 
	cjne a, #0x00, fail_message_extend
	mov q_count, #0x01
	ljmp question_passed
	
question_1_check:
	cjne a, #0x01, question_2_check
	mov a, alarm_ans
	subb a, #0x06
	da a 
	cjne a, #0x00, fail_message_extend
	mov a, #0x06
	
	subb a, alarm_ans
	da a 
	cjne a, #0x00, fail_message_extend
	mov q_count, #0x02
	ljmp question_passed
	
question_2_check:
	mov a, alarm_ans
	subb a, #0x07
	da a 
	cjne a, #0x00, fail_message_extend
	mov a, #0x07
	
	subb a, alarm_ans
	da a 
	cjne a, #0x00, fail_message_extend
	mov q_count, #0x00
	ljmp question_passed
	
question_passed:	
	mov R3, #0x00
	clr ET0  ; Enable timer 0 interrupt
	
	Set_Cursor(1, 1)
    Send_Constant_String(#Initial_Message)
    
    Set_Cursor(2, 1)
    Send_Constant_String(#Initial_Message2)	
    
    Set_Cursor(1, 13)     ; the place in the LCD where we want the BCD counter value
	Display_BCD(BCD_counter) ; This macro is also in 'LCD_4bit.inc'
	
	Set_Cursor(1, 10)
	Display_BCD(BCD_counter1)
	
	Set_Cursor(1, 7)
	Display_BCD(BCD_counter2)
	
	Set_Cursor(2, 10)
	Display_BCD(BCD_alarm_min)
	
	Set_Cursor(2, 7)
	Display_BCD(BCD_alarm_hour)

loop_a:

	jnb half_seconds_flag, loop_extend
	sjmp loop_b
	
	
loop_extend:
	ljmp loop
loop_b:
	clr half_seconds_flag 
    ljmp loop
END
