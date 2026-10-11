## The last-resort stand-in: every component nothing describes becomes a
## per-pin impedance to ground chosen from `Pin.kind`. `expandPinModels` is
## the pass every analysis calls; it also runs the ferrite-bead and
## resistive expansions and consults the behavioural registry first.
## Mutates its netlist; use a simulation clone.

import std/tables
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../netlist/kinds
import ../../netlist/formats/spice as spiceFormat
import ./common
import ./behavioral
import ./ferrite_bead
import ./passives
import ./magnetics
import ./switch
import ../provenance

type
  PinModelDefaults* = object
    ## Ohms to ground per pin kind; zero leaves the pin alone.
    byKind*: array[PinType, float]
    fallback*: float

proc defaultPinModels*(): PinModelDefaults =
  ## Order-of-magnitude stand-ins, so a board with an MCU simulates instead
  ## of dying on an unknown model.
  ##
  ## - **Input, in-out, power, passive: high.** CMOS inputs are megohms; a
  ##   bus pin mostly isn't driving; a supply's real load isn't in the
  ##   netlist. High is also conservative for a PDN sweep.
  ## - **Output: low**, modelled to ground (a small-signal stand-in, not a
  ##   claim it drives low). Open-drain outputs aren't distinguishable by
  ##   kind: tag them `ptInOut` or annotate `zin`.
  ## - **Ground: untouched.**
  ##
  ## Annotate `zin` on a pin (or component) to use a known number.
  result.byKind[ptUnknown] = 1.0e6
  result.byKind[ptInput] = 1.0e6
  result.byKind[ptOutput] = 50.0
  result.byKind[ptInOut] = 1.0e6
  result.byKind[ptPower] = 1.0e6
  result.byKind[ptGround] = 0.0
  result.byKind[ptPassive] = 1.0e6
  result.fallback = 1.0e6

proc pinImpedanceFor(p: Pin, c: Component, d: PinModelDefaults):
    tuple[z: float, note: Assumption, invented: bool] =
  let onPin = annotationFloat(p, "zin")
  if onPin.has:
    return (onPin.value, Assumption(), false)
  let onComp = annotationFloat(c, "zin")
  if onComp.has:
    return (onComp.value, Assumption(), false)
  var z = d.byKind[p.kind]
  if z == 0.0 and p.kind != ptGround: z = d.fallback
  (z, assumption(c.designator & "." & p.name, "zin", z, "ohm", annDefaulted,
     "no model for this " & (if c.kind.len > 0: c.kind else: "part") &
     "; stood in from the pin kind (" & $p.kind & ")"), true)

proc expandPinModels*(nl: Netlist, d = defaultPinModels(),
                      exclude: openArray[string] = []): seq[Assumption] =
  ## Replaces every component nothing describes (`isPassive` false, no
  ## `subNetlist`, no `simReplace`) with per-pin impedances to ground.
  ##
  ## **This destroys topology**: paths through the part are gone. Right for
  ## loading questions, wrong for signal paths. Simulation clones only.
  ##
  ## `exclude` names parts the caller will model deliberately (a regulator
  ## ramp, an op-amp macromodel). Returns one `Assumption` per invented
  ## impedance.
  # Ferrite beads pass `isPassive` but SPICE has no bead device (`FB1` would
  # read as a CCCS), so they are expanded here: every part reaching the deck
  # must be simulatable.
  result.add expandFerriteBeads(nl)
  result.add expandResistiveParts(nl)
  result.add expandCoupledInductors(nl)
  result.add expandSwitches(nl)

  let gnd = groundOf(nl)
  if gnd == nil:
    return @[note("no ground reference was found, so parts without models " &
                  "were left as they are; nothing can be referenced to " &
                  "ground until some net is named \"0\" or marked ntGround")]

  var unmodelled: seq[Component]
  for _, c in nl.components:
    if c.subNetlist == nil and c.simReplace == nil and not isPassive(c) and
       c.designator notin exclude and
       c.attrs.getOrDefault("models.pin.expanded", "") != "true":
      unmodelled.add c

  for c in unmodelled:
    # A modelled kind decides its own fate, including declining (left
    # untouched rather than broken into impedances).
    let bm = behavioralModelFor(c.kind)
    if bm != nil:
      provenance(nl, c, brStandIn):
        let (handled, notes) = bm(nl, c, gnd)
        result.add notes
        if handled: c.attrs["models.pin.expanded"] = "true"
      continue

    # Snapshot before removing: the pins go with the component.
    var terminals: seq[tuple[name: string, z: float, net: Net]]
    for p in orderedPins(c):
      if p.net == nil or p.net == gnd: continue
      let (z, note, invented) = pinImpedanceFor(p, c, d)
      if z <= 0.0: continue
      if invented: result.add note
      terminals.add (name: p.name, z: z, net: p.net)

    provenance(nl, c, brStandIn):
      removeComponent(nl, c.designator)

      for t in terminals:
        let r = addComponent(nl, newComponent(
          $spiceFormat.designatorPrefix("resistor") & c.designator & "_" & t.name,
          kind = "resistor"))
        discard connect(r, "1", t.net, ptPassive)
        discard connect(r, "2", gnd, ptPassive)
        r.attrs["value"] = spiceValue(t.z)
        r.attrs["models.pin.expanded"] = "true"
        r.attrs[benchPinKey] = t.name
