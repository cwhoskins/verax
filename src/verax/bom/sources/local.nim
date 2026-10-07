## The hermetic catalogue source: a JSON file of orderable parts, loaded into
## memory and searched by a linear scan with `source.matches`.
##
## This is a project's preferred-parts list (the "preferred-parts database"
## `parts/CLAUDE.md` points at) and every resolver test's fixture. A list of
## hundreds to a few thousand rows is microseconds to scan, so there is no
## index and no database: a real one would cost the library its
## standard-library-only rule (`db_sqlite` left the stdlib in Nim 2) and
## buy nothing at this size. The catalogue of millions is a distributor's,
## reached by a network source.
##
## ```json
## { "schema": "verax.catalog/1",
##   "parts": [
##     { "mpn": "RC0402FR-0710KL", "manufacturer": "Yageo",
##       "family": "resistor", "value": 10000, "tolerance": 0.01,
##       "caseCode": "0402", "powerRating": 0.0625,
##       "stock": 1200000, "lifecycle": "active",
##       "attrs": { "ipn": "R-0001" } } ] }
## ```
##
## **Strict.** A file with any problem -- an unknown field, a family that is
## not one of `CatalogFamilies`, a `value` written as a string, a tolerance
## of `1` meaning 1 %, a duplicate `(manufacturer, mpn)` -- raises
## `CatalogError` naming every problem by row, and nothing is loaded. A
## skipped row would be a catalogue quietly missing the part it was meant to
## pin.
##
## Not registered on import: a file-backed source has nothing to answer with
## until it is given a file. `registerCatalogFile` loads and registers one.

import std/[json, math, sequtils, strutils, tables]

import ../types
import ../classify
import ../source

const
  CatalogSchema* = "verax.catalog/1"
  CatalogFamilies* = {
      "resistor": pfResistor, "capacitor": pfCapacitor,
      "inductor": pfInductor, "ferrite_bead": pfFerrite, "other": pfOther,
    }
    ## The `family` spellings a row may use -- the component kinds
    ## `classify.builtinPartFamilies` maps, plus `other` for everything
    ## bought by MPN.
  Lifecycles* = ["active", "nrnd", "obsolete"]

type
  CatalogError* = object of CatchableError
    problems*: seq[string]
      ## One line per problem, each naming its row (`parts[3]`).

  Catalog* = ref object
    origin*: string
      ## The file it was read from, or the caller's label for a string.
    parts*: seq[Candidate]

const partFields = ["mpn", "manufacturer", "family", "description",
  "datasheet", "package", "caseCode", "value", "tolerance", "voltageRating",
  "powerRating", "currentRating", "dielectric", "stock", "moq", "lifecycle",
  "attrs"]

proc familyName(f: PartFamily): string =
  for (n, x) in CatalogFamilies:
    if x == f: return n
  $f

proc readPart(row: JsonNode, family: PartFamily, c: Candidate,
              bad: proc (msg: string)) =
  proc str(key: string): string =
    if not row.hasKey(key): return ""
    let n = row[key]
    if n.kind != JString:
      bad key & " must be a string, got " & $n.kind
      return ""
    n.getStr.strip

  proc num(key: string, positive = true): float =
    if not row.hasKey(key): return NaN
    let n = row[key]
    if n.kind notin {JInt, JFloat}:
      bad key & " must be a number in SI base units, got " &
        (if n.kind == JString: "the string " & n.getStr.escape else: $n.kind)
      return NaN
    result = n.getFloat
    if result.classify in {fcNan, fcInf, fcNegInf} or
        (positive and result <= 0):
      bad key & " must be a positive finite number, got " & $result
      return NaN

  proc count(key: string, minimum: int): int =
    if not row.hasKey(key): return -1
    let n = row[key]
    if n.kind != JInt or n.getBiggestInt < minimum:
      bad key & " must be an integer >= " & $minimum & ", got " & $n
      return -1
    n.getBiggestInt.int

  c.description = str("description")
  c.datasheet = str("datasheet")
  c.package = str("package")
  c.dielectric = str("dielectric")
  c.value = num("value")
  c.tolerance = num("tolerance")
  c.voltageRating = num("voltageRating")
  c.powerRating = num("powerRating")
  c.currentRating = num("currentRating")
  c.avail = Availability(stock: count("stock", 0), moq: count("moq", 1),
                         lifecycle: str("lifecycle").toLowerAscii)

  if not c.tolerance.isNaN and c.tolerance >= 1:
    bad "tolerance is a fraction (0.01 is 1 %), got " & $c.tolerance
  if c.avail.lifecycle.len > 0 and c.avail.lifecycle notin Lifecycles:
    bad "lifecycle must be one of " & Lifecycles.join(", ") & ", got " &
      c.avail.lifecycle.escape

  let cc = str("caseCode")
  if cc.len > 0:
    c.caseCode = caseCodeOf("", cc)
    if c.caseCode.len == 0:
      bad "caseCode " & cc.escape & " is not a standard imperial chip case code"
  elif c.package.len > 0:
    c.caseCode = caseCodeOf("", c.package)

  if family.isParametric:
    if c.value.isNaN and not row.hasKey("value"):
      bad "a " & familyName(family) & " must state value"
  else:
    for key in ["value", "tolerance", "dielectric", "caseCode"]:
      if row.hasKey(key):
        bad key & " is only read for a parametric family, not " &
          familyName(family)

  if row.hasKey("attrs"):
    let a = row["attrs"]
    if a.kind != JObject:
      bad "attrs must be an object of strings"
    else:
      for k, v in a:
        if v.kind != JString: bad "attrs." & k & " must be a string"
        else: c.attrs[k] = v.getStr

proc parseCatalog*(text: string, origin = "<string>"): Catalog =
  ## Parses a catalogue document, raising `CatalogError` listing every
  ## problem found if there is any.
  var problems: seq[string]
  result = Catalog(origin: origin)
  let doc =
    try: parseJson(text)
    except JsonParsingError as e:
      raise (ref CatalogError)(msg: origin & ": not valid JSON: " & e.msg,
                               problems: @["not valid JSON: " & e.msg])
  if doc.kind != JObject:
    problems.add "the document must be an object with schema and parts"
  else:
    for k, _ in doc:
      if k notin ["schema", "parts"]:
        problems.add "unknown top-level field " & k.escape
    let schema = doc{"schema"}
    if schema == nil or schema.kind != JString or schema.getStr != CatalogSchema:
      problems.add "schema must be " & CatalogSchema.escape &
        (if schema == nil: ", and is missing" else: ", got " & $schema)
    let parts = doc{"parts"}
    if parts == nil or parts.kind != JArray:
      problems.add "parts must be an array"
    else:
      var seen: Table[string, int]
      for i, row in parts.elems:
        var label = "parts[" & $i & "]"
        if row.kind != JObject:
          problems.add label & ": must be an object"
          continue
        let mpnNode = row{"mpn"}
        if mpnNode != nil and mpnNode.kind == JString:
          label.add " (" & mpnNode.getStr & ")"
        let at = label
        proc bad(msg: string) = problems.add at & ": " & msg
        for k, _ in row:
          if k notin partFields: bad "unknown field " & k.escape
        let c = Candidate(source: "local", value: NaN, tolerance: NaN,
                          voltageRating: NaN, powerRating: NaN,
                          currentRating: NaN,
                          avail: unknownAvailability())
        for key in ["mpn", "manufacturer"]:
          let n = row{key}
          if n == nil or n.kind != JString or n.getStr.strip.len == 0:
            bad key & " is required and must be a non-empty string"
        c.mpn = row{"mpn"}.getStr.strip
        c.manufacturer = row{"manufacturer"}.getStr.strip
        let fam = row{"family"}
        var known = false
        if fam != nil and fam.kind == JString:
          for (n, f) in CatalogFamilies:
            if n == fam.getStr.strip.toLowerAscii:
              c.family = f
              known = true
        if not known:
          bad "family must be one of " &
            CatalogFamilies.mapIt(it[0]).join(", ") &
            (if fam == nil: ", and is missing" else: ", got " & $fam)
          continue
        readPart(row, c.family, c, bad)
        if c.mpn.len > 0 and c.manufacturer.len > 0:
          let k = partKey(c.manufacturer, c.mpn)
          if k in seen:
            bad "duplicates parts[" & $seen[k] & "] (" & c.manufacturer &
              " " & c.mpn & ")"
          else:
            seen[k] = i
        result.parts.add c
  if problems.len > 0:
    raise (ref CatalogError)(
      msg: origin & ": " & $problems.len & " problem(s) in the catalogue:\n  " &
        problems.join("\n  "),
      problems: problems)

proc loadCatalog*(path: string): Catalog =
  ## Reads and parses a catalogue file. An unreadable file is a
  ## `CatalogError` too, so a caller has one exception to report.
  let text =
    try: readFile(path)
    except IOError as e:
      raise (ref CatalogError)(msg: path & ": cannot read catalogue: " & e.msg,
                               problems: @["cannot read: " & e.msg])
  parseCatalog(text, path)

proc search*(cat: Catalog, q: PartQuery): seq[Candidate] =
  ## Every part matching `q`, in file order, as caller-owned copies.
  ## Ranking is the resolver's job; `q.manufacturers` is ignored here.
  for c in cat.parts:
    if q.limit > 0 and result.len >= q.limit: break
    if c.matches(q): result.add copyCandidate(c)

proc lookup*(cat: Catalog, mpn: string, manufacturer = ""): Candidate =
  ## The part with this MPN (and manufacturer, when given), ignoring case;
  ## the first in file order when the manufacturer is not given and two
  ## manufacturers share the MPN. `nil` when unknown.
  let m = mpn.strip.toLowerAscii
  let mf = manufacturer.strip.toLowerAscii
  for c in cat.parts:
    if c.mpn.toLowerAscii == m and
        (mf.len == 0 or c.manufacturer.toLowerAscii == mf):
      return copyCandidate(c)
  nil

proc catalogSource*(cat: Catalog, name = "local"): CatalogSource =
  ## A `CatalogSource` answering from `cat`. Its candidates carry `name` as
  ## their `source`.
  proc stamp(c: Candidate): Candidate =
    if c != nil: c.source = name
    c
  CatalogSource(
    name: name,
    search: proc (q: PartQuery): seq[Candidate] =
      result = cat.search(q)
      for c in result: discard stamp(c),
    lookup: proc (mpn, manufacturer: string): Candidate =
      stamp(cat.lookup(mpn, manufacturer)))

proc registerCatalogFile*(path: string, name = "local"): Catalog =
  ## Loads `path` and registers it as a source, after any already
  ## registered. Raises `CatalogError` before registering anything.
  result = loadCatalog(path)
  registerCatalogSource(catalogSource(result, name))
