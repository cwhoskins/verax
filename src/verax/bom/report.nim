## A `BomResult` rendered three ways:
##
##   * `render` -- text: lines, findings by severity, summary.
##   * `renderCsv` -- one row per line.
##   * `renderJson` -- `verax.bom/1`, which is **also the lockfile**
##     (`loadLock` reads each searched part's `signature`).

import std/[json, math, sequtils, strutils, tables]

import ../netlist/issue
import ./types

const BomSchema* = "verax.bom/1"

type
  LockError* = object of CatchableError
    ## An unusable `--bom-lock` file: a usage error, never silently skipped.

proc sevWord(s: Severity): string =
  case s
  of sevError: "error"
  of sevWarning: "warning"
  of sevInfo: "info"

proc familyWord(f: PartFamily): string =
  case f
  of pfResistor: "resistor"
  of pfCapacitor: "capacitor"
  of pfInductor: "inductor"
  of pfFerrite: "ferrite_bead"
  of pfOther: "other"
  of pfNotAPart: "not_a_part"

proc locked(line: BomLine): bool =
  ## Every item on the line was decided by the lock.
  if line.resolutions.len == 0: return false
  for r in line.resolutions:
    if not r.locked: return false
  true

proc resolved(line: BomLine): bool =
  line.resolutions.len > 0 and line.resolutions[0].chosen != nil

type Counts = tuple[parts, dnp, unresolved, excluded: int]

proc counts(r: BomResult): Counts =
  for x in r.resolutions:
    if x.item.excluded:
      inc result.excluded
      continue
    result.parts += x.item.quantity
    if x.item.doNotPopulate: result.dnp += x.item.quantity
    if x.chosen == nil and x.item.effectiveMpn.len == 0:
      result.unresolved += x.item.quantity

proc plural(n: int, word: string): string =
  $n & " " & word & (if n == 1: "" else: "s")

# --- text --------------------------------------------------------------------

proc render*(r: BomResult): string =
  let c = counts(r)
  var L: seq[string]
  var head = "BILL OF MATERIALS -- " & plural(r.lines.len, "line") & ", " &
    plural(c.parts, "part")
  if c.dnp > 0: head &= " (" & $c.dnp & " DNP)"
  if c.unresolved > 0: head &= ", " & $c.unresolved & " unresolved"
  if c.excluded > 0: head &= ", " & $c.excluded & " excluded"
  L.add head
  L.add ""

  var rows = @[@["QTY", "DESIGNATORS", "VALUE", "FOOTPRINT", "MANUFACTURER",
                 "MPN", "NOTE"]]
  for line in r.lines:
    var note: seq[string]
    if line.doNotPopulate: note.add "DNP"
    if line.locked: note.add "locked"
    if not line.resolved and line.mpn.len > 0: note.add "unverified"
    rows.add @[$line.quantity, line.designators.join(","),
               (if line.value.len > 0: line.value else: "-"),
               (if line.footprint.len > 0: line.footprint else: "-"),
               (if line.manufacturer.len > 0: line.manufacturer else: "-"),
               (if line.mpn.len > 0: line.mpn else: "(unresolved)"),
               note.join(", ")]
  var widths = newSeq[int](rows[0].len)
  for row in rows:
    for k, cell in row: widths[k] = max(widths[k], cell.len)
  for row in rows:
    var s = "  " & row[0].align(widths[0])
    for k in 1 ..< row.len:
      s &= "  " & (if k == row.high: row[k] else: row[k].alignLeft(widths[k]))
    L.add s.strip(leading = false)

  let issues = block:
    var all = r.issues
    for x in r.resolutions: all.add x.issues
    all
  var bySev: array[Severity, seq[Issue]]
  for i in issues: bySev[i.severity].add i
  for s in [sevError, sevWarning, sevInfo]:
    if bySev[s].len == 0: continue
    L.add ""
    L.add (case s
           of sevError: "ERRORS"
           of sevWarning: "WARNINGS"
           of sevInfo: "INFO") & " (" & $bySev[s].len & ")"
    for i in bySev[s]:
      L.add "  " & i.kind & "  " & i.message

  L.add ""
  L.add "summary: " & plural(r.lines.len, "line") & ", " &
    plural(bySev[sevError].len, "error") & ", " &
    plural(bySev[sevWarning].len, "warning") & ", " &
    $bySev[sevInfo].len & " info"
  L.join("\n")

# --- CSV ---------------------------------------------------------------------

proc csvField(s: string): string =
  ## RFC 4180 quoting (designators always contain commas).
  if s.contains({',', '"', '\n', '\r'}): "\"" & s.replace("\"", "\"\"") & "\""
  else: s

proc renderCsv*(r: BomResult): string =
  ## A header plus one row per line. Quantities count populated and DNP
  ## parts; excluded parts are on no row.
  var rows = @["Quantity,Designators,Value,Footprint,Manufacturer,MPN," &
               "Description,Datasheet,DNP"]
  for line in r.lines:
    rows.add [$line.quantity, line.designators.join(","), line.value,
              line.footprint, line.manufacturer, line.mpn, line.description,
              line.attrs.getOrDefault("datasheet"),
              (if line.doNotPopulate: "yes" else: "no")].map(csvField).join(",")
  rows.join("\n") & "\n"

# --- JSON --------------------------------------------------------------------

# Every float through `jnum`: bare `nan` isn't JSON.
proc jnum(x: float): JsonNode =
  if x.isNaN or x == Inf or x == -Inf: newJNull() else: newJFloat(x)

proc jint(n: int): JsonNode =
  ## Unknown stock and MOQ are `-1` in memory and `null` on the wire.
  if n < 0: newJNull() else: newJInt(n)

proc jstrs(xs: seq[string]): JsonNode =
  result = newJArray()
  for x in xs: result.add newJString(x)

proc issueJson(i: Issue): JsonNode =
  result = newJObject()
  result["kind"] = newJString(i.kind)
  result["severity"] = newJString(sevWord(i.severity))
  result["message"] = newJString(i.message)

proc candidateJson(c: Candidate): JsonNode =
  result = newJObject()
  result["manufacturer"] = newJString(c.manufacturer)
  result["mpn"] = newJString(c.mpn)
  result["value"] = jnum(c.value)
  result["tolerance"] = jnum(c.tolerance)
  result["stock"] = jint(c.avail.stock)
  result["moq"] = jint(c.avail.moq)
  result["lifecycle"] = newJString(c.avail.lifecycle)
  result["source"] = newJString(c.source)

proc partJson(x: Resolution): JsonNode =
  let i = x.item
  result = newJObject()
  result["designators"] = jstrs(i.designators)
  result["members"] = jstrs(i.members)
  result["kind"] = newJString(i.kind)
  result["family"] = newJString(familyWord(i.family))
  result["quantity"] = newJInt(i.quantity)
  result["dnp"] = newJBool(i.doNotPopulate)
  result["excluded"] = newJBool(i.excluded)
  var req = newJObject()
  req["value_text"] = newJString(i.valueText)
  req["value"] = jnum(i.value)
  req["tolerance"] = jnum(i.tolerance)
  req["voltage_rating"] = jnum(i.voltageRating)
  req["power_rating"] = jnum(i.powerRating)
  req["current_rating"] = jnum(i.currentRating)
  req["dielectric"] = newJString(i.dielectric)
  req["case_code"] = newJString(i.caseCode)
  req["footprint"] = newJString(i.footprint)
  req["package"] = newJString(i.package)
  req["part_number"] = newJString(i.partNumber)
  req["description"] = newJString(i.description)
  result["requirement"] = req
  result["signature"] = newJString(x.signature)
  let c = x.chosen
  result["resolved"] = newJBool(c != nil)
  result["manufacturer"] = newJString(if c != nil: c.manufacturer
                                      else: i.manufacturer)
  result["mpn"] = newJString(if c != nil: c.mpn else: i.effectiveMpn)
  result["source"] = newJString(if c != nil: c.source else: "")
  result["locked"] = newJBool(x.locked)
  result["candidates"] = newJInt(x.candidates)
  result["chosen"] = (if c != nil: candidateJson(c) else: newJNull())
  var alts = newJArray()
  for a in x.alternates: alts.add candidateJson(a)
  result["alternates"] = alts
  var assumed = newJArray()
  for a in i.assumptions:
    var o = newJObject()
    o["key"] = newJString(a.key)
    o["value"] = jnum(a.value)
    o["unit"] = newJString(a.unit)
    o["detail"] = newJString(a.detail)
    assumed.add o
  result["assumptions"] = assumed
  var iss = newJArray()
  for e in x.issues: iss.add issueJson(e)
  result["issues"] = iss

proc renderJson*(r: BomResult): string =
  ## `parts[]` has every item (excluded included) in collection order; lines
  ## reference parts by index.
  var root = newJObject()
  root["schema"] = newJString(BomSchema)
  var index = initTable[pointer, int]()
  var parts = newJArray()
  for k, x in r.resolutions:
    index[cast[pointer](x)] = k
    parts.add partJson(x)
  var lines = newJArray()
  for line in r.lines:
    var o = newJObject()
    o["quantity"] = newJInt(line.quantity)
    o["designators"] = jstrs(line.designators)
    o["value"] = newJString(line.value)
    o["footprint"] = newJString(line.footprint)
    o["manufacturer"] = newJString(line.manufacturer)
    o["mpn"] = newJString(line.mpn)
    o["description"] = newJString(line.description)
    o["part_number"] = newJString(line.partNumber)
    o["datasheet"] = newJString(line.attrs.getOrDefault("datasheet"))
    o["source"] = newJString(line.attrs.getOrDefault("source"))
    o["dnp"] = newJBool(line.doNotPopulate)
    o["locked"] = newJBool(line.locked)
    var refs = newJArray()
    for x in line.resolutions: refs.add newJInt(index[cast[pointer](x)])
    o["parts"] = refs
    lines.add o
  root["lines"] = lines
  root["parts"] = parts
  var iss = newJArray()
  for e in r.issues: iss.add issueJson(e)
  root["issues"] = iss
  let c = counts(r)
  var worst = sevInfo
  var nSev: array[Severity, int]
  for e in r.issues:
    inc nSev[e.severity]
    worst = max(worst, e.severity)
  for x in r.resolutions:
    for e in x.issues:
      inc nSev[e.severity]
      worst = max(worst, e.severity)
  var s = newJObject()
  s["lines"] = newJInt(r.lines.len)
  s["parts"] = newJInt(c.parts)
  s["dnp"] = newJInt(c.dnp)
  s["unresolved"] = newJInt(c.unresolved)
  s["excluded"] = newJInt(c.excluded)
  s["errors"] = newJInt(nSev[sevError])
  s["warnings"] = newJInt(nSev[sevWarning])
  s["infos"] = newJInt(nSev[sevInfo])
  s["worst"] = newJString(sevWord(worst))
  root["summary"] = s
  root.pretty

# --- the lockfile ------------------------------------------------------------

proc parseLock*(text: string, origin = "<string>"): Table[string, LockEntry] =
  ## Every resolved part with a `signature` (chosen by search), keyed on it.
  ## MPN-bought parts aren't locked. Two parts sharing a signature must
  ## agree, else the file is refused.
  var j: JsonNode
  try:
    j = parseJson(text)
  except CatchableError as e:
    raise newException(LockError,
      "cannot parse lock '" & origin & "' as JSON: " & e.msg)
  if j.isNil or j.kind != JObject or j{"schema"}.getStr("") != BomSchema:
    raise newException(LockError, "'" & origin & "' is not a " & BomSchema &
      " document -- pass a file `verax bom --bom-format=json` wrote")
  if j{"parts"}.isNil or j["parts"].kind != JArray:
    raise newException(LockError, "'" & origin & "' has no 'parts' array")
  for p in j["parts"]:
    let sig = p{"signature"}.getStr("")
    let mpn = p{"mpn"}.getStr("")
    if sig.len == 0 or mpn.len == 0 or not p{"resolved"}.getBool(false):
      continue
    let mfr = p{"manufacturer"}.getStr("")
    var designators: seq[string]
    if not p{"designators"}.isNil and p["designators"].kind == JArray:
      for d in p["designators"]: designators.add d.getStr("")
    if sig in result:
      let prior = result[sig]
      if cmpIgnoreCase(prior.mpn, mpn) != 0 or
          cmpIgnoreCase(prior.manufacturer, mfr) != 0:
        raise newException(LockError, "'" & origin & "' locks one " &
          "requirement to two parts (" & prior.manufacturer & " " &
          prior.mpn & " for " & prior.designators.join(",") & ", " & mfr &
          " " & mpn & " for " & designators.join(",") & "): " & sig)
      result[sig].designators.add designators
    else:
      result[sig] = LockEntry(signature: sig, mpn: mpn, manufacturer: mfr,
                              designators: designators)

proc loadLock*(path: string): Table[string, LockEntry] =
  ## `parseLock` of a file; an unreadable file is a `LockError` too.
  var text: string
  try:
    text = readFile(path)
  except IOError as e:
    raise newException(LockError, "cannot read lock '" & path & "': " & e.msg)
  parseLock(text, path)
