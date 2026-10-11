## Capacitor parasitic expansion: an ideal C in series with ESR and ESL.
## Ideal caps show none of the self-resonance, ESR floor or anti-resonance a
## PDN sweep looks for. Mutates its netlist (use a clone) and returns an
## `Assumption` per invented number.

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
  ## Typical MLCC figures by case size, **not** vendor data: enough for a
  ## qualitatively right impedance curve. Annotate `esr`/`esl` from a
  ## datasheet when exact values matter.
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
  ## Attribute first, then the package table, then the fallback. Reads
  ## through `netlist/annotations` (consistent errors; typos caught by
  ## `validateAnnotations`). Each invented value is returned as an
  ## `Assumption` with its provenance.
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
    p.esr = float(authoredEsr.value)
    esrSrc = ""
  let authoredEsl = esl(c)
  if authoredEsl.has:
    p.esl = float(authoredEsl.value)
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
  ## Rewrites every `capacitor` into ideal C + ESR + ESL via the `graph` API.
  ##
  ## Only `nl`'s own components, never children (a macromodel's capacitor
  ## must not gain an ESL). Caps marked `parasitics.expanded` are skipped,
  ## so expanding twice is a no-op. Returns one `Assumption` per invented
  ## value.
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

    # Derate first: it rewrites the capacitance itself.
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
