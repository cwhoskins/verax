import std/[tables, unittest]

import verax/fem

test "newFemProblem sets the kind and a room-temperature ambient":
  let em = newFemProblem("cap", pkElectrostatic)
  check em.kind == pkElectrostatic
  check em.kind.isElectromagnetic
  let th = newFemProblem("spread", pkThermalSteady)
  check th.kind.isThermal
  check abs(th.ambient - 293.15) < 1e-6

test "addRegion refuses an unregistered material or a degenerate z-extent":
  var p = newFemProblem("x", pkThermalSteady)
  expect FemError:
    p.addRegion(Region(name: "r", material: "copper", zLow: 0.0, zHigh: 1e-3))
  p.addMaterial(Material(name: "copper", kThermal: 385.0))
  expect FemError:
    p.addRegion(Region(name: "r", material: "copper", zLow: 1e-3, zHigh: 1e-3))
  p.addRegion(Region(name: "r", material: "copper", zLow: 0.0, zHigh: 1e-3))
  check p.regions.len == 1

test "validate returns warnings, it does not raise":
  var p = newFemProblem("fw", pkFullWave)      # no frequencies, no regions
  let w = p.validate()
  check w.len >= 2
  check "full-wave problem has no frequency points" in w

test "reading a real field as complex raises, not returns garbage":
  var r = FemResult(problemName: "t")
  var f = newField("T", fkTemperature, complexValued = false)
  f.values = @[300.0, 310.0, 320.0]
  r.fields["T"] = f
  check r["T"] == @[300.0, 310.0, 320.0]
  check r.mag("T") == @[300.0, 310.0, 320.0]
  expect FemSolveError:
    discard r.cplx("T")
