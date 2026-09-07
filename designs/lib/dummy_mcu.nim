## The other end of the bus: a bit-banging I2C controller that runs one fixed
## script and says whether it worked.
##
## Not a model of any real microcontroller. It exists so that
## `designs/lib/m24c64.nim` has something to talk to, and so that a *protocol*
## exchange -- two behavioural models, a shared bidirectional line, and a
## result that depends on both of them agreeing -- reaches the contract layer
## as a number something can check.
##
## The script:
##
## 1. Read `uid_bytes` bytes from the identification page (`0xB0`, address,
##    repeated START, `0xB1`, sequential read, NACK the last byte, STOP) and
##    compare them against `uid`.
## 2. Write `wr_data` to `wr_addr` in the memory array (`0xA0`, address, data,
##    STOP).
## 3. ACK-poll: START, `0xA0`, look at the acknowledge, STOP, repeat. This is
##    what the EEPROM's write-cycle NACK is for. Bounded by `poll_limit` so a
##    part that never finishes ends the run instead of hanging it.
## 4. Read `rb_data.len` bytes back from `rb_addr` and compare against
##    `rb_data`.
## 5. Drive `done` high, and `pass` high only if both comparisons matched.
##
## **`pass` is low from t = 0 and only ever goes high at the end of step 5.**
## That is the property to keep: a run that stalls half way through reads as a
## failure rather than as a claim nobody checked, which is the whole reason
## the verdict is worth asserting on.
##
## The readback expectation is stated (`rb_data`) rather than assumed equal to
## what was written, because the two differ whenever the write was interesting:
## a page write that runs past the end of its page wraps to the *start* of the
## page, so writing 36 bytes from offset 16 and reading 32 back from offset 0
## is a real and useful check whose expected answer is not `wr_data`. Deriving
## it here would mean reimplementing the EEPROM inside the controller, which
## is exactly the circularity the design is meant to avoid.
##
## ### Timing
##
## `clk` is an ordinary digital clock at four times the bus rate -- ngspice's
## stock `d_osc` supplies it. Four phases per bit is what puts SDA transitions
## in the middle of SCL-low instead of on top of an SCL edge:
##
## | phase | SCL | SDA |
## |---|---|---|
## | 0 | low  | drive this bit, or release |
## | 1 | released -> high | held |
## | 2 | high | sampled |
## | 3 | driven low | held |
##
## An external clock rather than the model scheduling its own wake-ups:
## `cm_event_queue` self-scheduling is not exercised anywhere in this repo,
## and this is already the first two-way protocol in it.
##
## Both SDA and SCL are open drain, like the real thing -- `dgHiImpedance` to
## release, `dsZero`/`dgStrong` to pull down -- so the clock is something the
## bus can hold down even though nothing here does.

import verax/spice/xspice/dsl

const
  mcuProgMax* = 176
    ## Program slots. The longest script is a UID read (24), a write of
    ## `dataMax` bytes (5 + N), a poll loop (4), a readback (8 + N) and the
    ## verdict, so 42 + 2N.
  mcuDataMax* = 40
    ## Most bytes one `wr_data`/`rb_data` may carry. Chosen to cover a
    ## 32-byte page plus enough overrun to make the in-page wrap visible.
  mcuUidMax* = 16
  mcuRxMax* = mcuUidMax + mcuDataMax

  # Program opcodes. Bus ops take a whole byte transfer; the rest run to
  # completion inside one fetch.
  opStart* = 0'u8   ## generate a START (or a repeated START)
  opStop*  = 1'u8   ## generate a STOP
  opTx*    = 2'u8   ## send `arg`; the target's acknowledge lands in `lastAck`
  opRxA*   = 3'u8   ## receive a byte into slot `arg` and acknowledge it
  opRxN*   = 4'u8   ## receive a byte into slot `arg` and NACK it (the last one)
  opPoll*  = 5'u8   ## if the last byte was NACKed and the budget allows, go to `arg`
  opChkId* = 6'u8   ## compare the received UID against the expected one
  opChkRb* = 7'u8   ## compare the readback against the expected one
  opEnd*   = 8'u8   ## drive `done`, and `pass` if both comparisons matched

  boIdle  = 0'u8
  boStart = 1'u8
  boStop  = 2'u8
  boByte  = 3'u8

  lvZero = 0'i8
  lvOne = 1'i8
    ## `ord(dsZero)` and `ord(dsOne)`. Spelled without naming the enum so this
    ## module's types survive `-d:xspiceSpecOnly`, which imports no FFI.

type
  McuProg* = object
    op*: array[mcuProgMax, uint8]
    arg*: array[mcuProgMax, uint8]
    n*: int32
    expUid*: array[mcuUidMax, uint8]
    expRb*: array[mcuDataMax, uint8]
    nUid*, nRb*: int32

  McuRx* = array[mcuRxMax, uint8]

  PrevIn = object
    clk, sda: int8

  McuState = object
    pc: int32
    busOp: uint8
    micro: int8
    bit: int8
    shift: uint8
    outByte: uint8
    rxSlot: uint8
    isTx: bool
    ackAfterRx: bool
    lastAck: bool
    polls: int32
    okId: bool
    okRb: bool
    running: bool
    sdaLow: bool
    sclLow: bool
    doneHi: bool
    passHi: bool

func held(raw, fallback: int8): int8 =
  ## A bus level, treating "neither high nor low" as *no change* -- see the
  ## same helper in `m24c64.nim`. An analog line crossing between the two
  ## receiver thresholds reads as `dsUnknown`, and a controller that sampled
  ## that as data would read a released line as neither one nor zero.
  if raw == lvZero or raw == lvOne: raw else: fallback

func hexVal(c: char): int =
  case c
  of '0'..'9': int(c) - int('0')
  of 'a'..'f': int(c) - int('a') + 10
  of 'A'..'F': int(c) - int('A') + 10
  else: -1

func parseHex(s: cstring, dest: var openArray[uint8], limit: int): int =
  ## Bytes written. Stops at the first thing that is not a hex pair, so a
  ## malformed parameter shortens the transfer rather than inventing data.
  var n = 0
  while n < 2 * limit and s[n] != '\0': n += 1
  var i = 0
  while i < n div 2 and i < limit and i < dest.len:
    let hi = hexVal(s[2 * i])
    let lo = hexVal(s[2 * i + 1])
    if hi < 0 or lo < 0: break
    dest[i] = uint8(hi shl 4 or lo)
    i += 1
  i

codeModel "dummy_mcu":
  description "bit-banged I2C controller running one scripted EEPROM exchange"

  port clk,  dir = xdIn,    default = xpD, allowed = [xpD],
       description = "bit clock, four per SCL period"
  port sda,  dir = xdInout, default = xpD, allowed = [xpD],
       description = "serial data, open drain"
  port scl,  dir = xdInout, default = xpD, allowed = [xpD],
       description = "serial clock, open drain"
  port done, dir = xdOut,   default = xpD, allowed = [xpD],
       description = "high once the script has finished, however it finished"
  port pass, dir = xdOut,   default = xpD, allowed = [xpD],
       description = "high only if every readback matched"

  param uid, string, default = "0102030405060708090a0b0c0d0e0f10",
        description = "the identification-page bytes the target should return"
  param uid_offset, int, default = 0, limits = [0, 31],
        description = "where in the identification page to start reading"
  param dev, int, default = 0, limits = [0, 7],
        description = "the target's E2/E1/E0 chip-enable address"
  param wr_addr, int, default = 16, limits = [0, 8191],
        description = "memory address the write starts at"
  param wr_data, string, default = "5aa5c33c",
        description = "bytes to write, as hex digit pairs"
  param rb_addr, int, default = -1, limits = [-1, 8191],
        description = "address to read back from; -1 means wr_addr"
  param rb_data, string, default = "same",
        description = "bytes the readback should return; same means wr_data"
  param poll_limit, int, default = 400, limits = [1, 100000],
        description = "most acknowledge polls before giving up on the write"
  param t_start, float, default = 5.0e-6,
        description = "how long to leave the bus idle before the first START (s)"
  param tpd, float, default = 5.0e-8,
        description = "SDA/SCL output delay from the clock edge that caused it (s)"
  param clk_load, float, default = 1.0e-12, description = "clk pin load (F)"
  param sda_load, float, default = 1.0e-11, description = "SDA pin load (F)"
  param scl_load, float, default = 1.0e-11, description = "SCL pin load (F)"

  eval:
    if init:
      eventAlloc(0, McuState)
      eventAlloc(1, McuProg)
      eventAlloc(2, McuRx)
      eventAlloc(3, PrevIn)
      load(clk) = param(clk_load)
      load(sda) = param(sda_load)
      load(scl) = param(scl_load)

    # An idle I2C bus is high, which is the right thing to assume for a level
    # that has never been anything yet.
    let prev = (if time == 0.0: PrevIn(clk: lvZero, sda: lvOne)
                else: eventVar(3, 1, PrevIn))
    let clkNow = int8(ord(inputState(clk)))
    let sdaNow = held(int8(ord(inputState(sda))), prev.sda)
    let prog = addr eventVar(1, 0, McuProg)
    let rx = addr eventVar(2, 0, McuRx)

    if time == 0.0:
      # Assemble the script. Doing it here rather than in the state machine
      # keeps the machine a plain interpreter, and keeps every
      # parameter-dependent decision -- how many bytes, which addresses -- in
      # one readable place.
      for i in 0 ..< mcuRxMax: rx[][i] = 0'u8
      prog[].nUid = int32(parseHex(param(uid), prog[].expUid, mcuUidMax))
      var nWr: array[mcuDataMax, uint8]
      let wrN = parseHex(param(wr_data), nWr, mcuDataMax)
      # The sentinel is the word `same` rather than an empty string: cmpp
      # lexes `""` as zero elements and rejects the whole table.
      let rbSrc = param(rb_data)
      let rbSame = rbSrc[0] == '\0' or rbSrc[0] == 's'
      prog[].nRb =
        (if rbSame: int32(wrN)
         else: int32(parseHex(rbSrc, prog[].expRb, mcuDataMax)))
      if rbSame:
        for i in 0 ..< wrN: prog[].expRb[i] = nWr[i]

      let idOff = uint8(param(uid_offset))
      let wrA = int(param(wr_addr))
      let rbAraw = int(param(rb_addr))
      let rbA = (if rbAraw < 0: wrA else: rbAraw)
      let devSel = uint8((int(param(dev)) and 7) shl 1)

      var k = 0
      template emit(o, a: uint8) =
        if k < mcuProgMax:
          prog[].op[k] = o
          prog[].arg[k] = a
          k += 1

      # 1: the identification page, device select 1011.
      emit(opStart, 0)
      emit(opTx, 0xB0'u8 or devSel)
      emit(opTx, 0)
      emit(opTx, idOff)
      emit(opStart, 0)
      emit(opTx, 0xB1'u8 or devSel)
      for i in 0 ..< prog[].nUid:
        emit((if i == prog[].nUid - 1: opRxN else: opRxA), uint8(i))
      emit(opStop, 0)
      emit(opChkId, 0)

      # 2: the page write, device select 1010.
      emit(opStart, 0)
      emit(opTx, 0xA0'u8 or devSel)
      emit(opTx, uint8((wrA shr 8) and 0xFF))
      emit(opTx, uint8(wrA and 0xFF))
      for i in 0 ..< wrN: emit(opTx, nWr[i])
      emit(opStop, 0)

      # 3: acknowledge polling. The target NACKs its own address until the
      # write cycle is over, so this loop is the only thing that knows when
      # the part is ready.
      let pollTop = uint8(k)
      emit(opStart, 0)
      emit(opTx, 0xA0'u8 or devSel)
      emit(opStop, 0)
      emit(opPoll, pollTop)

      # 4: the readback, as a random read -- a truncated write to set the
      # address, then a repeated START.
      emit(opStart, 0)
      emit(opTx, 0xA0'u8 or devSel)
      emit(opTx, uint8((rbA shr 8) and 0xFF))
      emit(opTx, uint8(rbA and 0xFF))
      emit(opStart, 0)
      emit(opTx, 0xA1'u8 or devSel)
      for i in 0 ..< prog[].nRb:
        emit((if i == prog[].nRb - 1: opRxN else: opRxA),
             uint8(mcuUidMax + i))
      emit(opStop, 0)
      emit(opChkRb, 0)
      emit(opEnd, 0)
      prog[].n = int32(k)

      eventVar(0, 0, McuState) = McuState(busOp: boIdle)
      eventVar(3, 0, PrevIn) = PrevIn(clk: clkNow, sda: sdaNow)
      setOutput(sda, dsOne, dgHiImpedance)
      setOutput(scl, dsOne, dgHiImpedance)
      setOutput(done, dsZero, dgStrong)
      setOutput(pass, dsZero, dgStrong)
    else:
      eventVar(3, 0, PrevIn) = PrevIn(clk: clkNow, sda: sdaNow)
      var st = eventVar(0, 0, McuState)
      let wasSda = st.sdaLow
      let wasScl = st.sclLow
      let wasDone = st.doneHi
      let wasPass = st.passHi

      if clkNow == lvOne and prev.clk == lvZero:
        if not st.running:
          # Leave the bus alone long enough for the pull-ups to have brought
          # it up. On an analog bus that is an RC, not an instant.
          if time >= param(t_start): st.running = true

        if st.running:
          # Fetch. Everything that is not a byte transfer runs to completion
          # here, so a comparison or a taken branch costs no bus time.
          var guard = 0
          while st.busOp == boIdle and st.pc < prog[].n and guard < mcuProgMax:
            guard += 1
            let o = prog[].op[st.pc]
            let a = prog[].arg[st.pc]
            if o == opStart:
              st.busOp = boStart; st.micro = 0; st.pc += 1
            elif o == opStop:
              st.busOp = boStop; st.micro = 0; st.pc += 1
            elif o == opTx:
              st.busOp = boByte; st.micro = 0; st.bit = 0
              st.isTx = true; st.outByte = a; st.pc += 1
            elif o == opRxA or o == opRxN:
              st.busOp = boByte; st.micro = 0; st.bit = 0
              st.isTx = false; st.ackAfterRx = o == opRxA
              st.rxSlot = a; st.shift = 0; st.pc += 1
            elif o == opPoll:
              if (not st.lastAck) and st.polls < int32(param(poll_limit)):
                st.polls += 1
                st.pc = int32(a)
              else:
                st.pc += 1
            elif o == opChkId:
              var ok = prog[].nUid > 0
              for i in 0 ..< prog[].nUid:
                if rx[][i] != prog[].expUid[i]: ok = false
              st.okId = ok
              st.pc += 1
            elif o == opChkRb:
              var ok = prog[].nRb > 0
              for i in 0 ..< prog[].nRb:
                if rx[][mcuUidMax + i] != prog[].expRb[i]: ok = false
              st.okRb = ok
              st.pc += 1
            else:
              # opEnd, and anything unrecognised, which can only be a bug in
              # the assembler above.
              st.doneHi = true
              st.passHi = st.okId and st.okRb
              st.pc = prog[].n

          # Execute one phase of whatever bus operation is current.
          if st.busOp == boStart:
            # SDA falls while SCL is high. Releasing both first is what makes
            # this work as a repeated START as well as a first one.
            if st.micro == 0:
              st.sdaLow = false; st.sclLow = false
            elif st.micro == 1:
              st.sdaLow = true
            else:
              st.sclLow = true
              st.busOp = boIdle
            st.micro += 1

          elif st.busOp == boStop:
            # SDA rises while SCL is high.
            if st.micro == 0:
              st.sdaLow = true
            elif st.micro == 1:
              st.sclLow = false
            else:
              st.sdaLow = false
              st.busOp = boIdle
            st.micro += 1

          elif st.busOp == boByte:
            if st.micro == 0:
              st.sclLow = true
              if st.isTx:
                st.sdaLow =
                  st.bit < 8 and
                  (st.outByte and (0x80'u8 shr uint8(st.bit))) == 0
              else:
                # Release for the data bits; drive the acknowledge on bit 8.
                st.sdaLow = st.bit == 8 and st.ackAfterRx
              st.micro = 1
            elif st.micro == 1:
              st.sclLow = false
              st.micro = 2
            elif st.micro == 2:
              if st.isTx:
                if st.bit == 8: st.lastAck = sdaNow == lvZero
              elif st.bit < 8:
                st.shift = (st.shift shl 1) or
                           (if sdaNow == lvZero: 0'u8 else: 1'u8)
              st.micro = 3
            else:
              st.sclLow = true
              st.bit += 1
              if st.bit == 9:
                if not st.isTx: rx[][int(st.rxSlot)] = st.shift
                st.busOp = boIdle
              st.micro = 0

      eventVar(0, 0, McuState) = st

      # Report an event on a pin only when that pin moved. On a bus this busy,
      # an unconditional output on every clock edge is thousands of no-ops.
      if st.sdaLow != wasSda:
        if st.sdaLow: setOutput(sda, dsZero, dgStrong)
        else: setOutput(sda, dsOne, dgHiImpedance)
        outputDelay(sda) = param(tpd)
      else:
        outputChanged(sda) = false

      if st.sclLow != wasScl:
        if st.sclLow: setOutput(scl, dsZero, dgStrong)
        else: setOutput(scl, dsOne, dgHiImpedance)
        outputDelay(scl) = param(tpd)
      else:
        outputChanged(scl) = false

      if st.doneHi != wasDone:
        setOutput(done, (if st.doneHi: dsOne else: dsZero), dgStrong)
        outputDelay(done) = param(tpd)
      else:
        outputChanged(done) = false

      if st.passHi != wasPass:
        setOutput(pass, (if st.passHi: dsOne else: dsZero), dgStrong)
        outputDelay(pass) = param(tpd)
      else:
        outputChanged(pass) = false
