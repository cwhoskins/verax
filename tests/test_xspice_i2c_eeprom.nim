import std/[os, strutils, unittest]

import nimcir/contract/dsl
import nimcir/netlist/graph
import nimcir/analysis/transient
import nimcir/spice/xspice/build

import ../designs/lib/i2c_parts

## The I2C EEPROM protocol, end to end, on a **digital** bus.
##
## `designs/i2c_eeprom.nim` runs the same two code models over a real analog
## bus -- pull-up resistors, bus capacitance and a `bidi_bridge` -- which is
## what makes its `i2c` role's claims mean anything. It is also two orders of
## magnitude more analog timepoints, because every released line becomes an RC
## the solver has to follow.
##
## This file swaps that bus for `d_pullup` and keeps everything else. The
## device models cannot tell the difference: their SDA and SCL are digital
## `inout` pins either way, and only what supplies the `1` changes. So the
## protocol -- which is the part with two independent state machines that have
## to agree -- gets a fast regression, and the design gets to be the slow,
## honest one.
##
## The cases are chosen so that each one fails differently if a distinct piece
## of the model is wrong, and in particular so that the verdict is shown to be
## capable of coming out **low**. A pass/fail flag that cannot be made to fail
## is not evidence of anything.

let haveNgspice = findExe("ngspice").len > 0
let haveToolchain =
  haveNgspice and (
    try:
      discard findToolchain()
      true
    except CatchableError:
      false)

proc rig(eeUid, mcuUid: string, tw = 0.0, pollLimit = -1,
         wrAddr = -1, wrData = "", rbAddr = -1, rbData = ""): Design =
  ## One MCU, one EEPROM, a digital bus and somewhere for the verdict to land.
  ##
  ## `xact_done` and `xact_pass` are ordinary analog nets fed by the
  ## `dac_bridge` that `useDummyMcu` installs; the 100k pull-downs give them a
  ## DC path and a defined level before the controller drives them.
  let d = design("i2c_rig"):
    net gnd, kind = ntGround, name = "0"
    net sda, kind = ntSignal
    net scl, kind = ntSignal
    net xact_done, kind = ntSignal
    net xact_pass, kind = ntSignal

    component R1, kind = "resistor", value = "100k":
      pin "1", xact_done, kind = ptPassive
      pin "2", gnd, kind = ptGround
    component R2, kind = "resistor", value = "100k":
      pin "1", xact_pass, kind = ptPassive
      pin "2", gnd, kind = ptGround

    component U1, kind = "mcu", partNumber = "dummy":
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
      pin "DONE", xact_done, kind = ptOutput
      pin "PASS", xact_pass, kind = ptOutput
      pin "VSS", gnd, kind = ptGround

    component U2, kind = "eeprom", partNumber = "M24C64-U":
      pin "SDA", sda, kind = ptInOut
      pin "SCL", scl, kind = ptInOut
      pin "VSS", gnd, kind = ptGround

  useM24C64(d, "U2", uid = eeUid, tw = tw)
  useDummyMcu(d, "U1", uid = mcuUid, pollLimit = pollLimit,
              wrAddr = wrAddr, wrData = wrData,
              rbAddr = rbAddr, rbData = rbData)
  # The bus is digital, so it is not marked analog and no bridge is built.
  digitalBus(d.netlist, [findNet(d.netlist, "sda"), findNet(d.netlist, "scl")])
  d

proc verdict(d: Design, tSettle, tWindow: float): tuple[done, pass: float] =
  ## Both flags out of one run. `analyzeTransient` measures the net it is
  ## given, but the whole plot comes back in `raw`, and running the
  ## transaction twice to read two nodes of it would double the slowest thing
  ## in this file.
  var spec = defaultTransientSpec()
  spec.tSettle = tSettle
  spec.tWindow = tWindow
  let rep = analyzeTransient(d.netlist, "xact_pass", spec)
  checkpoint("issues: " & $rep.issues.len)
  for iss in rep.issues: checkpoint(iss.message)
  let dv = rep.raw["v(xact_done)"]
  (dv[^1], rep["settled_v"])

const goodUid = "0102030405060708090a0b0c0d0e0f10"

suite "i2c eeprom, digital bus":
  test "the toolchain is what decides whether any of this runs":
    if not haveToolchain:
      checkpoint("SKIP: no ngspice, or no configured ngspice source tree; " &
                 "set $NGSPICE_SRC or let xspice/build find one in the cache")
    check true

  if haveToolchain:
    test "the whole transaction completes and every readback matches":
      # Read the UID, write four bytes, ACK-poll through the 5 ms write cycle,
      # read them back. All four stages have to work for `pass` to go high.
      let (dn, ps) = verdict(rig(goodUid, goodUid), 9.0e-3, 1.0e-3)
      check dn > 3.0
      check ps > 3.0

    test "a UID the controller did not expect fails, and says so as a verdict":
      # The same run in every respect except the sixteen bytes in the target's
      # identification page. `done` must still rise -- the exchange itself was
      # fine -- while `pass` must not.
      let (dn, ps) = verdict(rig("deadbeef0000000000000000000000ff", goodUid),
                             9.0e-3, 1.0e-3)
      check dn > 3.0
      check ps < 0.3

    test "the write cycle is real: a part that stays busy is never written":
      # `tw` far beyond the run, so every acknowledge poll is NACKed until the
      # budget runs out. Without a genuine busy period the write would appear
      # to succeed immediately and this would pass, which is the point of it.
      let (dn, ps) = verdict(rig(goodUid, goodUid, tw = 50.0e-3,
                                 pollLimit = 10), 5.0e-3, 1.0e-3)
      check dn > 3.0
      check ps < 0.3

    test "a page write past the end of its page wraps to the start of it":
      # Thirty-six bytes from offset 16 of a 32-byte page. Bytes 0..15 land at
      # offsets 16..31, bytes 16..31 wrap to offsets 0..15, and bytes 32..35
      # overwrite offsets 16..19 -- the page pointer's low five bits roll over
      # and the rest of the address does not advance. The expectation is
      # computed here rather than by the controller, so the check is against
      # the datasheet's behaviour and not against the model's own idea of it.
      var wr = ""
      var page = newSeq[int](32)
      for i in 0 ..< 32: page[i] = 0xFF
      var off = 16
      for i in 0 ..< 36:
        let b = 0x40 + i
        wr.add toHex(b, 2).toLowerAscii
        page[off] = b
        off = (off + 1) mod 32
      var rb = ""
      for b in page: rb.add toHex(b, 2).toLowerAscii

      let (dn, ps) = verdict(
        rig(goodUid, goodUid, wrAddr = 16, wrData = wr,
            rbAddr = 0, rbData = rb), 14.5e-3, 1.0e-3)
      check dn > 3.0
      check ps > 3.0

    test "an expectation that ignores the wrap is rejected":
      # The same write, read back against what a part with no in-page wrap
      # would have left behind. If this passed, the case above would be
      # measuring nothing.
      var wr = ""
      for i in 0 ..< 36: wr.add toHex(0x40 + i, 2).toLowerAscii
      var rb = ""
      for i in 0 ..< 16: rb.add "ff"
      for i in 0 ..< 16: rb.add toHex(0x40 + i, 2).toLowerAscii

      let (dn, ps) = verdict(
        rig(goodUid, goodUid, wrAddr = 16, wrData = wr,
            rbAddr = 0, rbData = rb), 14.5e-3, 1.0e-3)
      check dn > 3.0
      check ps < 0.3
