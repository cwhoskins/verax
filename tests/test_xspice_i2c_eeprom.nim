import std/[os, strutils, unittest]

import verax/contract/dsl
import verax/netlist/graph
import verax/analysis/analyses/transient
import verax/spice/xspice/build

import ../designs/lib/i2c_parts

## The I2C EEPROM protocol end to end on a digital bus.
##
## An analog bus (pull-ups, capacitance, `bidi_bridge`) costs orders of
## magnitude more timepoints. The device models' SDA/SCL are digital `inout`
## either way, so `d_pullup` gives the protocol a fast regression.
##
## Each case fails differently if a distinct piece of the model is wrong,
## and the verdict is shown able to come out low.

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
  ## One MCU, one EEPROM, a digital bus and verdict nets. `xact_done` and
  ## `xact_pass` are analog nets fed by `useDummyMcu`'s `dac_bridge`; the
  ## 100k pull-downs give them a DC path.
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
  # Digital bus: not analog, no bridge.
  digitalBus(d.netlist, [findNet(d.netlist, "sda"), findNet(d.netlist, "scl")])
  d

proc verdict(d: Design, tSettle, tWindow: float): tuple[done, pass: float] =
  ## Both flags from one run, read from `raw`.
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
      # UID read, four-byte write, ACK-poll through the 5 ms cycle, read back.
      let (dn, ps) = verdict(rig(goodUid, goodUid), 9.0e-3, 1.0e-3)
      check dn > 3.0
      check ps > 3.0

    test "a UID the controller did not expect fails, and says so as a verdict":
      # Only the target's ID page differs: `done` rises, `pass` doesn't.
      let (dn, ps) = verdict(rig("deadbeef0000000000000000000000ff", goodUid),
                             9.0e-3, 1.0e-3)
      check dn > 3.0
      check ps < 0.3

    test "the write cycle is real: a part that stays busy is never written":
      # `tw` beyond the run, so every poll is NACKed. Without a real busy
      # period the write would appear to succeed.
      let (dn, ps) = verdict(rig(goodUid, goodUid, tw = 50.0e-3,
                                 pollLimit = 10), 5.0e-3, 1.0e-3)
      check dn > 3.0
      check ps < 0.3

    test "a page write past the end of its page wraps to the start of it":
      # 36 bytes from offset 16 of a 32-byte page: the pointer's low five bits
      # wrap, so bytes 16..31 land at 0..15 and 32..35 overwrite 16..19. The
      # expectation is computed here, from the datasheet, not by the model.
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
      # The same write against a no-wrap expectation must fail, or the case
      # above measures nothing.
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
