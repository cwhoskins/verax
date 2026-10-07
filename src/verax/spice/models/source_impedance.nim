## A finite output impedance in series with every source: an ideal source is
## a dead short at AC, so a PDN sweep including the regulator would read
## 0 ohm everywhere. Mutates its netlist; use a clone.

import std/tables
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../netlist/formats/spice as spiceFormat
import ./common

type
  SourceImpedance* = tuple[rout, lout: float]
    ## Series output resistance (ohms) and inductance (henries).

  SourceDefaults* = object
    byKind*: OrderedTable[string, SourceImpedance]
    fallback*: SourceImpedance

proc defaultSourceImpedance*(): SourceDefaults =
  ## Defaults: the flat part is the regulator's closed-loop output
  ## resistance; the inductance stands for wiring and the impedance rise
  ## above loop bandwidth. The exact numbers matter far less than being
  ## finite -- the supply is in parallel with the decoupling. Annotate
  ## `rout`/`lout` when the supply itself is under study.
  result.byKind = {
    "voltage_source": (rout: 10.0e-3, lout: 1.0e-6),
    "regulator": (rout: 10.0e-3, lout: 1.0e-6),
    "ldo": (rout: 5.0e-3, lout: 1.0e-6),
    "battery": (rout: 100.0e-3, lout: 500.0e-9),
  }.toOrderedTable
  result.fallback = (rout: 10.0e-3, lout: 1.0e-6)

proc sourceImpedanceFor(c: Component, d: SourceDefaults):
    tuple[z: SourceImpedance, notes: seq[Assumption]] =
  var z = d.fallback
  var rSrc = "from the global fallback"
  var lSrc = "from the global fallback"
  if d.byKind.hasKey(c.kind):
    z = d.byKind[c.kind]
    rSrc = "typical for a " & c.kind
    lSrc = rSrc

  let ar = annotationFloat(c, "rout")
  if ar.has:
    z.rout = ar.value
    rSrc = ""
  let al = annotationFloat(c, "lout")
  if al.has:
    z.lout = al.value
    lSrc = ""

  var notes: seq[Assumption]
  if rSrc.len > 0:
    notes.add assumption(c.designator, "rout", z.rout, "ohm", annDefaulted, rSrc)
  if lSrc.len > 0:
    notes.add assumption(c.designator, "lout", z.lout, "H", annDefaulted, lSrc)
  (z: z, notes: notes)

proc expandSourceImpedance*(nl: Netlist, d = defaultSourceImpedance(),
                            kinds: openArray[string] = ["voltage_source"]): seq[Assumption] =
  ## Puts a finite output impedance in series with every source of a listed
  ## kind. Annotate `rout = 0.ohm` and `lout = 0.H` to keep a source ideal
  ## (right for a stimulus, wrong for a supply). Idempotent.
  var sources: seq[Component]
  for _, c in nl.components:
    if c.kind in kinds and c.subNetlist == nil and
       c.attrs.getOrDefault("source.zout.expanded", "") != "true":
      sources.add c

  for src in sources:
    let pins = orderedPins(src)
    if pins.len != 2: continue
    if pins[0].net == nil or pins[1].net == nil: continue

    let (z, notes) = sourceImpedanceFor(src, d)
    if z.rout == 0.0 and z.lout == 0.0:
      # Ideal by request: mark and leave it.
      src.attrs["source.zout.expanded"] = "true"
      continue
    result.add notes

    let outNet = pins[0].net
    let midR = addNet(nl, newNet(src.designator & "_ROUT_N"))
    let midL = addNet(nl, newNet(src.designator & "_LOUT_N"))

    disconnect(pins[0])
    connect(pins[0], midR)

    let r = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("resistor") & src.designator & "_ROUT",
      kind = "resistor"))
    discard connect(r, "1", midR, ptPassive)
    discard connect(r, "2", midL, ptPassive)
    r.attrs["value"] = spiceValue(max(z.rout, 1.0e-9))

    let l = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("inductor") & src.designator & "_LOUT",
      kind = "inductor"))
    discard connect(l, "1", midL, ptPassive)
    discard connect(l, "2", outNet, ptPassive)
    l.attrs["value"] = spiceValue(max(z.lout, 1.0e-15))

    src.attrs["source.zout.expanded"] = "true"
