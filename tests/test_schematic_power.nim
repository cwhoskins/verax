## The separated power/decoupling band (`schematic/power`, `state
## .enforcePowerBand`), the `layout.power` override, and the bypass-bank
## collapse floor in `schematic/arrays.nim`.
##
## The properties worth pinning here: a sheet with no power-classified unit
## is byte-identical whether or not `lsPowerBand` runs; a placement unit
## whose every external net is a rail or ground lands strictly below the
## dashed divider `enforcePowerBand` draws, while an ordinary signal unit
## stays strictly above it; `layout.power` overrides that classification
## either way, per placement unit; and two-or-more identical decoupling caps
## on one rail/ground pair collapse to one badged symbol, while an ordinary
## same-valued pair wired into unrelated roles does not.

import std/[json, tables, unittest]

import verax/netlist
import verax/netlist/dsl
import verax/schematic

proc partOf(s: Schematic, desig: string): SchematicPart =
  for p in s.parts:
    if p.designator == desig: return p
  doAssert false, "no part named " & desig

proc opAmpStage(): Netlist =
  ## A signal stage (an op-amp with a feedback resistor) plus a decoupling
  ## cap and a ferrite bead between two rails -- one signal unit, two power
  ## units, so the band has something on both sides of the divider.
  result = newNetlist("stage")
  let gnd = addNet(result, newNet("0", ntGround))
  let vdd = addNet(result, newNet("vdd", ntPower))
  let vraw = addNet(result, newNet("vraw", ntPower))
  let inp = addNet(result, newNet("in"))
  let outp = addNet(result, newNet("out"))
  let fb = addNet(result, newNet("fb"))

  let u1 = addComponent(result, newComponent("U1", kind = "opamp"))
  discard connect(u1, "IN+", inp, ptInput)
  discard connect(u1, "IN-", fb, ptInput)
  discard connect(u1, "OUT", outp, ptOutput)
  discard connect(u1, "V+", vdd, ptPower)
  discard connect(u1, "V-", gnd, ptGround)

  let rf = addComponent(result, newComponent("RF", kind = "resistor"))
  rf.attrs["value"] = "10k"
  discard connect(rf, "1", outp, ptPassive)
  discard connect(rf, "2", fb, ptPassive)

  let cd = addComponent(result, newComponent("CD", kind = "capacitor"))
  cd.attrs["value"] = "100n"
  discard connect(cd, "1", vdd, ptPassive)
  discard connect(cd, "2", gnd, ptPassive)

  let fbead = addComponent(result, newComponent("FB1", kind = "ferrite_bead"))
  discard connect(fbead, "1", vraw, ptPassive)
  discard connect(fbead, "2", vdd, ptPassive)

proc signalOnly(): Netlist =
  ## No rail or ground at all -- every unit is signal, so the band has
  ## nothing to separate.
  result = newNetlist("signal_only")
  let a = addNet(result, newNet("a"))
  let b = addNet(result, newNet("b"))
  let r1 = addComponent(result, newComponent("R1", kind = "resistor"))
  r1.attrs["value"] = "1k"
  discard connect(r1, "1", a, ptPassive)
  discard connect(r1, "2", b, ptPassive)

proc powerOnly(): Netlist =
  ## Every unit is externally pure-power -- nothing to separate either.
  result = newNetlist("power_only")
  let vdd = addNet(result, newNet("vdd", ntPower))
  let gnd = addNet(result, newNet("0", ntGround))
  let c1 = addComponent(result, newComponent("C1", kind = "capacitor"))
  c1.attrs["value"] = "100n"
  discard connect(c1, "1", vdd, ptPassive)
  discard connect(c1, "2", gnd, ptPassive)

test "a sheet with no power-classified unit draws no divider, byte-identical to lsPowerBand off":
  for nl in [signalOnly(), powerOnly()]:
    let s = layout(nl)
    check s.dividers.len == 0
    var opts = defaultLayoutOptions()
    opts.stages.excl lsPowerBand
    check sceneToJsonString(layout(nl, opts)) == sceneToJsonString(s)

test "a decoupling cap and a rail-to-rail ferrite bead land below the divider; the signal stage stays above":
  let s = layout(opAmpStage())
  check s.dividers.len == 1
  let divY = s.dividers[0].y
  check partOf(s, "U1").y < divY
  check partOf(s, "RF").y < divY
  check partOf(s, "CD").y > divY
  check partOf(s, "FB1").y > divY

test "layout.power overrides classification, either direction":
  let nl = netlist("override"):
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    net sig, kind = ntSignal
    component U1, kind = "mcu":
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
      pin "IO", sig, kind = ptOutput
    component R1, kind = "resistor", value = "10k":
      pin "1", sig, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      layout:
        power = true
    component CD, kind = "capacitor", value = "100n":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
      layout:
        power = false

  check layoutOverrideReport(nl) == @["R1=power", "CD=no-power"]
  let s = layout(nl)
  check s.dividers.len == 1
  let divY = s.dividers[0].y
  check partOf(s, "R1").y > divY    # forced into the band despite a signal net
  check partOf(s, "CD").y < divY    # forced out despite an all-rail shape

test "the power band is held: no part straddles the divider":
  for nl in [opAmpStage()]:
    let s = layout(nl)
    check s.dividers.len == 1
    let divY = s.dividers[0].y
    for p in s.parts:
      let halfH = p.bodyH / 2.0
      check p.y + halfH <= divY + 1e-6 or p.y - halfH >= divY - 1e-6

test "the divider spans the finished scene bounds and carries a caption":
  let s = layout(opAmpStage())
  check s.dividers.len == 1
  let d = s.dividers[0]
  check d.x1 < d.x2
  check d.x1 >= s.minX
  check d.x2 <= s.maxX
  check d.label == "POWER"

test "the scene JSON round-trips dividers, and a pre-feature archive with no dividers key still reads":
  let s = layout(opAmpStage())
  let node = sceneToJson(s)
  check node["dividers"].len == 1
  let back = jsonToScene(node)
  check back.dividers == s.dividers

  var stripped = node
  stripped.delete("dividers")
  let legacy = jsonToScene(stripped)
  check legacy.dividers.len == 0

test "two identical decoupling caps on one rail pair collapse to one x2 symbol":
  let nl = netlist("bypass_bank"):
    net vdd, kind = ntPower
    net gnd, kind = ntGround, name = "0"
    net sig, kind = ntSignal
    component U1, kind = "mcu":
      pin "VDD", vdd, kind = ptPower
      pin "GND", gnd, kind = ptGround
      pin "IO", sig, kind = ptOutput
    component C1, kind = "capacitor", value = "1u":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component C2, kind = "capacitor", value = "1u":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component C3, kind = "capacitor", value = "100n":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component C4, kind = "capacitor", value = "100n":
      pin "1", vdd, kind = ptPassive
      pin "2", gnd, kind = ptPassive

  let rep = arrayReport(nl)
  check rep.len == 2
  var bySource: seq[string]
  for a in rep: bySource.add a.source & ":" & $a.count
  check "capacitor:2" in bySource

  let s = layout(nl)
  check s.parts.len == 3     # U1 + one "1u x2" symbol + one "100n x2" symbol
  var badged = 0
  for p in s.parts:
    if p.count >= 2:
      inc badged
      check p.count == 2
      check p.members.len == 2
      var haveBadge = false
      for lb in s.labels:
        if lb.owner == p.designator and lb.text == "x2": haveBadge = true
      check haveBadge
  check badged == 2

test "an ordinary same-valued pair wired into different roles does not collapse":
  let nl = newNetlist("divider_pair")
  let vin = addNet(nl, newNet("vin"))
  let vout = addNet(nl, newNet("vout"))
  let gnd = addNet(nl, newNet("0", ntGround))
  let r1 = addComponent(nl, newComponent("R1", kind = "resistor"))
  r1.attrs["value"] = "1k"
  discard connect(r1, "1", vin, ptPassive)
  discard connect(r1, "2", vout, ptPassive)
  let r2 = addComponent(nl, newComponent("R2", kind = "resistor"))
  r2.attrs["value"] = "1k"
  discard connect(r2, "1", vout, ptPassive)
  discard connect(r2, "2", gnd, ptPassive)
  check arrayReport(nl).len == 0
  let s = layout(nl)
  check s.parts.len == 2
  for p in s.parts: check p.count == 0
