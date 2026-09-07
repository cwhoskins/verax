## The verify-level run archive: `runFULL` pictures and JSON scenes of the
## *authored* design.
##
## `spice/ngspice.run` already writes per-run `runNNN.svg`/`runNNN.json` of
## the derived fragment it simulated; `tests/test_spice_keep.nim` and
## `tests/test_schematic.nim` pin those. The one picture those never contain
## is the circuit the author actually wrote, so `verify` writes `runFULL.svg`
## and its `runFULL.json` scene once, overwritten every check, *before*
## `readiness` runs any fragment -- each pair from the same routed scene.
##
## The properties worth pinning here are: the files exist even when no
## simulation runs (so they are gated on the archive, not on a run); they are
## overwritten rather than slotted; and they take no `index.txt` row -- the
## index names one analysis run per row, and these pictures are not runs.
##
## One property -- that a *derived* simulation fragment's `run000` archive
## routes cleanly rather than degrading to dashed fallback markers -- lives
## behind `-d:slowTests`: it costs ~140s, almost all of it one `layout()` of
## the op-substituted fragment (`schematic.layout()` is superlinear), not the
## simulation. Run it with
##   nim c -r --path:./src -d:slowTests tests/test_verify_keep.nim

import std/[json, os, strutils, tempfiles, unittest]

import verax/contract/dsl
import verax/schematic
import verax/verify

import designs/lib/riaa

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

proc namedGain(value: string): Netlist =
  ## Deliberately shares a subcircuit name while changing its rendered scene.
  subckt("GAIN_BLOCK", [IN, OUT]):
    net IN, kind = ntSignal
    net OUT, kind = ntSignal
    component R1, kind = "resistor", value = value:
      pin "1", IN, kind = ptPassive
      pin "2", OUT, kind = ptPassive

proc leaf(value: string): Netlist =
  subckt("LEAF", [IN, OUT]):
    net IN, kind = ntSignal
    net OUT, kind = ntSignal
    component R1, kind = "resistor", value = value:
      pin "1", IN, kind = ptPassive
      pin "2", OUT, kind = ptPassive

proc parentWithLeaf(value: string): Netlist =
  ## Its own sheet is unchanged; only its descendant's resolved target varies.
  subckt("PARENT", [IN, OUT]):
    net IN, kind = ntSignal
    net OUT, kind = ntSignal
    instance X1, leaf(value), [IN, OUT]

proc sameNameVariantBoard(): Design =
  design("same_name_variants"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    net c, kind = ntSignal
    net d, kind = ntSignal
    instance XA, namedGain("1k"), [a, b]
    instance XB, namedGain("2k"), [c, d]

proc descendantVariantBoard(): Design =
  design("descendant_variants"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    net c, kind = ntSignal
    net d, kind = ntSignal
    instance XA, parentWithLeaf("1k"), [a, b]
    instance XB, parentWithLeaf("2k"), [c, d]

proc slashNamedBlock(): Netlist =
  subckt("A/B", [IN, OUT]):
    net IN, kind = ntSignal
    net OUT, kind = ntSignal
    component R1, kind = "resistor", value = "1k":
      pin "1", IN, kind = ptPassive
      pin "2", OUT, kind = ptPassive

proc underscoreNamedBlock(): Netlist =
  subckt("A_B", [IN, OUT]):
    net IN, kind = ntSignal
    net OUT, kind = ntSignal
    component R1, kind = "resistor", value = "1k":
      pin "1", IN, kind = ptPassive
      pin "2", OUT, kind = ptPassive

proc safeNameCollisionBoard(): Design =
  design("safe_name_collision"):
    net a, kind = ntSignal
    net b, kind = ntSignal
    net c, kind = ntSignal
    net d, kind = ntSignal
    instance XA, slashNamedBlock(), [a, b]
    instance XB, underscoreNamedBlock(), [c, d]

proc riaaBoard(): Design =
  ## The real stereo RIAA design (`designs/riaa_preamp.nim`) rebuilt here so a
  ## test can drive `verify` in-process: the same two `riaaChannel()`
  ## instances, supplies and claims. Its first simulation run is the
  ## `run000.svg` operating-point fragment the foreign escape-seed protection
  ## must not change into new fallback markers.
  design("riaa_preamp"):
    net gnd, kind = ntGround, name = "0", global = true
    net vp, kind = ntPower:
      spec:
        voltage = 15.0.V
    net vn, kind = ntPower:
      spec:
        voltage = -15.0.V

    net inL,  kind = ntSignal
    net outL, kind = ntSignal
    net inR,  kind = ntSignal
    net outR, kind = ntSignal

    component V1, kind = "voltage_source", value = "DC 15":
      pin "+", vp, kind = ptPower
      pin "-", gnd, kind = ptGround
      spec:
        voltage = 15.0.V
    component V2, kind = "voltage_source", value = "DC -15":
      pin "+", vn, kind = ptPower
      pin "-", gnd, kind = ptGround
      spec:
        voltage = -15.0.V

    component C1, kind = "capacitor", value = "220u":
      pin "1", vp, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "electrolytic"
        esr = 150.mohm
        esl = 6.nH
    component C2, kind = "capacitor", value = "220u":
      pin "1", vn, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      spec:
        package = "electrolytic"
        esr = 150.mohm
        esl = 6.nH

    instance XL, riaaChannel(), [inL, outL, vp, vn, gnd]
    instance XR, riaaChannel(), [inR, outR, vp, vn, gnd]

    role "power_rail", pos, rail = vp, voltage = 15.0.V, band = 5.pct,
         targetZ = 500.mohm, targetFrom = 100.kHz, targetTo = 10.MHz
    role "power_rail", neg, rail = vn, voltage = -15.0.V, band = 5.pct

    role "gain_stage", left, opamp = XL.innerComponent("U1"),
         input = inL, output = outL,
         atF = 1.kHz, minGain = 39.0.dB, maxGain = 40.5.dB
    role "gain_stage", right, opamp = XR.innerComponent("U1"),
         input = inR, output = outR,
         atF = 1.kHz, minGain = 39.0.dB, maxGain = 40.5.dB

    role "channel_match", stereo, a = roleRef("left"), b = roleRef("right"),
         fFrom = 20.Hz, fTo = 20.kHz, maxGainDelta = 0.5.dB

test "runFULL.svg and its json scene are written before readiness, even with no simulation":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(bareBoard(), offlineCapabilities)

  check fileExists(dir / "runFULL.svg")
  check fileExists(dir / "runFULL.json")
  # No fragment ran, so no slot was taken and no index row was written.
  check not fileExists(dir / "run000.svg")
  check not fileExists(dir / "run000.json")
  check not fileExists(dir / "index.txt")

  let svg = readFile(dir / "runFULL.svg")
  check svg.startsWith("<?xml")
  check ">R1</text>" in svg

  # The JSON is the public scene of the very netlist `verify` laid out, not a
  # second layout: byte-for-byte what `sceneToJsonString` produces for it.
  check readFile(dir / "runFULL.json") == sceneToJsonString(bareBoard().netlist)

test "a subcircuit gets its own runFULL.<name> svg+json sheet, deduped by name":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(twoChannelBoard(), offlineCapabilities)

  check fileExists(dir / "runFULL.svg")
  check fileExists(dir / "runFULL.json")
  # GAIN_BLOCK is instantiated twice but drawn once.
  check fileExists(dir / "runFULL.GAIN_BLOCK.svg")
  check fileExists(dir / "runFULL.GAIN_BLOCK.json")
  check not fileExists(dir / "runFULL.XL.svg")
  check not fileExists(dir / "runFULL.XL.json")
  check not fileExists(dir / "runFULL.XR.svg")
  check not fileExists(dir / "runFULL.XR.json")

  # The child sheet shows the block's own interface as ports.
  let child = readFile(dir / "runFULL.GAIN_BLOCK.svg")
  check "<polygon" in child
  check ">IN</text>" in child
  check ">OUT</text>" in child

  # Its JSON scene carries the same two ports.
  let childScene = parseJson(readFile(dir / "runFULL.GAIN_BLOCK.json"))
  check childScene["title"].getStr == "GAIN_BLOCK"
  check childScene["ports"].len == 2

  # No index row for any of the pictures.
  check not fileExists(dir / "index.txt")

test "runFULL.html is a self-contained hierarchy browser linking blocks to sheets":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(twoChannelBoard(), offlineCapabilities)

  check fileExists(dir / "runFULL.html")
  let html = readFile(dir / "runFULL.html")
  # Self-contained: no external stylesheet, script or image reference.
  check "<script>" in html
  check "src=" notin html
  check "<link" notin html

  # The embedded model carries both sheets and wires each instance of the
  # block to the one deduplicated child sheet.
  let modelStart = html.find("const MODEL = ") + "const MODEL = ".len
  let modelEnd = html.find(";\n", modelStart)
  let model = parseJson(html[modelStart ..< modelEnd])
  check model["root"].getStr == "@root"
  check model["sheets"].hasKey("@root")
  check model["sheets"].hasKey("GAIN_BLOCK")

  var linked: seq[string]
  for p in model["sheets"]["@root"]["parts"]:
    if p["child"].kind != JNull:
      linked.add p["child"].getStr
  check linked == @["GAIN_BLOCK", "GAIN_BLOCK"]   # XL and XR both descend

  # The child sheet's parts have no further hierarchy to descend into.
  for p in model["sheets"]["GAIN_BLOCK"]["parts"]:
    check p["child"].kind == JNull

  # Each sheet inlines its SVG with the XML prolog stripped (invalid mid-HTML).
  check model["sheets"]["@root"]["svg"].getStr.startsWith("<svg")

test "same-named children get distinct sheets when their rendered scenes differ":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(sameNameVariantBoard(), offlineCapabilities)

  # The first occurrence keeps the legacy name; later non-equivalent ones are
  # suffixed, both on disk and in the hierarchy browser.
  check fileExists(dir / "runFULL.GAIN_BLOCK.svg")
  check fileExists(dir / "runFULL.GAIN_BLOCK.2.svg")
  let html = readFile(dir / "runFULL.html")
  let modelStart = html.find("const MODEL = ") + "const MODEL = ".len
  let modelEnd = html.find(";\n", modelStart)
  let model = parseJson(html[modelStart ..< modelEnd])
  var linked: seq[string]
  for p in model["sheets"]["@root"]["parts"]:
    if p["child"].kind != JNull: linked.add p["child"].getStr
  check linked == @["GAIN_BLOCK", "GAIN_BLOCK.2"]

test "same-named parents split when their resolved descendants differ":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(descendantVariantBoard(), offlineCapabilities)

  check fileExists(dir / "runFULL.LEAF.svg")
  check fileExists(dir / "runFULL.LEAF.2.svg")
  check fileExists(dir / "runFULL.PARENT.svg")
  check fileExists(dir / "runFULL.PARENT.2.svg")
  let html = readFile(dir / "runFULL.html")
  let modelStart = html.find("const MODEL = ") + "const MODEL = ".len
  let modelEnd = html.find(";\n", modelStart)
  let model = parseJson(html[modelStart ..< modelEnd])
  check model["sheets"]["PARENT"]["parts"][0]["child"].getStr == "LEAF"
  check model["sheets"]["PARENT.2"]["parts"][0]["child"].getStr == "LEAF.2"

test "sanitized child-name collisions also receive globally unique IDs":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(safeNameCollisionBoard(), offlineCapabilities)

  check fileExists(dir / "runFULL.A_B.svg")
  check fileExists(dir / "runFULL.A_B.2.svg")

test "the archive uses the constrained layout selected through the environment":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  var options = defaultLayoutOptions()
  options.policy = lpConstrainedLayered
  withEnv("VERAX_KEEP_RUNS", dir):
    withEnv("VERAX_SCHEMATIC_LAYOUT", "constrained-layered"):
      discard verify(twoChannelBoard(), offlineCapabilities)

  check readFile(dir / "runFULL.json") ==
        sceneToJsonString(layout(twoChannelBoard().netlist, options))
  check readFile(dir / "runFULL.GAIN_BLOCK.json") ==
        sceneToJsonString(layout(gainBlock(), options))

test "a flat design writes only runFULL.svg and runFULL.json":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(bareBoard(), offlineCapabilities)
  check fileExists(dir / "runFULL.svg")
  check fileExists(dir / "runFULL.json")
  for f in walkFiles(dir / "runFULL.*.svg"):
    check false  # no runFULL.<name>.svg for a design with no subcircuits
  for f in walkFiles(dir / "runFULL.*.json"):
    check false  # no runFULL.<name>.json either

test "a child sheet is overwritten, not slotted":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  createDir(dir)
  writeFile(dir / "runFULL.GAIN_BLOCK.svg", "sentinel")
  writeFile(dir / "runFULL.GAIN_BLOCK.json", "sentinel")
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(twoChannelBoard(), offlineCapabilities)
  let child = readFile(dir / "runFULL.GAIN_BLOCK.svg")
  check child.startsWith("<?xml")
  check "sentinel" notin child
  let childScene = readFile(dir / "runFULL.GAIN_BLOCK.json")
  check "sentinel" notin childScene
  check parseJson(childScene).hasKey("parts")

test "runFULL.svg and runFULL.json are overwritten, not appended or slotted":
  let dir = createTempDir("verax_verifykeeptest_", "")
  defer: removeDir(dir)
  createDir(dir)
  writeFile(dir / "runFULL.svg", "sentinel")
  writeFile(dir / "runFULL.json", "sentinel")
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(bareBoard(), offlineCapabilities)

  let svg = readFile(dir / "runFULL.svg")
  check svg.startsWith("<?xml")
  check "sentinel" notin svg
  let scene = readFile(dir / "runFULL.json")
  check "sentinel" notin scene
  check parseJson(scene).hasKey("parts")

suite "runFULL.svg beside the derived runNNN.svg":
  if not haveNgspice:
    echo "  [skipped: ngspice not found on PATH]"
  else:
    test "the authored design and the derived fragment both appear, and only the run is indexed":
      let dir = createTempDir("verax_verifykeeptest_", "")
      defer: removeDir(dir)
      withEnv("VERAX_KEEP_RUNS", dir):
        discard verify(dividerBoard(), allCapabilities)

      check fileExists(dir / "runFULL.svg")
      check fileExists(dir / "runFULL.json")
      check fileExists(dir / "run000.svg")
      check fileExists(dir / "run000.json")
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

    when defined(slowTests):
      test "the real RIAA archive records a fully routed derived sheet":
        # The Hanan grid routes the first derived fragment's op-amp-substitution
        # internal nets, so the archived SVG and JSON must describe real wires,
        # not fallback markers. ~140s, almost all of it one `layout()` of the
        # derived fragment -- hence `-d:slowTests`. The authored-side half of
        # this property is pinned cheaply below, off `{capStatic}`.
        let dir = createTempDir("verax_riaaregress_", "")
        defer: removeDir(dir)
        withEnv("VERAX_KEEP_RUNS", dir):
          discard verify(riaaBoard(), allCapabilities)

        check fileExists(dir / "run000.svg")
        check fileExists(dir / "run000.json")

        # SVG is the rendered archive view: dashed strokes only represent
        # fallback stubs, so their absence says every connection was routed.
        let runSvg = readFile(dir / "run000.svg")
        check runSvg.startsWith("<?xml")
        check "stroke-dasharray=\"6 4\"" notin runSvg

        # JSON is the same routed scene. Require actual wire geometry as well
        # as no fallback records, rather than pinning an incidental wire count.
        let runScene = parseJson(readFile(dir / "run000.json"))
        check runScene["fallbacks"].len == 0
        check runScene["wires"].len > 0
        for wire in runScene["wires"]:
          check wire["points"].len >= 2

test "the RIAA archive keeps a routed authored design and child sheet":
  # The authored-side half of the routed-archive property, off `{capStatic}`
  # so no derived fragment is simulated (~2s rather than ~140s). The full
  # top sheet and the `RIAA_CHANNEL` child sheet both come from the design as
  # written, so they are written even with no run.
  let dir = createTempDir("verax_riaaauthored_", "")
  defer: removeDir(dir)
  withEnv("VERAX_KEEP_RUNS", dir):
    discard verify(riaaBoard(), {capStatic})

  check fileExists(dir / "runFULL.svg")
  check fileExists(dir / "runFULL.json")
  check fileExists(dir / "runFULL.RIAA_CHANNEL.svg")
  check fileExists(dir / "runFULL.RIAA_CHANNEL.json")

  # The authored child archive routes cleanly and preserves its semantic
  # IN/OUT interface ports.
  let child = readFile(dir / "runFULL.RIAA_CHANNEL.svg")
  check child.startsWith("<?xml")
  check "stroke-dasharray=\"6 4\"" notin child
  let childScene = parseJson(readFile(dir / "runFULL.RIAA_CHANNEL.json"))
  check childScene["fallbacks"].len == 0
  var portNames: seq[string]
  for port in childScene["ports"]:
    portNames.add port["name"].getStr
  check portNames == @["IN", "OUT"]
