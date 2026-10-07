## The two policies collection rests on: a component kind's family, and
## whether its land pattern is a standard chip case a search may fill.

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
  ## Seed for `familyOf`; unlisted kinds are `pfOther` (need an MPN).
  ## `pfNotAPart`: stimulus/controlled sources, `K` couplings, controlled
  ## switches. Batteries are bought, so absent.

var partFamilies = block:
  var t: Table[string, PartFamily]
  for (k, f) in builtinPartFamilies: t[k] = f
  t

proc registerPartFamily*(kind: string, family: PartFamily) =
  ## Runtime registration, so a project's own kinds are first-class (kinds
  ## are open strings: a table, never a `case`).
  partFamilies[kind.toLowerAscii] = family

proc familyOf*(kind: string): PartFamily =
  partFamilies.getOrDefault(kind.toLowerAscii, pfOther)

# --- case code ----------------------------------------------------------------

const standardCaseCodes* = {
    "0201": "0603", "0402": "1005", "0603": "1608", "0805": "2012",
    "1206": "3216", "1210": "3225", "1812": "4532", "2010": "5025",
    "2512": "6332",
  }
  ## Imperial code -> metric name. `0603` is both a real imperial and metric
  ## size, so a footprint name is trusted only with its metric twin beside
  ## it (`R_0402_1005Metric`).

proc metricOf(imperial: string): string =
  for (i, m) in standardCaseCodes:
    if i == imperial: return m
  ""

proc caseCodeOf*(footprint, package: string): string =
  ## The imperial case code, or `""` -- **the standard-footprint gate**: `""`
  ## makes the resolver refuse to search. A stated `footprint` is the only
  ## authority (a QFN footprint beside `package = "0805"` gives `""`);
  ## without one, `package` must be a bare imperial code.
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
