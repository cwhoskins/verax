## Joins the run archive (`spice/ngspice`, `$VERAX_KEEP_RUNS`) to the
## schematic renderer: importing this installs the writer that leaves a
## `runNNN.svg`/`runNNN.json` picture of each run's derived netlist beside
## its deck and rawfile.
##
## Its own root module because `spice` must not depend on `schematic` (that
## would link the layout engine into every simulation) and `schematic`
## depends only on `netlist`. `verify` imports it; a program that runs
## analyses directly and wants the pictures imports it too.

{.used.}  # imported for its side effect

import ./netlist/types
import ./schematic
import ./spice/ngspice

proc writeRunPicture(nl: Netlist, base: string) {.nimcall.} =
  writeScenePair(layout(nl, archiveLayoutOptions()), base)

proc installRunPictureWriter*() =
  ## Called at module init; exposed so a cleared hook can be restored.
  setRunPictureWriter(writeRunPicture)

installRunPictureWriter()
