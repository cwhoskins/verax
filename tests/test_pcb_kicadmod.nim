## `formats/kicadmod.nim`: the `.kicad_mod` footprint reader. Skipped when
## `/usr/share/kicad/footprints` is absent; otherwise exercises the real
## library.

import std/[os, unittest]

import verax/pcb/units
import verax/pcb/geometry
import verax/pcb/types
import verax/pcb/footprint
import verax/pcb/formats/kicadmod

const kicadFootprints = "/usr/share/kicad/footprints"

if not dirExists(kicadFootprints):
  echo "SKIP: ", kicadFootprints, " not present, skipping .kicad_mod reader tests"
else:
  test "an SMD 0402 resolves with two roundrect pads at +-0.51 mm":
    let fp = resolveFootprint("Resistor_SMD:R_0402_1005Metric")
    check fp != nil
    check fp.name == "Resistor_SMD:R_0402_1005Metric"
    check fp.mount == mkSmt
    check fp.pads.len == 2
    var byId: array[2, FootprintPad]
    for p in fp.pads:
      check p.padType == ptSmd
      check p.layers == @["F.Cu", "F.Mask", "F.Paste"]
      check p.aperture.kind == akRoundRect
      check abs(toMm(p.aperture.rw) - 0.54) < 1e-9
      check abs(toMm(p.aperture.rh) - 0.64) < 1e-9
    let xs = [toMm(fp.pads[0].at.x), toMm(fp.pads[1].at.x)]
    check (abs(xs[0] - 0.51) < 1e-9 or abs(xs[0] + 0.51) < 1e-9)
    check (abs(xs[1] - 0.51) < 1e-9 or abs(xs[1] + 0.51) < 1e-9)
    check xs[0] != xs[1]

  test "a through-hole header resolves drill diameters and ptThruHole":
    let fp = resolveFootprint(
      "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical")
    check fp != nil
    check fp.mount == mkThroughHole
    check fp.pads.len == 2
    for p in fp.pads:
      check p.padType == ptThruHole
      check toMm(p.drillDia) > 0.0

  test "an unresolvable spec returns nil rather than raising":
    check resolveFootprint("NoSuchLibrary:NoSuchPart") == nil
    check resolveFootprint("") == nil

  test "the Y-flip applies at the boundary: a negative library Y comes back positive":
    # A synthetic footprint with a negative raw Y, testing the Y-down ->
    # Y-up rule directly.
    let body = """(footprint "flip_test"
      (layer "F.Cu")
      (attr smd)
      (pad "1" smd rect (at 0 -1.5) (size 1 1) (layers "F.Cu"))
    )"""
    let tmp = getTempDir() / "verax_kicadmod_flip_test.kicad_mod"
    writeFile(tmp, body)
    defer: removeFile(tmp)
    let fp = readFootprintFile(tmp)
    check fp.pads.len == 1
    check toMm(fp.pads[0].at.y) > 0.0   # library Y was -1.5 (KiCad Y-down)
    check abs(toMm(fp.pads[0].at.y) - 1.5) < 1e-9
