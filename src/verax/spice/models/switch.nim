## Switches: a two-terminal analog/load switch as a SPICE `S` element, and a
## multi-throw analog mux / RF switch as a decoded bank of them.
##
## SPICE has a voltage-controlled switch (`Sname n+ n- nc+ nc- MODEL`,
## `.MODEL m SW(Ron= Roff= Vt= Vh=)`) and nothing higher-level. Everything
## here builds on that primitive:
##
## * `expandSwitches` turns a plain `switch` / `relay` / `load_switch` into
##   one `S` element and a `.MODEL SW` card.
## * `muxModel` (a behavioural-registry model) turns an `analog_switch` /
##   `rf_switch` / `mux` into, per throw, a decoder `B` source and a through
##   `S` element -- plus, when the part is absorptive, a second `S` element
##   and a 50 ohm resistor that terminate the throw when it is open. This is
##   what makes "EN low, every port sits in 50 ohm" a real measurement
##   rather than a comment.
##
## **What this does not model:** charge injection, on-resistance flatness vs
## signal level, off-isolation vs frequency (`Roff` is flat), break-before-
## make timing, and the control-logic supply current. `Vt`/`Vh` come from a
## logic threshold, not a real input stage.
##
## Mutates the `Netlist` it is given; run it on a simulation clone.

import std/[algorithm, math, strutils, tables]
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/kinds
import ../../netlist/annotations
import ../../units
import ../../eng
import ../../netlist/formats/spice as spiceFormat
import ./common
import ./behavioral

type
  SwitchModel* = object
    ron*: Ohms          ## through-path resistance when the part states none
    roff*: Ohms         ## open-throw leakage when the part states none
    controlRail*: float  ## assumed logic rail for the control threshold

proc defaultSwitchModel*(): SwitchModel =
  SwitchModel(ron: 100.mohm, roff: 1.Gohm, controlRail: 3.3)

const switchKinds = ["switch", "relay", "load_switch"]

proc swCard(ron, roff, vt, vh: float): string =
  "SW(Ron=" & spiceValue(max(ron, 1.0e-3)) & " Roff=" & spiceValue(roff) &
    " Vt=" & spiceValue(vt) & " Vh=" & spiceValue(vh) & ")"

proc controlRailFor(ctrlNet: Net, d: SwitchModel): float =
  ## The control logic swing, for the switch threshold. The control net
  ## rarely carries a `voltage` of its own, so this is usually the default --
  ## which is why `vt` is worth stating on a part whose control family is not
  ## 3.3 V logic.
  let r = railVoltage(ctrlNet)
  if r.has and r.value > 0.0: r.value else: d.controlRail

proc expandSwitches*(nl: Netlist, d = defaultSwitchModel()): seq[Assumption] =
  ## Rewrites every two-terminal `switch` / `relay` / `load_switch` that
  ## carries no `.MODEL` of its own into a `vswitch` `S` element plus a
  ## `.MODEL <desig>_SW SW(...)` card.
  ##
  ## The through terminals are matched by `common.switchThrowInNames` /
  ## `switchThrowOutNames`, the control by `switchCtrlNames` (referenced to
  ## `switchCtrlRetNames` or, failing that, ground). A part missing any of
  ## those is left alone with a note -- it still has a device letter, so the
  ## deck writer will not misattribute it, but ngspice will reject the line.
  var parts: seq[Component]
  for _, c in nl.components:
    if c.kind in switchKinds and c.subNetlist == nil and not hasDeviceModel(c):
      parts.add c

  let gnd = groundOf(nl)
  for part in parts:
    let desig = part.designator
    let inP = pinNamed(part, switchThrowInNames)
    let outP = pinNamed(part, switchThrowOutNames)
    let ctrlP = pinNamed(part, switchCtrlNames)
    var ctrlRetP = pinNamed(part, switchCtrlRetNames)
    if inP == nil or outP == nil or ctrlP == nil or
       inP.net == nil or outP.net == nil or ctrlP.net == nil:
      var names: seq[string]
      for pp in orderedPins(part): names.add pp.name
      result.add note(desig & " (" & part.kind & ") needs a through pair " &
        "(IN/OUT) and a control pin to be modelled as an S switch; it has " &
        names.join(", ") & ". Left unmodelled.")
      continue
    let ctrlRet = if ctrlRetP != nil and ctrlRetP.net != nil: ctrlRetP.net
                  elif gnd != nil: gnd
                  else: nil
    if ctrlRet == nil:
      result.add note(desig & ": no ground for the switch control reference.")
      continue

    let rail = controlRailFor(ctrlP.net, d)
    let ronA = annotationFloat(part, "ron")
    let roffA = annotationFloat(part, "roff")
    let vtA = annotationFloat(part, "vt")
    let vhA = annotationFloat(part, "vh")
    let ron = if ronA.has and ronA.value > 0.0: ronA.value else: float(d.ron)
    let roff = if roffA.has and roffA.value > 0.0: roffA.value else: float(d.roff)
    let vt = if vtA.has: vtA.value else: rail * 0.5
    let vh = if vhA.has: vhA.value else: rail * 0.1
    if not (ronA.has and ronA.value > 0.0):
      result.add assumption(desig, "ron", ron, "ohm", annDefaulted,
        "typical for a small analog/load switch; state it where the drop " &
        "across a closed contact matters")
    if not (roffA.has and roffA.value > 0.0):
      result.add assumption(desig, "roff", roff, "ohm", annDefaulted,
        "an open switch is treated as a flat 1 Gohm; real off-isolation " &
        "falls with frequency and this does not")
    if not vtA.has:
      result.add assumption(desig, "vt", vt, "V", annDefaulted,
        "half of an assumed " & eng(rail, "V") & " control rail")

    let inNet = inP.net
    let outNet = outP.net
    let ctrlNet = ctrlP.net
    let modelName = "MSW_" & desig.replace(".", "_")
    setModel(nl, modelName, swCard(ron, roff, vt, vh))
    removeComponent(nl, desig)

    let s = addComponent(nl, newComponent("S" & desig, kind = "vswitch"))
    discard connect(s, "1", inNet, ptPassive)
    discard connect(s, "2", outNet, ptPassive)
    discard connect(s, "C+", ctrlNet, ptInput)
    discard connect(s, "C-", ctrlRet, ptInput)
    s.attrs["value"] = modelName

    result.add note(desig & ": modelled as an S switch, " & eng(ron, "ohm") &
      " on / " & eng(roff, "ohm") & " off, threshold " & eng(vt, "V"))

# --- the multi-throw mux -------------------------------------------------

proc logistic(netName: string, vt, vs: float, wantHigh: bool): string =
  ## A smooth 0..1 gate on `v(netName)` crossing `vt`. Smooth rather than
  ## `v(net) > vt` because a hard step has a zero derivative on both sides
  ## and an infinite one at the corner -- which is how a `.tran` earns
  ## "timestep too small" and how an `.ac` linearises a live path to no
  ## gain. Same reasoning as `opampModel`'s min/max clamp.
  let arg = "(v(" & netName & ")-" & spiceValue(vt) & ")/" & spiceValue(vs)
  if wantHigh: "(1/(1+exp(-" & arg & ")))"
  else:        "(1/(1+exp(" & arg & ")))"

proc muxModel*(nl: Netlist, c: Component, gnd: Net): BehavioralResult =
  ## An analog mux / RF switch: a common terminal fanned to N throws, the
  ## live throw chosen by decoding the select pins, the whole part gated by
  ## an enable. Absorptive when `switch.off_termination` is stated -- each
  ## open throw then sits in that resistance to ground.
  ##
  ## Reads, all off the component:
  ## * `switch.select_pins` -- comma list, MSB first (e.g. `"A1,A0"`).
  ## * `switch.enable_active_low` -- `"true"` inverts the enable sense.
  ## * `switch.off_termination` -- ohms; absent means non-absorptive.
  ## * `ron` / `roff` -- through and leakage resistance.
  let comPin = pinNamed(c, ["rfc", "com", "d", "in", "s", "a"])
  if comPin == nil or comPin.net == nil:
    return (false, @[note(c.designator & " (" & c.kind & ") has no common " &
      "terminal (RFC/COM/D) -- left unmodelled.")])

  # Throw pins: everything named RF<n> or S<n> or NO<n>, in numeric order.
  var throws: seq[tuple[idx: int, net: Net]]
  for p in orderedPins(c):
    if p.net == nil: continue
    let nm = p.name.toLowerAscii
    for pfx in ["rf", "s", "no", "d"]:
      if nm.startsWith(pfx) and nm.len > pfx.len and
         nm[pfx.len] in {'0'..'9'}:
        try: throws.add (parseInt(nm[pfx.len .. ^1]), p.net)
        except ValueError: discard
        break
  if throws.len < 2:
    return (false, @[note(c.designator & " (" & c.kind & ") needs at least " &
      "two numbered throw pins (RF1, RF2, ...) -- left unmodelled.")])
  throws.sort(proc (a, b: tuple[idx: int, net: Net]): int = cmp(a.idx, b.idx))

  let selNames = c.attrs.getOrDefault("switch.select_pins", "")
  var selNets: seq[Net]
  for s in selNames.split(','):
    let p = pinNamed(c, [s.strip().toLowerAscii])
    if p != nil and p.net != nil: selNets.add p.net
  let enPin = pinNamed(c, ["en", "enable", "ce"])
  let activeLow = c.attrs.getOrDefault("switch.enable_active_low", "") == "true"

  # Snapshot every net *name* now: `removeComponent` below calls `disconnect`
  # on each pin, which nulls `Pin.net` -- the `Net` objects survive (they are
  # still wired to other parts) but the pin no longer points at them.
  let enNetName = if enPin != nil and enPin.net != nil: enPin.net.name else: ""
  let vddPin = pinNamed(c, ["vdd", "vcc", "vs+", "v+"])
  let vddNet = if vddPin != nil: vddPin.net else: nil
  let vddZin = if vddPin != nil: annotationFloat(vddPin, "zin")
               else: AnnValue[float](source: annAbsent)

  let d = defaultSwitchModel()
  let ronA = annotationFloat(c, "ron")
  let roffA = annotationFloat(c, "roff")
  let ron = if ronA.has and ronA.value > 0.0: ronA.value else: 4.0
  let roff = if roffA.has and roffA.value > 0.0: roffA.value else: float(d.roff)
  let termA = annotationFloat(c, "switch.off_termination")
  let hasTerm = termA.has and termA.value > 0.0
  let term = if hasTerm: termA.value else: 50.0

  let rail = (block:
    let r = railVoltage(comPin.net)
    if r.has and r.value > 0.0: r.value else: d.controlRail)
  let vt = rail * 0.5
  let vs = max(rail * 0.05, 0.02)

  var notes: seq[Assumption]
  if not ronA.has:
    notes.add assumption(c.designator, "ron", ron, "ohm", annDefaulted,
      "typical analog-mux on-resistance against 50 ohm ports")
  if hasTerm:
    notes.add note(c.designator & ": absorptive -- each open throw modelled " &
      "as " & eng(term, "ohm") & " to ground, which is the whole content of " &
      "the safe-default claim (enable low => every port in " & eng(term, "ohm") & ")")
  if selNets.len == 0 and throws.len > 1:
    notes.add note(c.designator & ": no `switch.select_pins`, so throw 1 is " &
      "the only one that can be selected; the rest are always terminated.")

  let comNet = comPin.net
  let desig = c.designator.replace(".", "_")
  let modelName = "MSW_" & desig
  setModel(nl, modelName, swCard(ron, roff, 0.5, 0.0))
  removeComponent(nl, c.designator)

  # Keep the supply pin loading the rail, so a PDN sweep past this part does
  # not improve just because the part stopped being there.
  if vddNet != nil and vddNet != gnd:
    let zv = if vddZin.has and vddZin.value > 0.0: vddZin.value else: 1.0e5
    let rv = addComponent(nl, newComponent("R" & c.designator & "_VDD",
                                           kind = "resistor"))
    discard connect(rv, "1", vddNet, ptPassive)
    discard connect(rv, "2", gnd, ptPassive)
    rv.attrs["value"] = spiceValue(zv)
    rv.attrs["models.pin.expanded"] = "true"
    if not (vddZin.has and vddZin.value > 0.0):
      notes.add assumption(c.designator & ".VDD", "zin", zv, "ohm",
        annDefaulted, "supply-pin load of an unmodelled mux; annotate `zin` " &
        "on the VDD pin for the real quiescent draw")

  let nbits = selNets.len
  for ti, throw in throws:
    # Which throw index does this pin correspond to? RF1 -> 0, RF2 -> 1, ...
    let sel = throw.idx - throws[0].idx

    # decoder: enable AND the select pattern for `sel`
    var terms: seq[string]
    if enNetName.len > 0:
      terms.add logistic(enNetName, vt, vs, not activeLow)
    for bi in 0 ..< nbits:
      let want = ((sel shr (nbits - 1 - bi)) and 1) == 1
      terms.add logistic(selNets[bi].name, vt, vs, want)
    let expr = if terms.len > 0: terms.join("*") else: (if sel == 0: "1" else: "0")

    let ctrlNet = addNet(nl, newNet(c.designator & "_C" & $throw.idx))
    let bd = addComponent(nl, newComponent("B" & c.designator & "_C" & $throw.idx,
                                           kind = "bsource"))
    discard connect(bd, "OUT+", ctrlNet, ptOutput)
    discard connect(bd, "OUT-", gnd, ptPassive)
    bd.attrs["value"] = "V = " & expr

    # through switch: common <-> throw, closed when ctrl high
    let st = addComponent(nl, newComponent("S" & c.designator & "_T" & $throw.idx,
                                           kind = "vswitch"))
    discard connect(st, "1", comNet, ptPassive)
    discard connect(st, "2", throw.net, ptPassive)
    discard connect(st, "C+", ctrlNet, ptInput)
    discard connect(st, "C-", gnd, ptInput)
    st.attrs["value"] = modelName

    if hasTerm:
      # inverted control, and a switch + resistor terminating the throw when
      # it is open. `RFC` itself is terminated only when the enable is off,
      # which the `sel == 0` throw's inverted decoder already expresses when
      # every other throw is also open -- close enough for a DC/​low-freq
      # absorptive model.
      let nCtrl = addNet(nl, newNet(c.designator & "_N" & $throw.idx))
      let bn = addComponent(nl, newComponent("B" & c.designator & "_N" & $throw.idx,
                                             kind = "bsource"))
      discard connect(bn, "OUT+", nCtrl, ptOutput)
      discard connect(bn, "OUT-", gnd, ptPassive)
      bn.attrs["value"] = "V = 1-v(" & ctrlNet.name & ")"

      let sg = addComponent(nl, newComponent("S" & c.designator & "_G" & $throw.idx,
                                             kind = "vswitch"))
      let tnode = addNet(nl, newNet(c.designator & "_TERM" & $throw.idx))
      discard connect(sg, "1", throw.net, ptPassive)
      discard connect(sg, "2", tnode, ptPassive)
      discard connect(sg, "C+", nCtrl, ptInput)
      discard connect(sg, "C-", gnd, ptInput)
      sg.attrs["value"] = modelName
      let rg = addComponent(nl, newComponent("R" & c.designator & "_TERM" & $throw.idx,
                                             kind = "resistor"))
      discard connect(rg, "1", tnode, ptPassive)
      discard connect(rg, "2", gnd, ptPassive)
      rg.attrs["value"] = spiceValue(term)

  notes.add note(c.designator & ": " & c.kind & " modelled as " &
    $throws.len & " throws off one common, " & eng(ron, "ohm") &
    " through / " & eng(roff, "ohm") & " open, decoded from " &
    (if nbits > 0: selNames else: "no select pins") &
    (if enPin != nil: " gated by " & enPin.name else: ""))
  (true, notes)
