import std/[os, osproc, strutils, tables, tempfiles, unittest]

import verax/netlist/types
import verax/netlist/graph
import verax/spice/ngspice
import verax/spice/xspice
import verax/spice/xspice/build

## Event-driven (digital) code models; needs an ngspice source tree.
##
## The raw-text deck pins the waveform precisely. The final test builds the
## same mixed-signal circuit through `netlist/graph` with vector-port
## bridges; `dac_bridge` makes `q` visible in the rawfile.

let repoRoot = currentSourcePath().parentDir.parentDir
let ngsSrc = getEnv("NGSPICE_SRC")
let haveToolchain =
  findExe("ngspice").len > 0 and ngsSrc.len > 0 and
  fileExists(ngsSrc / "src" / "xspice" / "icm" / "dlmain.c") and
  fileExists(ngsSrc / "src" / "include" / "ngspice" / "config.h")

const deckTemplate = """* nim d flip-flop
Vclk clk_a 0 PULSE(0 1 10u 1n 1n 10u 20u)
Vdat dat_a 0 PULSE(0 1 5u 1n 1n 30u 60u)
abridge1 [clk_a dat_a] [clk_d dat_d] adc
.model adc adc_bridge(in_low=0.3 in_high=0.7)
adff dat_d clk_d q_d dffmod
.model dffmod nimdff(clk_delay=$2 ic=$3)
abridge2 [q_d] [q_a] dac
.model dac dac_bridge(out_low=0 out_high=1 t_rise=1n t_fall=1n)
R1 q_a 0 1meg
.control
pre_codemodel $1
set num_threads=1
tran 1u 100u
print v(q_a)
.endc
.end
"""

type Edge = tuple[time: float, level: int]

proc qEdges(cm, clkDelay, ic: string): (int, seq[Edge]) =
  ## Run the deck and return q's initial level plus every transition.
  let bd = createTempDir("verax_dff_", "")
  defer: removeDir(bd)
  writeFile(bd / "t.cir", deckTemplate % [cm, clkDelay, ic])
  let (output, _) = execCmdEx(quoteShellCommand(@["ngspice", "-b", "t.cir"]),
                              workingDir = bd)
  var edges: seq[Edge]
  var first = -1
  var prev = 0
  for line in output.splitLines:
    let f = line.splitWhitespace
    if f.len < 3 or not f[0].allCharsInSet({'0'..'9'}): continue
    let t = parseFloat(f[1])
    let level = (if parseFloat(f[2]) > 0.5: 1 else: 0)
    if first < 0:
      first = level
      prev = level
      continue
    if level != prev:
      edges.add (t, level)
      prev = level
  if first < 0:
    raise newException(ValueError, "no data rows in ngspice output:\n" & output)
  (first, edges)

if not haveToolchain:
  echo "SKIP: NGSPICE_SRC not set to a configured ngspice source tree, " &
       "skipping digital code model tests"
else:
  let outDir = createTempDir("verax_dffbuild_", "")
  let cm = deckSafeCmPath(buildCodeModel(repoRoot / "examples" / "xspice_dff.nim",
                                         outDir / "dff.cm"))

  test "an event-driven model builds into a .cm":
    check fileExists(cm)

  test "q samples data on rising clock edges":
    # Clock rises at 10/30/50/70/90us, data high 5-35us and 65-95us, so q
    # goes 1,1,0,1,1: transitions at 10, 50 and 70us only.
    let (first, edges) = qEdges(cm, "1n", "0")
    check first == 0
    check edges.len == 3
    check abs(edges[0].time - 10e-6) < 0.5e-6
    check edges[0].level == 1
    check abs(edges[1].time - 50e-6) < 0.5e-6
    check edges[1].level == 0
    check abs(edges[2].time - 70e-6) < 0.5e-6
    check edges[2].level == 1

  test "no event is emitted when the sampled value is unchanged":
    # The 30us and 90us edges sample the value q holds; `outputChanged(q) =
    # false` suppresses those events.
    let (_, edges) = qEdges(cm, "1n", "0")
    for e in edges:
      check abs(e.time - 30e-6) > 1e-6
      check abs(e.time - 90e-6) > 1e-6

  test "clk_delay shifts every output event by the same amount":
    let (_, fast) = qEdges(cm, "1n", "0")
    let (_, slow) = qEdges(cm, "2u", "0")
    check fast.len == slow.len
    for i in 0 ..< fast.len:
      check abs((slow[i].time - fast[i].time) - 2e-6) < 0.2e-6

  test "the ic parameter sets the output state before the first clock":
    let (first0, _) = qEdges(cm, "1n", "0")
    let (first1, edges1) = qEdges(cm, "1n", "1")
    check first0 == 0
    check first1 == 1
    # Starting high, the first transition is at 50us.
    check edges1.len == 2
    check abs(edges1[0].time - 50e-6) < 0.5e-6

  test "a whole mixed-signal deck can be built through netlist/graph":
    # Both bridges have vector ports at both ends (`[a b]`).
    proc bridge(name: string, inT, outT: PortType,
                params: openArray[string]): ModelSpec =
      result = ModelSpec(name: name, cFunction: "cm_" & name,
        ports: @[
          PortSpec(name: "in", dir: xdIn, default: inT, allowed: @[inT], vector: true),
          PortSpec(name: "out", dir: xdOut, default: outT, allowed: @[outT], vector: true)])
      for p in params:
        result.params.add ParamSpec(name: p, dataType: xtReal, default: "0.0",
                                    nullAllowed: true)
    let dff = ModelSpec(name: "nimdff", cFunction: "cm_nimdff",
      ports: @[
        PortSpec(name: "d", dir: xdIn, default: xpD, allowed: @[xpD]),
        PortSpec(name: "clk", dir: xdIn, default: xpD, allowed: @[xpD]),
        PortSpec(name: "q", dir: xdOut, default: xpD, allowed: @[xpD])],
      params: @[
        ParamSpec(name: "clk_delay", dataType: xtReal, default: "1e-9", nullAllowed: true),
        ParamSpec(name: "ic", dataType: xtInt, default: "0", nullAllowed: true)])

    let nl = newNetlist("mixed")
    let gnd = addNet(nl, Net(name: "0", kind: ntGround))
    var n: Table[string, Net]
    for name in ["clk_a", "dat_a", "clk_d", "dat_d", "q_d", "q_a"]:
      n[name] = addNet(nl, Net(name: name))

    for (des, net, spec) in [("Vclk", "clk_a", "PULSE(0 1 10u 1n 1n 10u 20u)"),
                             ("Vdat", "dat_a", "PULSE(0 1 5u 1n 1n 30u 60u)")]:
      let v = addComponent(nl, Component(designator: des, kind: "voltage_source"))
      v.attrs["value"] = spec
      discard connect(v, "+", n[net])
      discard connect(v, "-", gnd)

    discard addCodeModelInstance(nl, "abridge1", bridge("adc_bridge", xpV, xpD, ["in_low", "in_high"]),
      [wire([n["clk_a"], n["dat_a"]]), wire([n["clk_d"], n["dat_d"]])],
      {"in_low": "0.3", "in_high": "0.7"}, modelName = "adc")
    discard addCodeModelInstance(nl, "adff", dff,
      [wire(n["dat_d"]), wire(n["clk_d"]), wire(n["q_d"])],
      {"clk_delay": "1n", "ic": "0"}, modelName = "dffmod")
    discard addCodeModelInstance(nl, "abridge2", bridge("dac_bridge", xpD, xpV, ["out_low", "out_high", "t_rise", "t_fall"]),
      [wire([n["q_d"]]), wire([n["q_a"]])],
      {"out_low": "0", "out_high": "1", "t_rise": "1n", "t_fall": "1n"},
      modelName = "dac")

    let r1 = addComponent(nl, Component(designator: "R1", kind: "resistor"))
    r1.attrs["value"] = "1meg"
    discard connect(r1, "1", n["q_a"])
    discard connect(r1, "2", gnd)

    let res = run(nl, @[".tran 1u 100u"], codemodels = @[cm])
    let q = res["v(q_a)"]
    let t = res["time"]
    var edges: seq[float]
    for i in 1 ..< q.len:
      if (q[i] > 0.5) != (q[i - 1] > 0.5): edges.add t[i]
    check edges.len == 3
    check abs(edges[0] - 10e-6) < 0.5e-6
    check abs(edges[1] - 50e-6) < 0.5e-6
    check abs(edges[2] - 70e-6) < 0.5e-6

  removeDir(outDir)
