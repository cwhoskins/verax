## The last-resort stand-in: every component whose behaviour nothing
## describes becomes a per-pin impedance to ground, chosen from `Pin.kind`.
## `expandPinModels` is the pass every analysis calls -- it also runs the
## ferrite-bead and resistive-part expansions and consults the behavioural
## registry first.
##
## Mutates the `Netlist` it is given; run it on a simulation clone.

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

type
  PinModelDefaults* = object
    ## What impedance each kind of pin presents, in ohms to the ground
    ## reference. Zero means "leave this pin alone".
    byKind*: array[PinType, float]
    fallback*: float

proc defaultPinModels*(): PinModelDefaults =
  ## Order-of-magnitude stand-ins, and nothing more. They exist so that a
  ## board carrying an MCU is *simulatable* rather than rejected: without
  ## them a `.op` over a real design dies on `u1 vdd 0 sda scl` with ngspice
  ## reporting an unknown model, which tells the reader nothing about their
  ## circuit.
  ##
  ## What each choice means, and what it does not:
  ##
  ## - **Input, in-out, power, passive: high.** A CMOS input is picofarads
  ##   and megohms; an in-out pin on a shared bus is not driving most of the
  ##   time; a supply pin's real load is a current the netlist does not
  ##   carry. High impedance is also the *conservative* choice for a PDN
  ##   sweep, since a load resistor in parallel would only make the rail look
  ##   better than it is.
  ## - **Output: low.** A push-pull driver is a low impedance to one rail or
  ##   the other. Which one depends on a logic state a netlist does not
  ##   record, so it is modelled to ground -- a small-signal stand-in, not a
  ##   claim that the pin is driving low. An open-drain or open-emitter
  ##   output is genuinely high-impedance and is not distinguishable from a
  ##   push-pull one by `Pin.kind` alone: tag it `ptInOut`, or annotate
  ##   `zin` on the pin.
  ## - **Ground: untouched.** It is the reference; a resistor from it to
  ##   itself models nothing.
  ##
  ## Annotate `zin` on a pin (or on the component, for all of its pins) to
  ## replace any of this with a number somebody actually knows.
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
  ## Replaces every component whose behaviour nothing describes with a
  ## per-pin impedance to ground, chosen from `Pin.kind`.
  ##
  ## "Nothing describes it" means `kinds.isPassive` is false -- the same test
  ## `spice/isolate` uses to decide what it can absorb -- and no `subNetlist`
  ## and no `simReplace` left to apply. A part with a real model, a
  ## macromodel or a stated replacement is never touched.
  ##
  ## **This destroys topology.** Every pin of the replaced part is tied to
  ## ground independently, so any path *through* the part is gone. That is
  ## correct for the questions these models are for -- what a part loads a
  ## rail or a bus with -- and wrong for anything that needs signal to pass
  ## through it. Run it on a simulation clone, never on a design netlist,
  ## exactly as with everything else in this module.
  ##
  ## `exclude` names designators to leave untouched. Every caller that seeds
  ## an isolation on a particular part passes it here, because that part is
  ## about to be modelled deliberately -- `analyzeStartup` stands its
  ## regulator up as a soft-start ramp and `analyzeOpAmpResponse` substitutes
  ## a macromodel, and a generic stand-in applied first would quietly replace
  ## the very thing the analysis exists to model.
  ##
  ## Returns one `Assumption` per invented impedance. That is the point of
  ## the pass as much as the simulability is: the numbers here are stand-ins,
  ## and a result resting on them has to say so.
  # A ferrite bead is electrically passive, so `isPassive` accepts it and
  # the loop below skips it -- but SPICE has no bead device, so left alone
  # it reaches the deck as `FB1` and ngspice reads the leading `F` as a
  # current-controlled current source. It is expanded here rather than at
  # each of the six call sites because the invariant this proc really
  # enforces is "every part reaching the deck is something SPICE can
  # simulate", and a bead breaks that in a way the passivity filter misses.
  result.add expandFerriteBeads(nl)
  result.add expandResistiveParts(nl)

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
    # A part whose kind is modelled decides its own fate -- including
    # declining, which leaves it untouched rather than falling through to
    # impedances that would break a path we know is there.
    let bm = behavioralModelFor(c.kind)
    if bm != nil:
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

    removeComponent(nl, c.designator)

    for t in terminals:
      let r = addComponent(nl, newComponent(
        $spiceFormat.designatorPrefix("resistor") & c.designator & "_" & t.name,
        kind = "resistor"))
      discard connect(r, "1", t.net, ptPassive)
      discard connect(r, "2", gnd, ptPassive)
      r.attrs["value"] = spiceValue(t.z)
      r.attrs["models.pin.expanded"] = "true"
