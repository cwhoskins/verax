## Capacitor parasitic expansion: an ideal C in series with its ESR and ESL,
## because an ideal capacitor's impedance falls monotonically forever and a
## PDN sweep over ideal caps shows none of the self-resonance, ESR floor or
## anti-resonance such a sweep is run to find.
##
## Like the rest of `spice/models`, this mutates whatever `Netlist` it is
## given -- run it on a simulation clone, never on the real design netlist --
## and returns a `seq[Assumption]` for every number it invents.

import std/tables
import ../../netlist/types
import ../../netlist/graph
import ../../netlist/annotations
import ../../netlist/formats/spice as spiceFormat
import ./common
import ./derating

type
  Parasitic* = tuple[esr, esl: float]
    ## Equivalent series resistance (ohms) and inductance (henries).

  ParasiticDefaults* = object
    byPackage*: OrderedTable[string, Parasitic]
    fallback*: Parasitic

proc defaultParasitics*(): ParasiticDefaults =
  ## Typical order-of-magnitude MLCC figures by case size, **not** measured
  ## or vendor data. They exist so a board that carries no parasitic
  ## annotation still produces a qualitatively right impedance curve --
  ## self-resonance in roughly the right decade, and an anti-resonance peak
  ## where two capacitor families actually interact. Do not read a specific
  ## ESR number off a run that used these; annotate `attrs["esr"]`/
  ## `attrs["esl"]` from a real datasheet if the exact value matters.
  result.byPackage = {
    "0201": (esr: 0.05, esl: 0.4e-9),
    "0402": (esr: 0.03, esl: 0.6e-9),
    "0603": (esr: 0.02, esl: 0.8e-9),
    "0805": (esr: 0.015, esl: 1.0e-9),
    "1206": (esr: 0.010, esl: 1.2e-9),
    "1210": (esr: 0.010, esl: 1.4e-9),
    "tantalum": (esr: 0.100, esl: 3.0e-9),
    "electrolytic": (esr: 0.200, esl: 5.0e-9),
    "bulk": (esr: 0.100, esl: 3.0e-9),
  }.toOrderedTable
  result.fallback = (esr: 0.02, esl: 1.0e-9)

proc parasiticFor(c: Component, d: ParasiticDefaults): tuple[p: Parasitic, notes: seq[Assumption]] =
  ## Attribute first, then the package table, then the global fallback.
  ##
  ## Reads through `netlist/annotations`, so an unparseable value raises with
  ## the same message everywhere and a misspelled key is caught by
  ## `validateAnnotations` rather than silently landing here as a default.
  ## Each invented value is returned as an `Assumption` carrying its own
  ## provenance -- this proc is where the distinction between "the designer
  ## measured this" and "we guessed from the case size" is actually made, so
  ## it is where the record has to be created.
  var p = d.fallback
  var esrSrc = "from the global fallback"
  var eslSrc = "from the global fallback"
  let pkg = package(c)
  if pkg.has and d.byPackage.hasKey(pkg.value):
    p = d.byPackage[pkg.value]
    esrSrc = "from package default (" & pkg.value & ")"
    eslSrc = esrSrc

  let authoredEsr = esr(c)
  if authoredEsr.has:
    p.esr = authoredEsr.value
    esrSrc = ""
  let authoredEsl = esl(c)
  if authoredEsl.has:
    p.esl = authoredEsl.value
    eslSrc = ""

  var notes: seq[Assumption]
  if esrSrc.len > 0:
    notes.add assumption(c.designator, "esr", p.esr, "ohm", annDefaulted, esrSrc)
  if eslSrc.len > 0:
    notes.add assumption(c.designator, "esl", p.esl, "H", annDefaulted, eslSrc)
  (p: p, notes: notes)

proc expandCapacitorParasitics*(nl: Netlist, d = defaultParasitics(),
                                derating = defaultDerating(),
                                bias = initOrderedTable[string, float]()):
    seq[Assumption] =
  ## Rewrites every `kind == "capacitor"` into an ideal C in series with its
  ## ESR and ESL, using only the `graph` API.
  ##
  ## This is not cosmetic. An ideal capacitor's impedance falls monotonically
  ## with frequency, so a PDN sweep over ideal caps shows no self-resonance,
  ## no ESR floor and no anti-resonance between capacitor families -- i.e.
  ## none of the three things such a sweep is run to find. The expansion is
  ## what makes the result mean anything above a megahertz.
  ##
  ## Only `nl`'s own components are touched, never `nl.children` -- a
  ## capacitor inside a macromodel (e.g. `idealOpAmp`'s pole cap) is a
  ## modelling element, not a physical part, and giving it an ESL would add a
  ## resonance the real amplifier does not have. Such caps are also marked
  ## `attrs["parasitics.expanded"]`, which this proc honours, so expanding
  ## twice is a no-op rather than a doubling.
  ##
  ## Returns one `Assumption` per invented value, each carrying which
  ## capacitor, which key, the magnitude and where it came from.
  var caps: seq[Component]
  for _, c in nl.components:
    if c.kind == "capacitor" and c.subNetlist == nil and
       c.attrs.getOrDefault("parasitics.expanded", "") != "true":
      caps.add c

  for cap in caps:
    let pins = orderedPins(cap)
    if pins.len != 2:
      raise newException(NetlistError,
        "cannot expand parasitics for " & cap.designator & ": expected 2 pins, got " & $pins.len)
    if pins[0].net == nil or pins[1].net == nil:
      continue  # a dangling cap contributes nothing; leave it exactly as-is

    # Before the parasitics, because it rewrites the capacitance itself: a
    # Class 2 ceramic on a rail is not the part its label says it is, and
    # every impedance computed from the label is wrong by that factor.
    result.add derateCapacitor(cap, derating, bias)

    let (par, notes) = parasiticFor(cap, d)
    result.add notes

    let farNet = pins[1].net
    let midR = addNet(nl, newNet(cap.designator & "_ESR_N"))
    let midL = addNet(nl, newNet(cap.designator & "_ESL_N"))

    disconnect(pins[1])
    connect(pins[1], midR)

    let r = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("resistor") & cap.designator & "_ESR",
      kind = "resistor"))
    discard connect(r, "1", midR, ptPassive)
    discard connect(r, "2", midL, ptPassive)
    r.attrs["value"] = spiceValue(par.esr)

    let l = addComponent(nl, newComponent(
      $spiceFormat.designatorPrefix("inductor") & cap.designator & "_ESL",
      kind = "inductor"))
    discard connect(l, "1", midL, ptPassive)
    discard connect(l, "2", farNet, ptPassive)
    l.attrs["value"] = spiceValue(par.esl)

    cap.attrs["parasitics.expanded"] = "true"
