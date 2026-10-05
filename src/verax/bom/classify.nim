## The two policy decisions collection rests on, named in one place: which
## family a component kind belongs to, and whether its land pattern is a
## standard chip case a parametric search may fill.

import std/[strutils, tables]

import ./types

# --- family -----------------------------------------------------------------

const builtinPartFamilies* = {
    "resistor": pfResistor, "capacitor": pfCapacitor,
    "inductor": pfInductor, "ferrite_bead": pfFerrite,
    "voltage_source": pfNotAPart, "current_source": pfNotAPart,
    "vcvs": pfNotAPart, "vccs": pfNotAPart, "ccvs": pfNotAPart,
    "cccs": pfNotAPart, "mutual_inductance": pfNotAPart,
    "vswitch": pfNotAPart, "iswitch": pfNotAPart,
  }
  ## Seed for `familyOf`. Anything not listed is `pfOther` -- bought, and
  ## needing an MPN. The `pfNotAPart` entries are the simulation-only kinds
  ## `netlist/kinds` already knows: a stimulus or controlled source, a `K`
  ## coupling between two inductors, a voltage/current-controlled switch.
  ## A battery is deliberately absent: it is bought.

var partFamilies = block:
  var t: Table[string, PartFamily]
  for (k, f) in builtinPartFamilies: t[k] = f
  t

proc registerPartFamily*(kind: string, family: PartFamily) =
  ## Runtime, like `kinds.registerDesignatorPrefix`, so a project's own kinds
  ## -- its own stimulus element, its own chip-passive kind -- are not second
  ## class. `Component.kind` is an open string, so this is a table and never
  ## a `case`.
  partFamilies[kind.toLowerAscii] = family

proc familyOf*(kind: string): PartFamily =
  partFamilies.getOrDefault(kind.toLowerAscii, pfOther)

# --- case code ----------------------------------------------------------------

const standardCaseCodes* = {
    "0201": "0603", "0402": "1005", "0603": "1608", "0805": "2012",
    "1206": "3216", "1210": "3225", "1812": "4532", "2010": "5025",
    "2512": "6332",
  }
  ## Imperial chip case code -> its metric name. The pairing is what makes a
  ## footprint name unambiguous: `0603` alone is a real imperial *and* a real
  ## metric size (metric 0603 is imperial 0201), so a footprint is only read
  ## when the imperial code sits beside its own metric twin, the way KiCad
  ## names every chip footprint (`R_0402_1005Metric`).

proc metricOf(imperial: string): string =
  for (i, m) in standardCaseCodes:
    if i == imperial: return m
  ""

proc caseCodeOf*(footprint, package: string): string =
  ## The imperial chip case code this part is, or `""` when it cannot be
  ## placed in `standardCaseCodes` -- **the standard-footprint gate**. A `""`
  ## is what makes the resolver refuse to search rather than return a part
  ## that will not fit the land pattern the board already has.
  ##
  ## A stated `footprint` is the only authority when present: it is the land
  ## pattern the board solders to, so a QFN footprint with `package = "0805"`
  ## beside it is `""`, not `0805`. Without one, `package` is accepted only
  ## as a bare imperial code.
  if footprint.len > 0:
    var name = footprint
    let colon = name.rfind(':')
    if colon >= 0: name = name[colon + 1 .. ^1]
    let slash = name.rfind({'/', '\\'})
    if slash >= 0: name = name[slash + 1 .. ^1]
    name.removeSuffix(".kicad_mod")
    let toks = name.split('_')
    for i in 0 ..< toks.len - 1:
      let m = metricOf(toks[i])
      if m.len > 0 and toks[i + 1].startsWith(m & "Metric"):
        return toks[i]
    return ""
  let p = package.strip()
  if metricOf(p).len > 0: p else: ""
