## Real-corpus check for `verax/pcb/trace` and `verax/pcb/tline` -- a
## **task, not a test** (`nimble traces`), on the same reasoning
## `examples/pcb_roundtrip.nim` states for `nimble roundtrip`: this is the
## only way to find out whether the stitching tolerances and the reference
## plane's coverage threshold survive real data, and a `/usr/share/kicad`
## sweep has no place inside `nimble test`'s per-commit budget.
##
## For every `*.kicad_pcb` under the given root (default
## `/usr/share/kicad/demos`) whose stackup states at least one material's
## `epsilonR` -- a board with no stackup has no dielectric to resolve a
## reference plane's height/er/tand against, so `extractRoutes` still runs
## but every section would trivially decline (`route_no_reference` or
## `reference_unfilled`), which would tell us nothing about whether the
## stitching itself is right -- extracts every net and reports: how many
## nets extracted as a single connected island versus split
## (`route_disconnected`), how many sections resolved a reference plane
## (at or above `minCoverage`, below it, or not at all), and every issue
## kind seen, so a loop or a tolerance join that looks wrong shows up as a
## number to go look at rather than silently passing.
##
## Run with:
##   nim c -d:release -r --path:./src examples/pcb_traces.nim [root]

import std/[algorithm, os, strformat, strutils, tables, times]

import verax/pcb
import verax/pcb/formats/kicad

proc findBoards(root: string): seq[string] =
  for f in walkDirRec(root):
    if f.endsWith(".kicad_pcb"): result.add(f)
  result.sort()

proc hasPopulatedStackup(pcb: Pcb): bool =
  if pcb.stackup == nil: return false
  for e in pcb.stackup.entries:
    if e.material != nil and e.material.epsilonR > 0.0: return true
  false

type BoardTotals = object
  nets, singleIsland, splitIsland: int
  sections, sectionsFullRef, sectionsGapRef, sectionsNoRef: int
  issueCounts: CountTable[string]

proc processBoard(pcb: Pcb): BoardTotals =
  for _, net in pcb.netlist.nets:
    if pcb.copperOn(net).len == 0: continue
    inc result.nets
    let graphs = extractRoutes(pcb, net)
    if graphs.len == 1: inc result.singleIsland
    elif graphs.len > 1: inc result.splitIsland
    for g in graphs:
      for i in g.issues: result.issueCounts.inc(i.kind)
      for e in g.edges:
        for s in e.sections:
          inc result.sections
          if s.reference.layer == nil: inc result.sectionsNoRef
          elif s.reference.coverage >= 0.9: inc result.sectionsFullRef
          else: inc result.sectionsGapRef

proc main() =
  let root = if paramCount() >= 1: paramStr(1) else: "/usr/share/kicad/demos"
  if not dirExists(root):
    echo "pcb_traces: no such directory: ", root
    quit(1)
  let boards = findBoards(root)
  if boards.len == 0:
    echo "pcb_traces: no .kicad_pcb files found under ", root
    quit(1)

  var examined, processed, skipped, refused, crashed = 0
  var grand: BoardTotals
  var worstLoops: seq[tuple[path: string, loops: int]] = @[]

  for path in boards:
    inc examined
    let t0 = epochTime()
    var pcb: Pcb
    try:
      pcb = readPcb(path)
    except PcbFormatError as e:
      # Refused *by name*, not a crash -- `RoyalBlue54L-Feather.kicad_pcb`
      # is the documented case (`pcb/CLAUDE.md`, `pcb_roundtrip.nim`'s own
      # `readRefused` counter): 349 missing opening parens in the shipped
      # demo corpus itself, correctly caught and reported by `readPcb`
      # rather than partially parsed. Counting this as a crash would hide a
      # working refusal behind the same label as an actual bug.
      stdout.write(path, "  READ REFUSED: ", e.msg, "\n")
      inc refused
      continue
    except CatchableError as e:
      stdout.write(path, "  READ CRASHED: ", e.msg, "\n")
      inc crashed
      continue
    if not hasPopulatedStackup(pcb):
      stdout.write(path, "  skipped (no populated stackup)\n")
      inc skipped
      continue
    inc processed
    let totals = processBoard(pcb)
    let ms = int((epochTime() - t0) * 1000.0)
    stdout.write(&"{path}  nets={totals.nets} single={totals.singleIsland} " &
                 &"split={totals.splitIsland} sections={totals.sections} " &
                 &"ref_ok={totals.sectionsFullRef} ref_gap={totals.sectionsGapRef} " &
                 &"ref_none={totals.sectionsNoRef}  ({ms} ms)\n")
    var issueParts: seq[string] = @[]
    for kind, n in totals.issueCounts:
      issueParts.add(kind & "=" & $n)
    if issueParts.len > 0:
      stdout.write("    issues: ", issueParts.join(", "), "\n")
    let loops = totals.issueCounts.getOrDefault("route_loop")
    if loops > 0: worstLoops.add((path, loops))

    grand.nets += totals.nets
    grand.singleIsland += totals.singleIsland
    grand.splitIsland += totals.splitIsland
    grand.sections += totals.sections
    grand.sectionsFullRef += totals.sectionsFullRef
    grand.sectionsGapRef += totals.sectionsGapRef
    grand.sectionsNoRef += totals.sectionsNoRef
    for kind, n in totals.issueCounts:
      grand.issueCounts.inc(kind, n)

  echo ""
  echo "--- summary ---"
  echo "boards examined:        ", examined
  echo "boards processed:       ", processed, " (populated stackup)"
  echo "boards skipped:         ", skipped, " (no stackup material)"
  echo "boards refused:         ", refused, " (readPcb declined by name, e.g. structural corruption)"
  echo "boards that crashed:    ", crashed
  echo "nets extracted:         ", grand.nets
  echo "  single connected graph: ", grand.singleIsland
  echo "  split into islands:     ", grand.splitIsland
  echo "sections:                ", grand.sections
  echo "  reference >= 90%:       ", grand.sectionsFullRef
  echo "  reference found, < 90%: ", grand.sectionsGapRef
  echo "  no reference found:     ", grand.sectionsNoRef
  echo "issue counts, across every board:"
  for kind, n in grand.issueCounts:
    echo "  ", kind, ": ", n
  if worstLoops.len > 0:
    echo ""
    echo "boards reporting route_loop (worth a look -- a stitched ring is a"
    echo "legitimate topology, but it is also what a wrong tolerance join"
    echo "would look like):"
    for (path, n) in worstLoops:
      echo "  ", path, ": ", n

  if crashed > 0:
    echo ""
    echo "FAIL: at least one board with a populated stackup crashed during read."
    quit(1)
  echo ""
  echo "OK: every processed board's nets extracted without raising."

main()
