import std/[strutils, tables, unittest]

import nimcir/pcb
import nimcir/fem

proc twoLayerBoard(): Pcb =
  ## Two copper layers with a real stack-up (35 um Cu / 1.51 mm FR-4 / 35 um
  ## Cu), one filled area on each and a track on top.
  result = newPcb("demo")
  let top = addLayer(result, newPcbLayer("F.Cu", lfSignal, lsTop))
  let bot = addLayer(result, newPcbLayer("B.Cu", lfSignal, lsBottom))

  discard addStackEntry(result, newStackEntry(seCopper, "F.Cu", um(35.0)))
  discard addStackEntry(result, newStackEntry(seDielectric, "core", mm(1.51)))
  discard addStackEntry(result, newStackEntry(seCopper, "B.Cu", um(35.0)))
  result.stackup.entries[0].layer = top
  result.stackup.entries[2].layer = bot

  discard addCopper(top, newCopper(ckFill,
    fill(rectPolygon(mm(5.0), mm(5.0), pt(mm(2.5), mm(2.5))))))
  discard addCopper(bot, newCopper(ckFill,
    fill(rectPolygon(mm(8.0), mm(8.0), pt(mm(4.0), mm(4.0))))))
  discard addCopper(top, newCopper(ckTrack,
    stroke(polyline([pt(mm(0.5), mm(1.0)), pt(mm(6.0), mm(1.0))]), mm(0.25))))

test "extrudeCopper places each feature in its stack-up z-band":
  let pcb = twoLayerBoard()
  let regs = extrudeCopper(pcb)
  check regs.len == 3

  var topReg, botReg: Region
  for r in regs:
    if r.layer == "F.Cu" and topReg.name.len == 0: topReg = r
    if r.layer == "B.Cu": botReg = r

  check abs((topReg.zHigh - topReg.zLow) - 35e-6) < 1e-9
  check abs(topReg.zLow) < 1e-12                       # top surface at z = 0
  check abs(botReg.zLow - (35e-6 + 1.51e-3)) < 1e-9
  check abs((botReg.zHigh - botReg.zLow) - 35e-6) < 1e-9

test "a filled area keeps its real outline; a track falls back to its box":
  let pcb = twoLayerBoard()
  let regs = extrudeCopper(pcb)
  for r in regs:
    check r.outline.len >= 4

test "problemFromPcb assembles regions and both materials":
  let pcb = twoLayerBoard()
  let p = problemFromPcb(pcb, pkElectrostatic)
  check p.materials.hasKey("copper")
  check p.materials.hasKey("FR4")
  check p.regions.len >= 3
  check p.validate().len == 0        # every region has a known, usable material

test "extrudeZones refuses, and its message names Zone.fills":
  let pcb = twoLayerBoard()
  discard addZone(pcb, newZone("GND_POUR"))
  try:
    discard extrudeZones(pcb)
    check false
  except FemError as e:
    check "Zone.fills" in e.msg
