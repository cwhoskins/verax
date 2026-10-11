## Runs a design's checks and keeps what a test report needs beyond the
## `Readiness`: every ngspice run (curves, log, deck, simulated fragment),
## filed under the plan step that caused it.
##
## **Curves never enter `Readiness`** (`verify` pins its size). They come
## through `spice/ngspice`'s run observer, attributed to a step by the
## `onStep` hook `readiness` threads into `EvalContext`. A run outside any
## step (none today) lands in `unattributed`. A shared `.op` cached in
## `EvalContext.scratch` belongs to the first step that ran it; later steps
## reuse it without a run of their own.

import std/[tables, times]
import ../netlist/types
import ../contract/design
import ../contract/evaluate
import ../pcb/types as pcbtypes
import ../spice/ngspice
import ../readiness

export ngspice.RunRecord

type
  SimReport* = object
    readiness*: Readiness
    runsByStep*: Table[int, seq[RunRecord]]
      ## Plan-step index (`Check.step`) -> the runs it made, in order.
    unattributed*: seq[RunRecord]
    design*: Design
    netlist*: Netlist
      ## The design netlist, for checks that ran no simulation.
    generated*: DateTime

proc runsOf*(r: SimReport, c: Check): seq[RunRecord] =
  r.runsByStep.getOrDefault(c.step)

proc collectReport*(d: Design, allowed = allCapabilities,
                    board: Pcb = nil): SimReport =
  ## `readiness` with every simulator run kept. The observer is removed
  ## afterwards even if `readiness` raises.
  var current = -1
  var byStep = initTable[int, seq[RunRecord]]()
  var loose: seq[RunRecord]
  setRunObserver(proc (rec: RunRecord) =
    if current >= 0: byStep.mgetOrPut(current, @[]).add rec
    else: loose.add rec)
  try:
    result.readiness = readiness(d, allowed, board,
      onStep = proc (i: int, starting: bool) =
        current = (if starting: i else: -1))
  finally:
    clearRunObserver()
  result.runsByStep = byStep
  result.unattributed = loose
  result.design = d
  result.netlist = d.netlist
  result.generated = now()
