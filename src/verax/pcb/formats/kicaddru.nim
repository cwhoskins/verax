## KiCad custom design rules (`.kicad_dru`) writer: the routing rules an SI
## constraint derivation produced, as `length` and `via_count` constraints
## per net or net class, `clearance` between two nets (a crosstalk
## spacing) and `skew` within a differential pair. Write-only; constraints KiCad cannot express
## (backdrill, a termination value) stay in the constraint report.
##
## KiCad loads `<project>.kicad_dru` beside the `.kicad_pro`; `kicad-cli`
## has no standalone rule parser, so the acceptance gate
## (`tests/test_pcb_kicaddru.nim`) runs `kicad-cli pcb drc` on a fixture
## board with a deliberately violating track that **must** be reported.
## Proven on KiCad 10.0.6.

import std/[strutils, math]

type
  DruRule* = object
    name*: string
    condition*: string
      ## A KiCad rule expression; see `netCondition`/`netClassCondition`.
    maxLength*: float
      ## Metres; `NaN` = no length constraint.
    maxViaCount*: int
      ## `-1` = no via-count constraint.
    minClearance*: float
      ## Metres; `NaN` = no clearance constraint (use `pairCondition`).
    maxSkew*: float
      ## Length mismatch among the matched nets, metres; `NaN` = none (use
      ## `eitherCondition`).
    comment*: string
      ## Written as a `#` comment above the rule (provenance).

proc quoteKicad(s: string): string =
  ## KiCad expression strings are single-quoted inside a double-quoted
  ## condition; neither quote may appear in a net name we emit.
  if '\'' in s or '"' in s:
    raise newException(ValueError, "net name with a quote cannot be written to .kicad_dru: " & s)
  s

proc netCondition*(net: string): string =
  "A.NetName == '" & quoteKicad(net) & "'"

proc netClassCondition*(cls: string): string =
  "A.NetClass == '" & quoteKicad(cls) & "'"

proc pairCondition*(a, b: string): string =
  ## Items of net `a` against items of net `b`, in either order.
  "(A.NetName == '" & quoteKicad(a) & "' && B.NetName == '" & quoteKicad(b) &
    "') || (A.NetName == '" & quoteKicad(b) & "' && B.NetName == '" & quoteKicad(a) & "')"

proc eitherCondition*(a, b: string): string =
  ## An item of net `a` or of net `b`.
  "A.NetName == '" & quoteKicad(a) & "' || A.NetName == '" & quoteKicad(b) & "'"

proc druRule*(name, condition: string, maxLength = NaN, maxViaCount = -1,
              comment = "", minClearance = NaN, maxSkew = NaN): DruRule =
  DruRule(name: name, condition: condition, maxLength: maxLength,
          maxViaCount: maxViaCount, comment: comment, minClearance: minClearance,
          maxSkew: maxSkew)

proc renderDru*(rules: openArray[DruRule]): string =
  result = "(version 1)\n"
  for r in rules:
    if r.maxLength.isNaN and r.maxViaCount < 0 and r.minClearance.isNaN and
       r.maxSkew.isNaN: continue
    if '"' in r.name:
      raise newException(ValueError, "rule name with a double quote: " & r.name)
    for ln in r.comment.splitLines:
      if ln.len > 0: result.add "# " & ln & "\n"
    result.add "(rule \"" & r.name & "\"\n"
    result.add "  (condition \"" & r.condition & "\")"
    if not r.maxLength.isNaN:
      result.add "\n  (constraint length (max " & formatFloat(r.maxLength * 1e3, ffDecimal, 3) & "mm))"
    if r.maxViaCount >= 0:
      result.add "\n  (constraint via_count (max " & $r.maxViaCount & "))"
    if not r.minClearance.isNaN:
      result.add "\n  (constraint clearance (min " & formatFloat(r.minClearance * 1e3, ffDecimal, 3) & "mm))"
    if not r.maxSkew.isNaN:
      result.add "\n  (constraint skew (max " & formatFloat(r.maxSkew * 1e3, ffDecimal, 3) & "mm))"
    result.add ")\n"

proc writeDru*(rules: openArray[DruRule], path: string) =
  writeFile(path, renderDru(rules))
