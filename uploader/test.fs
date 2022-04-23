0b01010100 0 config,
0b11111111 1 config,
0b01111111 2 config,
0b11111111 3 config,
0b11100000 4 config,
\ 0b00000000 5 config,
0b00000111 5 config,

\ todo labels that can jump forward

0x04be constant lata
0x04c6 constant trisa
0x04ce constant porta
0x0400 constant ansela

0x007d constant dac1datl
0x007f constant dac1con
0x00a0 constant dac2datl
0x00a2 constant dac2con

0x0318 constant tmr0l
0x0319 constant tmr0h
0x031a constant t0con0
0x031b constant t0con1

0x0205 constant ra4pps

0x4cf constant portb

: banksel, ( full-addr -- )
  8 rshift movlb, ;

: store-w 0 ;
: store-f 1 ;
: use-access 0 ;
: use-bsr 1 ;

\ ===

porta banksel,
porta use-bsr clrf,

lata banksel,
lata use-bsr clrf,

ansela banksel,
ansela use-bsr clrf,

trisa banksel,
0b00010000 movlw,
trisa use-bsr movwf,

\ init tmr0
(
t0con0 banksel,
0b10000000 movlw,
t0con0 use-bsr movwf,
0b01110000 movlw,
t0con1 use-bsr movwf,
0x7f movlw,
tmr0h use-bsr movwf,

ra4pps banksel,
0x23 movlw,
ra4pps use-bsr movwf,


\ init dac1
dac1con banksel,
0b10100000 movlw,
dac1con use-bsr movwf,

dac1datl use-bsr clrf,
)

label dacloop
\ dac1con banksel,
  \ dac1datl store-f use-bsr comf,
\   (
\   dac1datl store-f use-bsr incf,
\   0x7f movlw,
\   dac1datl store-f use-bsr andwf,
\   )
\ 
\ (
  lata banksel,
\ 
    lata 1 clrf,
    nop,
    nop,
    lata 1 1 comf,
\   )
   \ clrwdt,
   nop,
dacloop 2 / goto,
