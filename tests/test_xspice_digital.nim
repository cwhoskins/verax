import std/[os, osproc, strutils, tempfiles, unittest]

import nimcir/spice/xspice/build

## Event-driven (digital) code models. Gated the same way as
## `test_xspice_build.nim`, since producing a `.cm` needs an ngspice source
## tree.
##
## The deck here is raw text rather than a nimcir `Netlist`, because driving a
## digital model needs `adc_bridge`/`dac_bridge` from ngspice's stock
## `digital.cm`, and those have **vector** ports (`[a b]`) which
## `xspice/instance.nim` deliberately refuses to emit -- they need the
## bracketed A-device syntax. Converting `q` back to analog via `dac_bridge`
## is also what makes the result visible to a rawfile reader at all.

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
  let bd = createTempDir("nimcir_dff_", "")
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
  let outDir = createTempDir("nimcir_dffbuild_", "")
  let cm = deckSafeCmPath(buildCodeModel(repoRoot / "examples" / "xspice_dff.nim",
                                         outDir / "dff.cm"))

  test "an event-driven model builds into a .cm":
    check fileExists(cm)

  test "q samples data on rising clock edges":
    # Clock rises at 10/30/50/70/90us; data is high 5-35us and 65-95us.
    # So q takes 1,1,0,1,1 -- meaning transitions only at 10, 50 and 70us.
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
    # The clock edges at 30us and 90us sample the value q already holds.
    # Without `outputChanged(q) = false` the model would emit an event at
    # each of them; the edge count above is what proves it does not.
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
    # Starting high, the 10us edge samples data=1, so the first transition is
    # the 50us one.
    check edges1.len == 2
    check abs(edges1[0].time - 50e-6) < 0.5e-6

  removeDir(outDir)
