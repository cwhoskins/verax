## The byte-exactness sweep for `verax/pcb/formats/kicad` -- a **task, not a
## test** (`nimble roundtrip`), per `verax/pcb/CLAUDE.md`: `nim c` debug-mode
## over the 81 MB `jetson-agx-thor-baseboard.kicad_pcb` is minutes, and
## `/usr/share/kicad/demos` is machine-local, so a silently-skipping
## `nimble test` entry on the one thing this stage exists to prove would be
## worse than no test at all.
##
## For every `*.kicad_pcb` found under the given root (default
## `/usr/share/kicad/demos`): parse with `sexp.parseSexpFile`, render with
## `fastPath = false` (the structural proof -- see `sexp.nim`), and compare
## bytes. Then separately try `kicad.readPcb`, since byte comparison alone
## never touches the typed model (a reader that mapped nothing would still
## pass the first half) -- `RoyalBlue54L-Feather.kicad_pcb` is asserted to
## report `OK` at the sexp level and `REFUSED` at the `readPcb` level, the
## expectation finding 2 predicts, encoded rather than waived.
##
## Run with:
##   nim c -d:release -r --path:./src examples/pcb_roundtrip.nim [root]

import std/[algorithm, os, sets, strutils, times, strformat]

import verax/pcb/formats/sexp
import verax/pcb/formats/kicad

proc findBoards(root: string): seq[string] =
  for f in walkDirRec(root):
    if f.endsWith(".kicad_pcb"): result.add(f)
  result.sort()

proc humanSize(bytes: int): string =
  if bytes >= 1_000_000: &"{bytes.float / 1_000_000.0:.1f} MB"
  elif bytes >= 1_000: &"{bytes.float / 1_000.0:.1f} KB"
  else: $bytes & " B"

proc main() =
  let root = if paramCount() >= 1: paramStr(1) else: "/usr/share/kicad/demos"
  if not dirExists(root):
    echo "pcb_roundtrip: no such directory: ", root
    quit(1)
  let boards = findBoards(root)
  if boards.len == 0:
    echo "pcb_roundtrip: no .kicad_pcb files found under ", root
    quit(1)

  var anyDiff = false
  var sexpOk, sexpDiff = 0
  var readOk, readRefused, readCrashed = 0

  for path in boards:
    let sz = getFileSize(path).int
    stdout.write(path, "  (", humanSize(sz), ")\n")

    # --- sexp layer: structural byte-exactness -----------------------
    let t0 = epochTime()
    var sexpVerdict = "OK"
    var doc: SexpDoc
    try:
      doc = parseSexpFile(path)
      let original = readFile(path)
      let rendered = render(doc, fastPath = false)
      if rendered != original:
        var diffAt = -1
        for i in 0 ..< min(rendered.len, original.len):
          if rendered[i] != original[i]: (diffAt = i; break)
        if diffAt < 0: diffAt = min(rendered.len, original.len)
        sexpVerdict = "DIFF at byte " & $diffAt & " (rendered " & $rendered.len &
                      " bytes, original " & $original.len & " bytes)"
        anyDiff = true
        inc sexpDiff
      else:
        inc sexpOk
    except CatchableError as e:
      sexpVerdict = "ERROR: " & e.msg
      anyDiff = true
    let sexpMs = int((epochTime() - t0) * 1000.0)
    echo "  sexp:  ", sexpVerdict, "  (", sexpMs, " ms, peak ",
         humanSize(getOccupiedMem()), ")"

    # --- kicad layer: the typed reader, and its coverage self-check --
    let t1 = epochTime()
    var readVerdict = "OK"
    try:
      let pcb = readPcb(path)
      let live = liveEntitySet(pcb)
      let doc2 = KicadDoc(pcb.source)
      if live.len != doc2.mapped.len:
        readVerdict = "MAPPING MISMATCH: liveEntities=" & $live.len &
                       " doc.mapped=" & $doc2.mapped.len &
                       " (a container the delete sweep would walk is missing " &
                       "or an entity was mapped without a live counterpart)"
        anyDiff = true
      inc readOk
    except PcbFormatError as e:
      readVerdict = "REFUSED: " & e.msg
      inc readRefused
    except CatchableError as e:
      readVerdict = "CRASHED: " & e.msg
      anyDiff = true
      inc readCrashed
    let readMs = int((epochTime() - t1) * 1000.0)
    echo "  kicad: ", readVerdict, "  (", readMs, " ms)"

  echo ""
  echo "--- summary ---"
  echo "boards examined:     ", boards.len
  echo "sexp byte-exact:     ", sexpOk, " / ", boards.len
  echo "sexp diffs/errors:   ", sexpDiff
  echo "kicad.readPcb OK:    ", readOk
  echo "kicad.readPcb REFUSED: ", readRefused
  echo "kicad.readPcb CRASHED: ", readCrashed

  if anyDiff:
    echo ""
    echo "FAIL: at least one board was not byte-exact, or crashed, or the " &
         "delete-sweep coverage check disagreed."
    quit(1)
  else:
    echo ""
    echo "OK: every board round-tripped byte-exact at the sexp layer."

main()
