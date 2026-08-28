## The verify-level run archive: `runFULL.svg` of the *authored* design.
##
## `spice/ngspice.run` already writes a per-run `runNNN.svg` of the derived
## fragment it simulated; `tests/test_spice_keep.nim` and
## `tests/test_schematic.nim` pin those. The one picture those never contain
## is the circuit the author actually wrote, so `verify` writes `runFULL.svg`
## once, overwritten every check, *before* `readiness` runs any fragment.
##
## The properties worth pinning here are: the file exists even when no
## simulation runs (so it is gated on the archive, not on a run); it is
## overwritten rather than slotted; and it takes no `index.txt` row -- the
## index names one analysis run per row, and this picture is not a run.

import std/[os, strutils, tempfiles, unittest]

import nimcir/contract/dsl
import nimcir/verify

let haveNgspice = findExe("ngspice").len > 0

template withEnv(key, value: string, body: untyped) =
  let had = existsEnv(key)
  let old = getEnv(key)
  putEnv(key, value)
  try:
    body
  finally:
    if had: putEnv(key, old) else: delEnv(key)

proc bareBoard(): Design =
  ## A design that claims nothing: offline it runs no simulation at all.
  design("bare"):
    net vdd, kind = ntPower, voltage = "3.3"
    net gnd, kind = ntGround, name = "0"
    component R1, kind = "resistor", value = "10k":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive

proc dividerBoard(): Design =
  ## A 10 V source divided down to a nominal 3.3 V rail, claimed through a
  ## `power_rail` role so `allCapabilities` runs exactly one `.op`.
  design("divider"):
    net vin, kind = ntPower, voltage = "10"
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"

    component V1, kind = "voltage_source", value = "DC 10":
      pin "+", vin, kind = ptPower
      pin "-", gnd, kind = ptGround
    component R1, kind = "resistor", value = "2000":
      pin "1", vin, kind = ptPassive
      pin "2", vdd, kind = ptPassive
    component R2, kind = "resistor", value = "1000":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component U1, kind = "mcu":
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround

    role "power_rail", vdd_rail, rail = vdd, voltage = 3.3.V, band = 5.pct

proc gainBlock(): Netlist =
  ## A trivial one-resistor block with two signal ports, to be instantiated
  ## more than once.
  subckt("GAIN_BLOCK", [IN, OUT]):
    net IN, kind = ntSignal
    net OUT, kind = ntSignal
    component R1, kind = "resistor", value = "1k":
      pin "1", IN, kind = ptPassive
      pin "2", OUT, kind = ptPassive

proc twoChannelBoard(): Design =
  ## One subcircuit instantiated twice -- the stereo shape.
  design("two_channel"):
    net inL, kind = ntSignal
    net inR, kind = ntSignal
    net outL, kind = ntSignal
    net outR, kind = ntSignal
    net gnd, kind = ntGround, name = "0"
    component RTL, kind = "resistor", value = "10k":
      pin "1", outL, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component RTR, kind = "resistor", value = "10k":
      pin "1", outR, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    instance XL, gainBlock(), [inL, outL]
    instance XR, gainBlock(), [inR, outR]

test "runFULL.svg is written before readiness, even with no simulation":
  let dir = createTempDir("nimcir_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("NIMCIR_KEEP_RUNS", dir):
    discard verify(bareBoard(), offlineCapabilities)

  check fileExists(dir / "runFULL.svg")
  # No fragment ran, so no slot was taken and no index row was written.
  check not fileExists(dir / "run000.svg")
  check not fileExists(dir / "index.txt")

  let svg = readFile(dir / "runFULL.svg")
  check svg.startsWith("<?xml")
  check ">R1</text>" in svg

test "a subcircuit gets its own runFULL.<name>.svg sheet, deduped by name":
  let dir = createTempDir("nimcir_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("NIMCIR_KEEP_RUNS", dir):
    discard verify(twoChannelBoard(), offlineCapabilities)

  check fileExists(dir / "runFULL.svg")
  # GAIN_BLOCK is instantiated twice but drawn once.
  check fileExists(dir / "runFULL.GAIN_BLOCK.svg")
  check not fileExists(dir / "runFULL.XL.svg")
  check not fileExists(dir / "runFULL.XR.svg")

  # The child sheet shows the block's own interface as ports.
  let child = readFile(dir / "runFULL.GAIN_BLOCK.svg")
  check "<polygon" in child
  check ">IN</text>" in child
  check ">OUT</text>" in child

  # No index row for any of the pictures.
  check not fileExists(dir / "index.txt")

test "a flat design writes only runFULL.svg":
  let dir = createTempDir("nimcir_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("NIMCIR_KEEP_RUNS", dir):
    discard verify(bareBoard(), offlineCapabilities)
  check fileExists(dir / "runFULL.svg")
  for f in walkFiles(dir / "runFULL.*.svg"):
    check false  # no runFULL.<name>.svg for a design with no subcircuits

test "a child sheet is overwritten, not slotted":
  let dir = createTempDir("nimcir_verifykeeptest_", "")
  defer: removeDir(dir)
  createDir(dir)
  writeFile(dir / "runFULL.GAIN_BLOCK.svg", "sentinel")
  withEnv("NIMCIR_KEEP_RUNS", dir):
    discard verify(twoChannelBoard(), offlineCapabilities)
  let child = readFile(dir / "runFULL.GAIN_BLOCK.svg")
  check child.startsWith("<?xml")
  check "sentinel" notin child

test "runFULL.svg is overwritten, not appended or slotted":
  let dir = createTempDir("nimcir_verifykeeptest_", "")
  defer: removeDir(dir)
  createDir(dir)
  writeFile(dir / "runFULL.svg", "sentinel")
  withEnv("NIMCIR_KEEP_RUNS", dir):
    discard verify(bareBoard(), offlineCapabilities)

  let svg = readFile(dir / "runFULL.svg")
  check svg.startsWith("<?xml")
  check "sentinel" notin svg

suite "runFULL.svg beside the derived runNNN.svg":
  if not haveNgspice:
    echo "  [skipped: ngspice not found on PATH]"
  else:
    test "the authored design and the derived fragment both appear, and only the run is indexed":
      let dir = createTempDir("nimcir_verifykeeptest_", "")
      defer: removeDir(dir)
      withEnv("NIMCIR_KEEP_RUNS", dir):
        discard verify(dividerBoard(), allCapabilities)

      check fileExists(dir / "runFULL.svg")
      check fileExists(dir / "run000.svg")
      check fileExists(dir / "run000.cir")
      check fileExists(dir / "run000.raw")
      check fileExists(dir / "index.txt")

      # The full picture is the design as written: the source, both legs of
      # the divider, and the unmodelled MCU that the simulation must stand in
      # for.
      let full = readFile(dir / "runFULL.svg")
      check ">V1</text>" in full
      check ">R1</text>" in full
      check ">R2</text>" in full
      check ">U1</text>" in full

      # The per-run picture is the derived fragment; it keeps its slot. The
      # MCU is gone there -- `expandPinModels` replaced it with per-pin
      # stand-in resistors before ngspice ran -- which is exactly why the
      # authored picture has to exist alongside it.
      check fileExists(dir / "run000.svg")
      check ">U1</text>" notin readFile(dir / "run000.svg")

      # runFULL is not a run: it takes no slot and no index row.
      let rows = readFile(dir / "index.txt").strip.splitLines
      check rows.len == 2
      check rows[0].startsWith("slot\tstatus")
      check rows[1].split('\t')[0] == "run000"
      for row in rows:
        check "runFULL" notin row
