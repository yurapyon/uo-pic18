: binary 2 base ! ;
: binary-char? [char] 2 [char] 0 within ;

create nibble-buf 4 chars allot

: read-nibble
  word drop nibble-buf 4 chars move
  ;

: clean-nibble
  nibble-buf 4 0 ?do
    dup i + dup c@ ( nb nb+i nb[i] )
    binary-char? if
      drop
    else
      [char] 0 swap c!
    then
  loop
  drop
  ;

: next-nibble
  read-nibble clean-nibble
  base @ binary
  nibble-buf 4 >number drop
  swap base !
  ;

: b<
  next-nibble 12 lshift
  next-nibble 8  lshift
  next-nibble 4  lshift
  next-nibble or or or
  state @ if
    [compile] literal
  then
  ; immediate

\ =====

: short 2 chars ;
: shorts short * ;
: pw! ( val addr -- )
  over 8 rshift over c!
  1+ c! ;

: _K 1024 * ;

create progmem 32 _K shorts allot
0 value progmem-here

\ todo make sure aligned ? only a problem when putting data in program memory
\      maybe notify on unaligned
: opcode, ( opc -- )
  progmem progmem-here + pw!
  1 shorts +to progmem-here ;

: progmem-data, ( val -- )
  progmem progmem-here + c!
  1 chars +to progmem-here ;

: progmem-block, ( addr ct -- )
  dup >r
  progmem progmem-here + swap move
  r> chars +to progmem-here ;

: progmem-align
  progmem-here short aligned-to to progmem-here ;

: label
  progmem-here constant ;

: prog-addr,abs ( offset -- )
  \ just drop because progmem starts at 0
  drop
  ;

\ TODO
: prog-addr,rel ( addr dest -- )
  ;

create eeprom 512 chars allot
0 value eeprom-here

: eeprom-data,
  eeprom eeprom-here + c!
  1 chars +to eeprom-here ;

: eeprom-block,
  dup >r
  eeprom eeprom-here + swap move
  r> chars +to eeprom-here ;

: eeprom-label
  eeprom-here constant ;

: eeprom-addr ( offset -- )
  0x380000 + ;

create config 9 chars allot

: config, ( val n -- )
  config + c! ;

: config-addr ( offset -- )
  0x300000 + ;

\ =====

: byte-oriented ( f d a -- params )
  swap 1 lshift or 8 lshift or ;

: byte-oriented-a ( f a -- params )
  8 lshift or ;

: bit-oriented ( f b a -- params )
  [compile] byte-oriented ;

\ todo clean up
: literal-inst ;
: control-11 ;
: control-8 ;

: fsr-inst ( fn k -- params )
  swap 6 lshift or ;

: return-inst ;

: addwf,   ( f d a -- ) byte-oriented   b< 0010 01__ ____ ____ or opcode, ;
: addwfc,  ( f d a -- ) byte-oriented   b< 0010 00__ ____ ____ or opcode, ;
: andwf,   ( f d a -- ) byte-oriented   b< 0001 01__ ____ ____ or opcode, ;
: clrf,    ( f a -- )   byte-oriented-a b< 0110 101_ ____ ____ or opcode, ;
: comf,    ( f d a -- ) byte-oriented   b< 0001 11__ ____ ____ or opcode, ;
: decf,    ( f d a -- ) byte-oriented   b< 0000 01__ ____ ____ or opcode, ;
: incf,    ( f d a -- ) byte-oriented   b< 0010 10__ ____ ____ or opcode, ;
: iorwf,   ( f d a -- ) byte-oriented   b< 0001 00__ ____ ____ or opcode, ;
: movwf,   ( f d a -- ) byte-oriented   b< 0101 00__ ____ ____ or opcode, ;
: movff,   ( fs fd -- )
  swap                                  b< 1100 ____ ____ ____ or opcode,
                                        b< 1111 ____ ____ ____ or opcode, ;
: movffl,  ( fs fd -- )
  over 10 rshift                        b< 0000 0000 0110 ____ or opcode,
  tuck 12 rshift swap 2 lshift or       b< 1111 ____ ____ ____ or opcode,
                                        b< 1111 ____ ____ ____ or opcode, ;
: movwf,   ( f a -- )   byte-oriented-a b< 0110 111_ ____ ____ or opcode, ;
: mulwf,   ( f a -- )   byte-oriented-a b< 0000 001_ ____ ____ or opcode, ;
: negf,    ( f a -- )   byte-oriented-a b< 0110 110_ ____ ____ or opcode, ;
: rlcf,    ( f d a -- ) byte-oriented   b< 0011 01__ ____ ____ or opcode, ;
: rlncf,   ( f d a -- ) byte-oriented   b< 0100 01__ ____ ____ or opcode, ;
: rrcf,    ( f d a -- ) byte-oriented   b< 0011 00__ ____ ____ or opcode, ;
: rrncf,   ( f d a -- ) byte-oriented   b< 0100 00__ ____ ____ or opcode, ;
: setf,    ( f a -- )   byte-oriented-a b< 0110 100_ ____ ____ or opcode, ;
: subfwb,  ( f d a -- ) byte-oriented   b< 0101 01__ ____ ____ or opcode, ;
: subwf,   ( f d a -- ) byte-oriented   b< 0101 11__ ____ ____ or opcode, ;
: subwfb,  ( f d a -- ) byte-oriented   b< 0101 10__ ____ ____ or opcode, ;
: swapf,   ( f d a -- ) byte-oriented   b< 0011 10__ ____ ____ or opcode, ;
: xorf,    ( f d a -- ) byte-oriented   b< 0001 10__ ____ ____ or opcode, ;
: cpfseq,  ( f a -- )   byte-oriented-a b< 0110 001_ ____ ____ or opcode, ;
: cpfsgt,  ( f a -- )   byte-oriented-a b< 0110 010_ ____ ____ or opcode, ;
: cpfslt,  ( f a -- )   byte-oriented-a b< 0110 000_ ____ ____ or opcode, ;
: decfsz,  ( f d a -- ) byte-oriented   b< 0010 11__ ____ ____ or opcode, ;
: dcfsnz,  ( f d a -- ) byte-oriented   b< 0100 11__ ____ ____ or opcode, ;
: incfsz,  ( f d a -- ) byte-oriented   b< 0011 11__ ____ ____ or opcode, ;
: infsnz,  ( f d a -- ) byte-oriented   b< 0100 10__ ____ ____ or opcode, ;
: tstfsz,  ( f a -- )   byte-oriented-a b< 0110 011_ ____ ____ or opcode, ;
: bcf,     ( f b a -- ) bit-oriented    b< 1001 ____ ____ ____ or opcode, ;
: bsf,     ( f b a -- ) bit-oriented    b< 1000 ____ ____ ____ or opcode, ;
: btg,     ( f b a -- ) bit-oriented    b< 0111 ____ ____ ____ or opcode, ;
: btfc,    ( f b a -- ) bit-oriented    b< 1011 ____ ____ ____ or opcode, ;
: btfss,   ( f b a -- ) bit-oriented    b< 1010 ____ ____ ____ or opcode, ;
: bc,      ( n -- )     control-8       b< 1110 0010 ____ ____ or opcode, ;
: bn,      ( n -- )     control-8       b< 1110 0110 ____ ____ or opcode, ;
: bnc,     ( n -- )     control-8       b< 1110 0011 ____ ____ or opcode, ;
: bnn,     ( n -- )     control-8       b< 1110 0111 ____ ____ or opcode, ;
: bnov,    ( n -- )     control-8       b< 1110 0101 ____ ____ or opcode, ;
: bnz,     ( n -- )     control-8       b< 1110 0001 ____ ____ or opcode, ;
: bov,     ( n -- )     control-8       b< 1110 0100 ____ ____ or opcode, ;
: bra,     ( n -- )     control-11      b< 1101 0___ ____ ____ or opcode, ;
: bz,      ( n -- )     control-8       b< 1110 0000 ____ ____ or opcode, ;
: call,    ( k s -- )
  9 lshift over 8 rshift or             b< 1110 110_ ____ ____ or opcode,
  swap                                  b< 1111 ____ ____ ____ or opcode, ;
: callw,   ( -- )                       b< 0000 0000 0001 0100 opcode, ;
: goto,    ( k -- )
  dup 8 rshift                          b< 1110 1111 ____ ____ or opcode,
  swap                                  b< 1111 ____ ____ ____ or opcode, ;
: rcall,   ( n -- )     control-11      b< 1101 1___ ____ ____ or opcode, ;
: retfie,  ( s -- )     return-inst     b< 0000 0000 0001 000_ or opcode, ;
: retlw,   ( k -- )     control-8       b< 0000 1100 ____ ____ or opcode, ;
: return,  ( s -- )     return-inst     b< 0000 0000 0001 001_ or opcode, ;
: clrwdt,  ( -- )                       b< 0000 0000 0000 0100 opcode, ;
: daw,     ( -- )                       b< 0000 0000 0000 0111 opcode, ;
: nop,     ( -- )                       b< 0000 0000 0000 0000 opcode, ;
: pop,     ( -- )                       b< 0000 0000 0000 0110 opcode, ;
: push,    ( -- )                       b< 0000 0000 0000 0101 opcode, ;
: reset,   ( -- )                       b< 0000 0000 1111 1111 opcode, ;
: sleep,   ( -- )                       b< 0000 0000 0000 0011 opcode, ;
: addfsr,  ( fn k -- )  fsr-inst        b< 1110 1000 ____ ____ or opcode, ;
: addlw,   ( k -- )     literal-inst    b< 0000 1111 ____ ____ or opcode, ;
: andlw,   ( k -- )     literal-inst    b< 0000 1011 ____ ____ or opcode, ;
: iorlw,   ( k -- )     literal-inst    b< 0000 1001 ____ ____ or opcode, ;
: lfsr,    ( fn k -- )
  tuck 10 rshift swap 4 lshift or       b< 1110 1110 00__ ____ or opcode,
                                        b< 1111 00__ ____ ____ or opcode, ;
: movlb,   ( k -- )     literal-inst    b< 0000 0001 00__ ____ or opcode, ;
: movlw,   ( k -- )     literal-inst    b< 0000 1110 ____ ____ or opcode, ;
: mullw,   ( k -- )     literal-inst    b< 0000 1101 ____ ____ or opcode, ;
: retlw,   ( k -- )     literal-inst    b< 0000 1100 ____ ____ or opcode, ;
: subfsr,  ( fn k -- )  fsr-inst        b< 1110 1001 ____ ____ or opcode, ;
: sublw,   ( k -- )     literal-inst    b< 0000 1000 ____ ____ or opcode, ;
: xorlw,   ( k -- )     literal-inst    b< 0000 1010 ____ ____ or opcode, ;
: tblrd*,  ( -- )                       b< 0000 0000 0000 1000 opcode, ;
: tblrd*+, ( -- )                       b< 0000 0000 0000 1001 opcode, ;
: tblrd*-, ( -- )                       b< 0000 0000 0000 1010 opcode, ;
: tblrd+*, ( -- )                       b< 0000 0000 0000 1011 opcode, ;
: tblwt*,  ( -- )                       b< 0000 0000 0000 1100 opcode, ;
: tblwt*+, ( -- )                       b< 0000 0000 0000 1101 opcode, ;
: tblwt*-, ( -- )                       b< 0000 0000 0000 1110 opcode, ;
: tblwt+*, ( -- )                       b< 0000 0000 0000 1111 opcode, ;

\ todo extended instruction set stuff

\ todo generate binary format
