import std/[math, os, osproc, strutils, tables, tempfiles, unittest]

import verax/netlist/types
import verax/netlist/graph
import verax/spice/ngspice
import verax/spice/xspice
import verax/spice/xspice/build
import verax/spice/xspice/instance

## Building a `.cm` needs a configured ngspice source tree; skipped without
## one.

let repoRoot = currentSourcePath().parentDir.parentDir
let ngsSrc = getEnv("NGSPICE_SRC")
let haveToolchain =
  findExe("ngspice").len > 0 and ngsSrc.len > 0 and
  fileExists(ngsSrc / "src" / "xspice" / "icm" / "dlmain.c") and
  fileExists(ngsSrc / "src" / "include" / "ngspice" / "config.h")

proc opVoltage(cmPath, deck: string): float =
  ## Run a deck that prints `v(vout)` and return it.
  let bd = createTempDir("verax_xsim_", "")
  defer: removeDir(bd)
  writeFile(bd / "t.cir", deck % [cmPath])
  let (output, _) = execCmdEx(quoteShellCommand(@["ngspice", "-b", "t.cir"]),
                              workingDir = bd)
  for line in output.splitLines:
    if line.startsWith("v(vout)"):
      return parseFloat(line.split('=')[1].strip)
  raise newException(ValueError, "no v(vout) in ngspice output:\n" & output)

const deckTemplate = """* verax xspice build test
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
    # Undetectable from `ngspice -v`, and the resulting segfault says
    # nothing, so a missing CIDER always warns.
    let warnings = tc.checkAbi()
    if "CIDER" notin tc.configFlags:
      check warnings.len > 0
      check "CIDER" in warnings.join(" ")

  # Built once at module scope: `defer` in unittest's `test` doesn't scope
  # as it reads.
  let outDir = createTempDir("verax_xbuild_", "")
  let cm = buildCodeModel(repoRoot / "examples" / "xspice_gain.nim",
                          outDir / "gain.cm", tc)

  test "buildCodeModel turns a DSL model source into a loadable .cm":
    check fileExists(cm)
    # The model function is private and reached through the SPICEdev table,
    # so cmDEVices is the export.
    let syms = execCmdEx(quoteShellCommand(@["nm", "-D", cm])).output
    check "cmDEVices" in syms
    check "cm_nimgain_info" in syms

  test "a mixed-case .cm path is made deck-safe (ngspice case-folds deck lines)":
    let safe = deckSafeCmPath(cm)
    check safe == safe.toLowerAscii
    check fileExists(safe)

  test "the built .cm loads in ngspice and computes gain*(in+offset)":
    # 2.0 * (3.0 + 0.5): the offset proves both parameters arrive.
    check abs(opVoltage(deckSafeCmPath(cm), deckTemplate) - 7.0) < 1e-6

  test "author, build, instantiate and simulate, all from verax":
    # Must mirror examples/xspice_gain.nim; drift shows as a model-resolution
    # error.
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

    # A lone XSPICE analog output can be singular; give it a DC path.
    let r1 = addComponent(nl, Component(designator: "R1", kind: "resistor"))
    r1.attrs["value"] = "1meg"
    discard connect(r1, "1", vout)
    discard connect(r1, "2", gnd)

    let res = run(nl, @[".op"], codemodels = @[cm])
    check abs(res["v(vout)"][0] - 7.0) < 1e-6

  test "analog state, integration and breakpoints round-trip through a .cm":
    # Continuous-time with memory: `analogAlloc`/`analogVar` roll back with a
    # rejected timepoint, `analogIntegrate` uses the simulator's method, and
    # `setPermBkpt` forces timepoints. Checked against a closed form.
    let intCm = buildCodeModel(repoRoot / "examples" / "xspice_integrator.nim",
                               outDir / "nimint.cm")
    let spec = ModelSpec(
      name: "nimint", cFunction: "cm_nimint",
      ports: @[
        PortSpec(name: "inp", dir: xdIn, default: xpV, allowed: @[xpV]),
        PortSpec(name: "outp", dir: xdOut, default: xpV, allowed: @[xpV])],
      params: @[
        ParamSpec(name: "gain", dataType: xtReal, default: "1.0", nullAllowed: true),
        ParamSpec(name: "out_ic", dataType: xtReal, default: "0.0", nullAllowed: true),
        ParamSpec(name: "tsample", dataType: xtReal, default: "0.0", nullAllowed: true)])

    let nl = newNetlist("xspice_integrator")
    let gnd = addNet(nl, Net(name: "0", kind: ntGround))
    let vin = addNet(nl, Net(name: "vin"))
    let vout = addNet(nl, Net(name: "vout"))
    let v1 = addComponent(nl, Component(designator: "V1", kind: "voltage_source"))
    v1.attrs["value"] = "DC 2"
    discard connect(v1, "+", vin)
    discard connect(v1, "-", gnd)
    discard addCodeModelInstance(nl, "a1", spec, [vin, vout],
                                 {"gain": "1000.0", "tsample": "1e-4"})
    let r1 = addComponent(nl, Component(designator: "R1", kind: "resistor"))
    r1.attrs["value"] = "1meg"
    discard connect(r1, "1", vout)
    discard connect(r1, "2", gnd)

    let res = run(nl, @[".tran 1u 1m"], codemodels = @[intCm])
    let t = res["time"]
    let v = res["v(vout)"]
    # 2000 * t at every sample, not just the end.
    check abs(v[0]) < 1e-9
    for i in 0 ..< t.len:
      check abs(v[i] - 2000.0 * t[i]) < 1e-6
    # `tsample` forces a timepoint every 100 us.
    var onGrid = 0
    for x in t:
      if abs(x / 1.0e-4 - round(x / 1.0e-4)) * 1.0e-4 < 1.0e-12: inc onGrid
    check onGrid >= 10

  test "run() rejects a code model path that does not exist":
    let nl = newNetlist("bad")
    expect(SpiceSimError):
      discard run(nl, @[".op"], codemodels = @["/nonexistent/nope.cm"])

  removeDir(outDir)
