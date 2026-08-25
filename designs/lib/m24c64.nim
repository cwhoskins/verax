## An I2C EEPROM target: ST's M24C64-U, 64 Kbit with a factory-programmed
## 128-bit unique ID.
##
## Event-driven, like `examples/xspice_dff.nim` and unlike the LT8640A models
## next door: there is no matrix to load and no `partial` anywhere. ngspice
## calls this when SDA or SCL changes, it works out which edge that was, and
## it schedules its own SDA output. The whole part is two digital pins.
##
## **SDA is one `inout` port, and that is the open-drain pin.** Pulling low is
## `dsZero` at `dgStrong`; releasing is `dgHiImpedance`, which lets whatever
## is on the other side of the pin -- a `d_pullup` on a digital bus, or a real
## resistor through a `bidi_bridge` on an analog one -- decide the line. The
## model never drives a `1`, because neither does the part.
##
## SCL is a plain input: the M24C64 does not stretch the clock, so there is
## nothing for the target to drive there and nothing for the controller to
## sample back. A part that *did* stretch would need `scl` to be `inout` too.
##
## What is modelled, from the datasheet:
##
## * Device select `1010 E2 E1 E0 R/W` (`0xA0`/`0xA1` at E=000) for the memory
##   array, `1011 E2 E1 E0 R/W` (`0xB0`/`0xB1`) for the 32-byte identification
##   page. Two address bytes in both cases; for the ID page A15..A5 are
##   don't-care and A4..A0 pick the byte.
## * Byte and page write. Data lands in a 32-byte buffer and commits to the
##   array only on STOP, and the write pointer **wraps inside the page** -- the
##   low five address bits roll over and the upper bits do not advance. Write
##   36 bytes and the last four land at the *start* of the page.
## * Current-address, random and sequential read. The read pointer wraps at
##   the end of the array, not at the end of the page. Getting those two wraps
##   different is most of the reason to model the part rather than fake it.
## * A real write cycle. On the STOP that ends a write the part goes busy for
##   `tw` and **NACKs its own device-select byte** until it is done, which is
##   what makes a controller's ACK-polling loop do something.
##
## Two things stated rather than known, both parameterised so a design can
## correct them without touching this file:
##
## * `uid_offset` -- where the 16 UID bytes sit inside the 32-byte ID page.
##   Defaulted to 0. **Not confirmed against the datasheet**; the ID page's
##   size, its device-select code and the UID's length are.
## * A write addressed at the ID page is acknowledged and discarded. The -U's
##   ID page ships locked read-only, so it certainly does not program; whether
##   the part NACKs the data byte or accepts and ignores it is not established
##   here.
##
## Deliberately not modelled: the WC pin (a design declares it so the netlist
## is honest, and this ignores it), multi-controller arbitration, and any AC
## timing beyond `tpd` -- the model reacts to edges rather than checking that
## they were far enough apart.

import nimcir/spice/xspice/dsl

const
  eeSize* = 8192
    ## 64 Kbit, byte-organised.
  idSize* = 32
    ## The identification page.
  pageSize* = 32
    ## Page-write granularity; also the in-page address wrap.
  uidBytes* = 16
    ## 128 bits of unique ID.
  erasedByte* = 0xFF'u8
    ## What an unprogrammed cell reads as.
  lvZero = 0'i8
  lvOne = 1'i8
    ## `ord(dsZero)` and `ord(dsOne)`, spelled without naming the enum -- see
    ## `PrevIn`.

type
  EeArray* = array[eeSize, uint8]
  IdPage* = array[idSize, uint8]
  PageBuf* = array[pageSize, uint8]

  EeMode = enum
    ## Which way the byte currently on the wire is going.
    emIgnore   ## not addressed, or NACKed: keep off the bus until STOP
    emRx       ## the controller is driving; we sample and acknowledge
    emTx       ## we are driving; the controller acknowledges

  EeStep = enum
    ## Where we are in the instruction, which is what the *next* received byte
    ## means.
    esIdle, esDev, esAddrHi, esAddrLo, esData

  PrevIn = object
    ## The bus as it stood at the previous accepted timepoint, held as plain
    ## levels rather than as `DigitalState`: this type is declared at module
    ## scope so that `-d:xspiceSpecOnly` -- which a design compiles under, and
    ## which imports no ngspice FFI at all -- can still see it.
    scl, sda: int8

  EeState = object
    step: EeStep
    mode: EeMode
    bit: int8
      ## Which bit of the current byte the last SCL falling edge began: 0..7
      ## are data, 8 is the acknowledge slot, and -1 means a START has been
      ## seen but no clock has fallen since.
    started: bool
    shift: uint8        ## byte being clocked in
    outByte: uint8      ## byte being clocked out
    addrHi: uint8
    isId: bool          ## this transfer addresses the identification page
    isRead: bool        ## the device-select byte asked for a read
    ackOk: bool         ## the controller acknowledged the byte we just sent
    sdaLow: bool        ## are we holding SDA down right now
    memAddr: uint16     ## the array pointer
    idAddr: uint8       ## the identification-page pointer
    pageDirty: uint32   ## which of the 32 buffered bytes were actually written
    twEnd: float        ## absolute time the write cycle ends; 0 when idle

func held(raw, fallback: int8): int8 =
  ## A bus level, treating "neither high nor low" as *no change*.
  ##
  ## An analog line crossing between the two thresholds reads as `dsUnknown`,
  ## so a released open-drain line rises 0 -> unknown -> 1 and an edge test
  ## written as "was low, is now high" never fires. Holding the previous level
  ## through the undefined region is what a Schmitt-trigger input does, which
  ## is what the I2C specification requires of a real receiver -- so this is
  ## the part's behaviour rather than a workaround for the bridge. On a purely
  ## digital bus the levels are only ever 0 or 1 and this changes nothing.
  if raw == lvZero or raw == lvOne: raw else: fallback

func hexVal(c: char): int =
  ## -1 for anything that is not a hex digit, so a malformed `uid` truncates
  ## rather than producing a plausible-looking wrong number.
  case c
  of '0'..'9': int(c) - int('0')
  of 'a'..'f': int(c) - int('a') + 10
  of 'A'..'F': int(c) - int('A') + 10
  else: -1

codeModel "m24c64":
  description "M24C64-U I2C EEPROM with a 128-bit unique ID"

  port sda, dir = xdInout, default = xpD, allowed = [xpD],
       description = "serial data, open drain"
  port scl, dir = xdIn, default = xpD, allowed = [xpD],
       description = "serial clock"

  param uid, string, default = "0102030405060708090a0b0c0d0e0f10",
        description = "128-bit unique ID, 32 hex digits"
  param uid_offset, int, default = 0, limits = [0, 16],
        description = "byte offset of the UID within the identification page"
  param dev, int, default = 0, limits = [0, 7],
        description = "the E2/E1/E0 chip-enable address the part answers to"
  param tw, float, default = 5.0e-3,
        description = "write cycle time (s); the part NACKs throughout it"
  param tpd, float, default = 5.0e-8,
        description = "SDA output delay from the SCL edge that caused it (s)"
  param sda_load, float, default = 1.0e-11, description = "SDA pin load (F)"
  param scl_load, float, default = 1.0e-11, description = "SCL pin load (F)"

  eval:
    if init:
      eventAlloc(0, EeState)
      eventAlloc(1, EeArray)
      eventAlloc(2, IdPage)
      eventAlloc(3, PageBuf)
      eventAlloc(4, PrevIn)
      load(sda) = param(sda_load)
      load(scl) = param(scl_load)

    # An idle I2C bus is high, which is the right thing to assume for a level
    # that has never been anything yet.
    let prev = (if time == 0.0: PrevIn(scl: lvOne, sda: lvOne)
                else: eventVar(4, 1, PrevIn))
    let sclNow = held(int8(ord(inputState(scl))), prev.scl)
    let sdaNow = held(int8(ord(inputState(sda))), prev.sda)
    let mem = addr eventVar(1, 0, EeArray)
    let idp = addr eventVar(2, 0, IdPage)
    let buf = addr eventVar(3, 0, PageBuf)

    if time == 0.0:
      # Power-up. An unprogrammed EEPROM reads as 0xFF, and the UID is laid
      # into the identification page from the parameter -- a unique ID is
      # per-device by definition, so it cannot be a constant in the model.
      for i in 0 ..< eeSize: mem[][i] = erasedByte
      for i in 0 ..< idSize: idp[][i] = erasedByte
      let s = param(uid)
      var n = 0
      while n < 2 * uidBytes and s[n] != '\0': n += 1
      let off = int(param(uid_offset))
      var i = 0
      while i < n div 2 and i < uidBytes:
        let hi = hexVal(s[2 * i])
        let lo = hexVal(s[2 * i + 1])
        if hi < 0 or lo < 0: break
        idp[][(off + i) mod idSize] = uint8(hi shl 4 or lo)
        i += 1

      eventVar(0, 0, EeState) = EeState(step: esIdle, mode: emIgnore, bit: -1)
      eventVar(4, 0, PrevIn) = PrevIn(scl: sclNow, sda: sdaNow)
      setOutput(sda, dsOne, dgHiImpedance)
    else:
      eventVar(4, 0, PrevIn) = PrevIn(scl: sclNow, sda: sdaNow)
      var st = eventVar(0, 0, EeState)
      let wasLow = st.sdaLow

      if sclNow == lvOne and prev.scl == lvOne and sdaNow != prev.sda:
        # SDA moved while the clock was high. That is never data, and it is
        # never us -- this model only ever changes SDA on a falling edge.
        if sdaNow == lvZero:
          # START, or a repeated START. The address pointers deliberately
          # survive: a random read is exactly a truncated write followed by a
          # repeated START, and the address it left behind is the point.
          st.step = esDev
          st.mode = emRx
          st.bit = -1
          st.shift = 0
          st.started = true
          st.sdaLow = false
        else:
          # STOP. A page write commits here and nowhere else, which is what
          # makes the write atomic from the bus's point of view.
          if st.pageDirty != 0:
            let base = int(st.memAddr and not 0x1F'u16)
            for i in 0 ..< pageSize:
              if (st.pageDirty and (1'u32 shl i)) != 0:
                mem[][(base + i) mod eeSize] = buf[][i]
            st.pageDirty = 0
            st.twEnd = time + param(tw)
          st.step = esIdle
          st.mode = emIgnore
          st.bit = -1
          st.started = false
          st.sdaLow = false

      elif st.started and sclNow == lvOne and prev.scl == lvZero:
        # Rising edge: everything on the bus is sampled here.
        if st.mode == emRx:
          if st.bit >= 0 and st.bit < 8:
            st.shift = (st.shift shl 1) or
                       (if sdaNow == lvZero: 0'u8 else: 1'u8)
        elif st.mode == emTx:
          if st.bit == 8:
            st.ackOk = sdaNow == lvZero

      elif st.started and sclNow == lvZero and prev.scl == lvOne:
        # Falling edge: everything on the bus changes here.
        st.bit += 1

        if st.bit == 8:
          # The eighth bit was sampled on the edge just gone, so the byte is
          # complete and this is the acknowledge slot.
          if st.mode == emRx:
            case st.step
            of esDev:
              let sel = st.shift shr 4
              let e = (st.shift shr 1) and 0b111
              let busy = st.twEnd > 0.0 and time < st.twEnd
              if busy or e != uint8(param(dev)) or
                 (sel != 0b1010'u8 and sel != 0b1011'u8):
                # Not us, or still writing. NACK by leaving SDA alone: this is
                # the edge an ACK-polling controller is watching.
                st.mode = emIgnore
                st.step = esIdle
                st.sdaLow = false
              else:
                st.isId = sel == 0b1011'u8
                st.isRead = (st.shift and 1'u8) != 0
                st.step = (if st.isRead: esData else: esAddrHi)
                st.sdaLow = true
            of esAddrHi:
              st.addrHi = st.shift
              st.step = esAddrLo
              st.sdaLow = true
            of esAddrLo:
              if st.isId:
                # A15..A5 are don't-care on the identification page.
                st.idAddr = st.shift and uint8(idSize - 1)
              else:
                st.memAddr = (uint16(st.addrHi) shl 8) or uint16(st.shift)
              st.step = esData
              st.sdaLow = true
            of esData:
              if not st.isId:
                let off = int(st.memAddr and 0x1F'u16)
                buf[][off] = st.shift
                st.pageDirty = st.pageDirty or (1'u32 shl off)
                # The in-page wrap: the low five bits roll over and the rest
                # of the address stays put.
                st.memAddr = (st.memAddr and not 0x1F'u16) or
                             uint16((off + 1) and 0x1F)
              st.sdaLow = true
            of esIdle:
              st.sdaLow = false
          else:
            # We were sending: release so the controller can acknowledge.
            st.sdaLow = false

        elif st.bit == 9:
          # The acknowledge has been clocked through; start the next byte.
          st.bit = 0
          if st.mode == emRx and st.isRead and st.step == esData:
            # The device-select byte asked for a read. Everything after it
            # comes from us.
            st.mode = emTx
            if st.isId:
              st.outByte = idp[][st.idAddr]
              st.idAddr = (st.idAddr + 1) and uint8(idSize - 1)
            else:
              st.outByte = mem[][st.memAddr]
              st.memAddr = (st.memAddr + 1) and uint16(eeSize - 1)
            st.sdaLow = (st.outByte and 0x80'u8) == 0
          elif st.mode == emTx:
            if st.ackOk:
              if st.isId:
                st.outByte = idp[][st.idAddr]
                st.idAddr = (st.idAddr + 1) and uint8(idSize - 1)
              else:
                st.outByte = mem[][st.memAddr]
                st.memAddr = (st.memAddr + 1) and uint16(eeSize - 1)
              st.sdaLow = (st.outByte and 0x80'u8) == 0
            else:
              # The controller NACKed, which is how it says "that was the last
              # byte I want". Nothing more until STOP.
              st.mode = emIgnore
              st.sdaLow = false
          else:
            st.shift = 0
            st.sdaLow = false

        else:
          # An ordinary data bit.
          if st.mode == emTx:
            st.sdaLow = (st.outByte and (0x80'u8 shr uint8(st.bit))) == 0
          else:
            st.sdaLow = false

      eventVar(0, 0, EeState) = st

      # One place decides what the pin is doing, and it reports no event when
      # nothing moved. Without that every SCL edge would emit an SDA event and
      # the queue would fill with no-ops.
      if st.sdaLow != wasLow:
        if st.sdaLow: setOutput(sda, dsZero, dgStrong)
        else: setOutput(sda, dsOne, dgHiImpedance)
        outputDelay(sda) = param(tpd)
      else:
        outputChanged(sda) = false
