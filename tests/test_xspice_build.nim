import std/[os, osproc, strutils, tables, tempfiles, unittest]

import nimcir/netlist/types
import nimcir/netlist/graph
import nimcir/spice/ngspice
import nimcir/spice/xspice
import nimcir/spice/xspice/build
import nimcir/spice/xspice/instance

## Building a `.cm` needs a *configured* ngspice source tree, which a distro
## `-devel` package does not provide. Gated the same way `test_spice_ngspice`
## gates on the `ngspice` binary, so a machine without one skips rather than
## fails.

let repoRoot = currentSourcePath().parentDir.parentDir
let ngsSrc = getEnv("NGSPICE_SRC")
let haveToolchain =
  findExe("ngspice").len > 0 and ngsSrc.len > 0 and
  fileExists(ngsSrc / "src" / "xspice" / "icm" / "dlmain.c") and
  fileExists(ngsSrc / "src" / "include" / "ngspice" / "config.h")

proc opVoltage(cmPath, deck: string): float =
  ## Run a deck that prints `v(vout)` and return it.
  let bd = createTempDir("nimcir_xsim_", "")
  defer: removeDir(bd)
  writeFile(bd / "t.cir", deck % [cmPath])
  let (output, _) = execCmdEx(quoteShellCommand(@["ngspice", "-b", "t.cir"]),
                              workingDir = bd)
  for line in output.splitLines:
    if line.startsWith("v(vout)"):
      return parseFloat(line.split('=')[1].strip)
  raise newException(ValueError, "no v(vout) in ngspice output:\n" & output)

const deckTemplate = """* nimcir xspice build test
V1 vin 0 DC 3
a1 vin vout g1
R1 vout 0 1meg
.model g1 nimgain(gain=2.0 in_offset=0.5)
.control
pre_codemodel $1
set num_threads=1
op
print v(vout)
.endc
.end
"""

if not haveToolchain:
  echo "SKIP: NGSPICE_SRC not set to a configured ngspice source tree, " &
       "skipping .cm build tests"
else:
  let tc = findToolchain()

  test "the toolchain resolves to a usable cmpp and a configured tree":
    check fileExists(tc.cmpp)
    check tc.ngspiceSrc.len > 0
    check fileExists(tc.ngspiceBuild / "src" / "include" / "ngspice" / "config.h")

  test "XSPICE is enabled in the tree, and the layout flags are readable":
    let flags = tc.configFlags
    check "XSPICE" in flags

  test "checkAbi warns when the tree lacks CIDER":
    # It cannot be detected from `ngspice -v`, so a missing CIDER must always
    # produce a warning rather than a silent pass -- the resulting segfault
    # gives no diagnostic of its own.
    let warnings = tc.checkAbi()
    if "CIDER" notin tc.configFlags:
      check warnings.len > 0
      check "CIDER" in warnings.join(" ")

  # Built once at module scope: `defer` inside unittest's `test` template does
  # not scope the way it reads, and one build is enough for both assertions.
  let outDir = createTempDir("nimcir_xbuild_", "")
  let cm = buildCodeModel(repoRoot / "examples" / "xspice_gain.nim",
                          outDir / "gain.cm", tc)

  test "buildCodeModel turns a DSL model source into a loadable .cm":
    check fileExists(cm)
    # The model function is emitted N_LIB_PRIVATE and reached through the
    # SPICEdev table, so it is cmDEVices that must be exported, not cm_nimgain.
    let syms = execCmdEx(quoteShellCommand(@["nm", "-D", cm])).output
    check "cmDEVices" in syms
    check "cm_nimgain_info" in syms

  test "a mixed-case .cm path is made deck-safe (ngspice case-folds deck lines)":
    let safe = deckSafeCmPath(cm)
    check safe == safe.toLowerAscii
    check fileExists(safe)

  test "the built .cm loads in ngspice and computes gain*(in+offset)":
    # 2.0 * (3.0 + 0.5); a hard-coded gain would still pass a plain 2*vin
    # check, so the offset is what proves both parameters arrive.
    check abs(opVoltage(deckSafeCmPath(cm), deckTemplate) - 7.0) < 1e-6

  test "author, build, instantiate and simulate, all from nimcir":
    # The spec here must mirror examples/xspice_gain.nim; a drift shows up as
    # an ngspice model-resolution error rather than a silent wrong answer.
    let spec = ModelSpec(
      name: "nimgain", cFunction: "cm_nimgain",
      ports: @[
        PortSpec(name: "inp", dir: xdIn, default: xpV, allowed: @[xpV]),
        PortSpec(name: "outp", dir: xdOut, default: xpV, allowed: @[xpV])],
      params: @[
        ParamSpec(name: "gain", dataType: xtReal, default: "1.0", nullAllowed: true),
        ParamSpec(name: "in_offset", dataType: xtReal, default: "0.0", nullAllowed: true)])

    let nl = newNetlist("xspice_e2e")
    let gnd = addNet(nl, Net(name: "0", kind: ntGround))
    let vin = addNet(nl, Net(name: "vin"))
    let vout = addNet(nl, Net(name: "vout"))

    let v1 = addComponent(nl, Component(designator: "V1", kind: "voltage_source"))
    v1.attrs["value"] = "DC 3"
    discard connect(v1, "+", vin)
    discard connect(v1, "-", gnd)

    discard addCodeModelInstance(nl, "a1", spec, [vin, vout],
                                 {"gain": "2.0", "in_offset": "0.5"})

    # An XSPICE analog output with nothing else on it can give ngspice a
    # singular matrix, so give the node a DC path.
    let r1 = addComponent(nl, Component(designator: "R1", kind: "resistor"))
    r1.attrs["value"] = "1meg"
    discard connect(r1, "1", vout)
    discard connect(r1, "2", gnd)

    let res = run(nl, @[".op"], codemodels = @[cm])
    check abs(res["v(vout)"][0] - 7.0) < 1e-6

  test "run() rejects a code model path that does not exist":
    let nl = newNetlist("bad")
    expect(SpiceSimError):
      discard run(nl, @[".op"], codemodels = @["/nonexistent/nope.cm"])

  removeDir(outDir)
