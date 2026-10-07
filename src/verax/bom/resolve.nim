## `BomItem`s -> `BomResult`: which orderable part each item is, per the
## registered `CatalogSource`s.
##
## Per item, in order:
##
##   1. **Excluded** (`bom_exclude`): on no line (`bom_excluded`).
##   2. **An MPN, for every family.** A stated `mpn` is authoritative; one no
##      source knows is `bom_part_not_found` (warning) and stays on the BOM.
##      With no `mpn`, `partNumber` stands in, always visibly
##      (`bom_partnumber_used_as_mpn`: info if a source knows it, warning if
##      not -- it may be a free-text label).
##   3. **A parametric search** for an R/C/L/ferrite with no MPN: refused
##      without a case code (`bom_nonstandard_footprint`) or value. A
##      matching `LockEntry` wins while its part is still offered and fits;
##      otherwise candidates are ranked.
##   4. **Nothing resolved**: `bom_mpn_required` or `bom_no_match` (error if
##      assembled, info if DNP).
##
## Items roll up into `BomLine`s by `(manufacturer, mpn)`, DNP separately,
## with a stock check per line.
##
## Of the `bom:` defaults only `manufacturers` is read here (`collect`
## applied the rest). `series` and `derating` are not: the design's value is
## bought as stated, and derating needs voltages a BOM doesn't know.

import std/[algorithm, math, strutils, tables]

import ../netlist/types
import ../netlist/issue
import ../netlist/bomdefaults
import ../eng
import ./types
import ./source

const
  KindBomExcluded* = "bom_excluded"
  KindBomPartNotFound* = "bom_part_not_found"
  KindBomPartObsolete* = "bom_part_obsolete"
  KindBomPartNrnd* = "bom_part_nrnd"
  KindBomPartnumberUsedAsMpn* = "bom_partnumber_used_as_mpn"
  KindBomMpnSpecMismatch* = "bom_mpn_spec_mismatch"
  KindBomMpnRequired* = "bom_mpn_required"
  KindBomNonstandardFootprint* = "bom_nonstandard_footprint"
  KindBomNoMatch* = "bom_no_match"
  KindBomLockStale* = "bom_lock_stale"
  KindBomUncommonPart* = "bom_uncommon_part"
  KindBomLowStock* = "bom_low_stock"
  KindBomNoSources* = "bom_no_sources"

type
  ResolveOptions* = object
    minCandidates*: int
      ## Fewer distinct matching parts than this is `bom_uncommon_part`;
      ## `0` disables the check.
    stockFactor*: float
      ## A line whose part has fewer than `quantity * stockFactor` in stock
      ## is `bom_low_stock`; `0` disables it. Unknown stock is never flagged.
    maxAlternates*: int
    lock*: Table[string, LockEntry]
      ## A previous result's decisions, keyed on `signature` (`loadLock`).

proc defaultResolveOptions*(): ResolveOptions =
  ResolveOptions(minCandidates: 3, stockFactor: 10.0, maxAlternates: 3)

# --- describing a requirement ------------------------------------------------

proc familyWord(f: PartFamily): string =
  case f
  of pfResistor: "resistor"
  of pfCapacitor: "capacitor"
  of pfInductor: "inductor"
  of pfFerrite: "ferrite_bead"
  of pfOther: "other"
  of pfNotAPart: "not_a_part"

proc valueUnit(f: PartFamily): string =
  case f
  of pfResistor, pfFerrite: "ohm"
  of pfCapacitor: "F"
  of pfInductor: "H"
  else: ""

proc canon(x: float): string =
  if x.isNaN: "-" else: formatFloat(x, ffScientific, 6)

proc signatureOf*(i: BomItem): string =
  ## The lockfile key: the requirement, never the designator (generated
  ## designators renumber). Identical requirements share a part on purpose.
  ## `""` for a non-searched family.
  if not i.family.isParametric: return ""
  [familyWord(i.family), canon(i.value), canon(i.tolerance),
   i.caseCode.toUpperAscii, i.dielectric.toUpperAscii,
   canon(i.voltageRating), canon(i.powerRating),
   canon(i.currentRating)].join("|")

proc pct(x: float): string =
  var s = formatFloat(x * 100, ffDecimal, 3)
  s.trimZeros()
  s & " %"

proc describe(i: BomItem): string =
  ## `22 nF ±5 % C0G 0402 ≥50 V`, for a message.
  var parts = @[eng(i.value, valueUnit(i.family))]
  if not i.tolerance.isNaN: parts.add "±" & pct(i.tolerance)
  if i.dielectric.len > 0: parts.add i.dielectric
  parts.add(if i.caseCode.len > 0: i.caseCode else: "(no case code)")
  if not i.voltageRating.isNaN: parts.add ">=" & eng(i.voltageRating, "V")
  if not i.powerRating.isNaN: parts.add ">=" & eng(i.powerRating, "W")
  if not i.currentRating.isNaN: parts.add ">=" & eng(i.currentRating, "A")
  parts.add familyWord(i.family)
  parts.join(" ")

proc queryOf*(i: BomItem): PartQuery =
  ## The search for an item's requirement. The nominal may sit within the
  ## item's tolerance; `fitsBand` then requires the whole band to.
  result = newPartQuery(i.family, i.value, i.caseCode)
  result.valueTolerance = i.tolerance
  result.maxTolerance = i.tolerance
  result.minVoltage = i.voltageRating
  result.minPower = i.powerRating
  result.minCurrent = i.currentRating
  result.dielectric = i.dielectric

proc fitsBand(c: Candidate, i: BomItem): bool =
  ## A candidate's whole band (nominal +/- tolerance) inside the item's: a
  ## 9.76 k 1 % part fits a 10 k 5 % requirement, a 9.76 k 5 % doesn't. No
  ## stated tolerance means an exact nominal (enforced by `matches`).
  if i.tolerance.isNaN: return true
  let ct = if c.tolerance.isNaN: 0.0 else: c.tolerance
  abs(c.value - i.value) + ct * abs(c.value) <=
    i.tolerance * abs(i.value) * (1 + 1e-9)

proc isExact(c: Candidate, i: BomItem): bool =
  abs(c.value - i.value) <= 1e-9 * abs(i.value)

# --- ranking -----------------------------------------------------------------

proc lifecycleRank(c: Candidate): int =
  case c.avail.lifecycle
  of "nrnd": 1
  of "obsolete": 2
  else: 0

proc rank(cands: var seq[Candidate], i: BomItem, preferred: seq[string]) =
  ## Lifecycle (active/unknown, NRND, obsolete), preferred manufacturer,
  ## exact value over in-band, stock descending (unknown last), then MPN and
  ## manufacturer, for byte-identical reruns.
  proc pref(c: Candidate): int =
    for k, m in preferred:
      if cmpIgnoreCase(m.strip, c.manufacturer) == 0: return k
    preferred.len
  cands.sort(proc (a, b: Candidate): int =
    result = cmp(lifecycleRank(a), lifecycleRank(b))
    if result != 0: return
    result = cmp(pref(a), pref(b))
    if result != 0: return
    result = cmp(not isExact(a, i), not isExact(b, i))
    if result != 0: return
    result = cmp(b.avail.stock, a.avail.stock)
    if result != 0: return
    result = cmp(a.mpn.toLowerAscii, b.mpn.toLowerAscii)
    if result != 0: return
    result = cmp(a.manufacturer.toLowerAscii, b.manufacturer.toLowerAscii))

# --- per item ----------------------------------------------------------------

proc who(i: BomItem): string = i.designators.join(",")

proc add(r: Resolution, kind: string, sev: Severity, msg: string) =
  r.issues.add newIssue(kind, sev, who(r.item) & ": " & msg,
                        components = r.item.components)

proc unresolvedSeverity(i: BomItem): Severity =
  ## An error only for a part that reaches assembly.
  if i.doNotPopulate: sevInfo else: sevError

proc checkLifecycle(r: Resolution, c: Candidate) =
  let at = c.manufacturer & " " & c.mpn & " (from " & c.source & ")"
  case c.avail.lifecycle
  of "obsolete":
    r.add(KindBomPartObsolete, sevWarning, at & " is obsolete.")
  of "nrnd":
    r.add(KindBomPartNrnd, sevWarning, at &
      " is not recommended for new designs.")
  else: discard

proc checkSpec(r: Resolution, c: Candidate) =
  ## An MPN-bought part against what the design states; only facts both
  ## sides state are compared.
  let i = r.item
  if not i.family.isParametric or i.value.isNaN: return
  var why: seq[string]
  if c.family != i.family:
    why.add "it is a " & familyWord(c.family) & ", not a " & familyWord(i.family)
  elif not c.value.isNaN and not isExact(c, i) and not fitsBand(c, i):
    why.add "its value is " & eng(c.value, valueUnit(i.family)) & ", not " &
      eng(i.value, valueUnit(i.family))
  if i.caseCode.len > 0 and c.caseCode.len > 0 and
      cmpIgnoreCase(i.caseCode, c.caseCode) != 0:
    why.add "its case code is " & c.caseCode & ", not " & i.caseCode
  if i.dielectric.len > 0 and c.dielectric.len > 0 and
      cmpIgnoreCase(i.dielectric, c.dielectric) != 0:
    why.add "its dielectric is " & c.dielectric & ", not " & i.dielectric
  template under(have, want: float, unit, what: string) =
    if not want.isNaN and not have.isNaN and have < want:
      why.add "its " & what & " is " & eng(have, unit) & ", under " &
        eng(want, unit)
  under(c.voltageRating, i.voltageRating, "V", "voltage rating")
  under(c.powerRating, i.powerRating, "W", "power rating")
  under(c.currentRating, i.currentRating, "A", "current rating")
  if why.len > 0:
    r.add(KindBomMpnSpecMismatch, sevWarning, c.manufacturer & " " & c.mpn &
      " does not meet what the design states: " & why.join("; ") & ".")

proc byMpn(r: Resolution): bool =
  ## Step 2: true when the item is settled by MPN (resolved or not), false
  ## to go on to a search.
  let i = r.item
  if i.mpn.len > 0:
    let c = lookupAll(i.mpn, i.manufacturer)
    if c == nil:
      r.add(KindBomPartNotFound, sevWarning, "no catalogue source knows " &
        (if i.manufacturer.len > 0: i.manufacturer & " " else: "") & i.mpn &
        "; it stays on the BOM as stated, unverified.")
    else:
      r.chosen = c
      checkLifecycle(r, c)
      checkSpec(r, c)
    return true
  if i.partNumber.strip.len > 0:
    let c = lookupAll(i.partNumber.strip, i.manufacturer)
    if c != nil:
      r.chosen = c
      r.add(KindBomPartnumberUsedAsMpn, sevInfo, "states no mpn; its part " &
        "number " & i.partNumber.escape & " was recognised as " &
        c.manufacturer & " " & c.mpn & " and used. State mpn = " &
        c.mpn.escape & " to make that the design's decision.")
      checkLifecycle(r, c)
      checkSpec(r, c)
    else:
      r.add(KindBomPartnumberUsedAsMpn, sevWarning, "states no mpn; its " &
        "part number " & i.partNumber.strip.escape & " is ordered as the " &
        "mpn, unverified -- no catalogue source knows it. State the real " &
        "mpn if that is a label rather than an orderable part.")
    return true
  false

proc bySearch(r: Resolution, opts: ResolveOptions) =
  let i = r.item
  r.signature = signatureOf(i)
  if i.caseCode.len == 0:
    let stated =
      if i.footprint.len == 0 and i.package.len == 0:
        "states neither a footprint nor a package"
      else:
        "has no standard case code (footprint " & i.footprint.escape &
          ", package " & i.package.escape & ")"
    r.add(KindBomNonstandardFootprint, sevWarning, stated & ", so no part " &
      "is searched for that might not fit its land pattern. State its " &
      "package (e.g. \"0402\") or its mpn.")
  if i.caseCode.len == 0 or i.value.isNaN:
    r.add(KindBomMpnRequired, unresolvedSeverity(i), "cannot be searched " &
      "for and states no mpn.")
    return
  var cands: seq[Candidate]
  for c in searchAll(queryOf(i)):
    if fitsBand(c, i): cands.add c
  r.candidates = cands.len
  if cands.len == 0:
    r.add(KindBomNoMatch, unresolvedSeverity(i), "no orderable part matches " &
      describe(i) & ".")
    return
  if opts.minCandidates > 0 and cands.len < opts.minCandidates:
    r.add(KindBomUncommonPart, sevInfo, "only " & $cands.len &
      " orderable part" & (if cands.len == 1: "" else: "s") & " match " &
      describe(i) & " -- this is an uncommon part.")
  let preferred =
    if i.components.len > 0: bomDefaults(i.components[0].netlist).manufacturers
    else: @[]
  rank(cands, i, preferred)
  var chosenAt = 0
  if r.signature in opts.lock:
    let e = opts.lock[r.signature]
    chosenAt = -1
    for k, c in cands:
      if partKey(c.manufacturer, c.mpn) == partKey(e.manufacturer, e.mpn) and
          c.avail.lifecycle != "obsolete":
        chosenAt = k
        r.locked = true
    if chosenAt < 0:
      r.add(KindBomLockStale, sevInfo, "the lock chose " & e.manufacturer &
        " " & e.mpn & ", which no source now offers as a current part " &
        "meeting " & describe(i) & "; ranked afresh.")
      chosenAt = 0
  r.chosen = cands[chosenAt]
  for k, c in cands:
    if k != chosenAt and r.alternates.len < opts.maxAlternates:
      r.alternates.add c
  checkLifecycle(r, r.chosen)

proc resolveItem*(i: BomItem, opts = defaultResolveOptions()): Resolution =
  result = Resolution(item: i, issues: i.issues)
  if i.excluded:
    result.add(KindBomExcluded, sevInfo, "is marked bom_exclude and is left " &
      "off the BOM.")
    return
  if byMpn(result): return
  if i.family.isParametric:
    bySearch(result, opts)
  else:
    result.add(KindBomMpnRequired, unresolvedSeverity(i), "states no mpn, " &
      "and a part of kind " & i.kind.escape & " is bought by part number.")

# --- roll-up -----------------------------------------------------------------

proc lineKey(r: Resolution): string =
  let i = r.item
  let dnp = if i.doNotPopulate: "|DNP" else: ""
  if r.chosen != nil: return "mpn:" & partKey(r.chosen.manufacturer,
                                               r.chosen.mpn) & dnp
  if i.effectiveMpn.len > 0:
    return "mpn:" & partKey(i.manufacturer, i.effectiveMpn) & dnp
  # Unresolved: one line per identical requirement, so missing parts are
  # still listed.
  if r.signature.len > 0: return "sig:" & r.signature & dnp
  "item:" & i.kind & "|" & i.valueText & "|" & i.footprint & "|" &
    i.partNumber & dnp

proc resolve*(items: seq[BomItem], opts = defaultResolveOptions()): BomResult =
  ## Resolves every item against the registered sources and rolls the
  ## result up into lines, in collection order.
  result = BomResult()
  if catalogSources().len == 0:
    result.issues.add newIssue(KindBomNoSources, sevWarning, "no catalogue " &
      "source is registered, so nothing can be verified or searched for.")
  var byKey: Table[string, BomLine]
  for i in items:
    let r = resolveItem(i, opts)
    result.resolutions.add r
    if i.excluded: continue
    let k = lineKey(r)
    var line = byKey.getOrDefault(k)
    if line == nil:
      let c = r.chosen
      # Print a parsed value through `eng`, not the raw `3.000000000e-06`.
      let shown =
        if i.family.isParametric and not i.value.isNaN:
          eng(i.value, valueUnit(i.family))
        else: i.valueText
      line = BomLine(key: k, value: shown, footprint: i.footprint,
                     partNumber: i.partNumber,
                     doNotPopulate: i.doNotPopulate)
      if c != nil:
        line.manufacturer = c.manufacturer
        line.mpn = c.mpn
        line.description =
          if c.description.len > 0: c.description else: i.description
        if c.datasheet.len > 0: line.attrs["datasheet"] = c.datasheet
        if c.source.len > 0: line.attrs["source"] = c.source
      else:
        line.manufacturer = i.manufacturer
        line.mpn = i.effectiveMpn
        line.description = i.description
      if line.footprint.len == 0: line.footprint = i.package
      byKey[k] = line
      result.lines.add line
    line.designators.add i.designators
    line.quantity += i.quantity
    line.resolutions.add r

  if opts.stockFactor > 0:
    for line in result.lines:
      if line.doNotPopulate: continue
      let c = line.resolutions[0].chosen
      if c == nil or c.avail.stock < 0: continue
      let want = float(line.quantity) * opts.stockFactor
      if float(c.avail.stock) < want:
        result.issues.add newIssue(KindBomLowStock, sevInfo,
          line.designators.join(",") & ": " & c.manufacturer & " " & c.mpn &
          " has " & $c.avail.stock & " in stock (" & c.source & "), under " &
          $want.int & " (" & $line.quantity & " used x " &
          $opts.stockFactor & ").")

proc allIssues*(r: BomResult): seq[Issue] =
  ## Every finding: the result's own, then each resolution's in order.
  result = r.issues
  for x in r.resolutions: result.add x.issues

proc worstSeverity*(r: BomResult): Severity =
  result = sevInfo
  for x in allIssues(r):
    if x.severity > result: result = x.severity
