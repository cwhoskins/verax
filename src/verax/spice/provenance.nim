## Where each element of a simulated netlist came from. Every part a model
## pass, a scoping strategy or a bench adds is marked, so a reader (the
## report's circuit view) can fold modelling elements back into the design
## part they stand for and tell the fixture -- stimulus, probes,
## terminations -- from the circuit under test.
##
## Keys (`Component.attrs`, and `Net.attrs` for probe/stimulus nets):
## - `bench.role`: a `BenchRole` spelling.
## - `bench.of`: the **design** designator an element models or stands in
##   for (a model of a stand-in resolves to the original part).
## - `bench.note`: one short line for a reader.
## - `bench.pin`: on a per-pin stand-in, the pin of `bench.of` it replaces.
##
## Unmarked parts are the design's own. The older per-pass flags
## (`parasitics.expanded`, `models.pin.expanded`, ...) keep their meaning;
## these are added beside them, never in their place. Decks never see them.

import std/[sets, tables]
import ../netlist/types

type
  BenchRole* = enum
    brModel = "model"
      ## An element of a part's simulation model; the part is still there
      ## (a capacitor's ESR and ESL).
    brStandIn = "standin"
      ## Replaces the part entirely (per-pin impedances, an ideal-source
      ## regulator, a `simReplace`).
    brStimulus = "stimulus"
      ## Drives the circuit for the measurement.
    brProbe = "probe"
      ## Exists to be read (a 0 V current sense), or the net that is read.
    brTermination = "termination"
      ## Closes a cut (a rail held at nominal, a leak, a load in place of a
      ## cut-away part).
    brLoad = "load"
      ## A test load the analysis applies.

const
  benchRoleKey* = "bench.role"
  benchOfKey* = "bench.of"
  benchNoteKey* = "bench.note"
  benchPinKey* = "bench.pin"
    ## On a per-pin stand-in: which pin of `bench.of` it stands in for.

proc benchRole*(c: Component): string = c.attrs.getOrDefault(benchRoleKey, "")
proc benchRole*(n: Net): string = n.attrs.getOrDefault(benchRoleKey, "")
proc benchOf*(c: Component): string = c.attrs.getOrDefault(benchOfKey, "")
proc benchNote*(c: Component): string = c.attrs.getOrDefault(benchNoteKey, "")

proc designOf*(c: Component): string =
  ## The design part `c` belongs to: its `bench.of`, else itself.
  let o = benchOf(c)
  if o.len > 0: o else: c.designator

proc mark*(c: Component, role: BenchRole, owner = "", note = "") =
  c.attrs[benchRoleKey] = $role
  if owner.len > 0: c.attrs[benchOfKey] = owner
  if note.len > 0: c.attrs[benchNoteKey] = note

proc mark*(n: Net, role: BenchRole, owner = "", note = "") =
  n.attrs[benchRoleKey] = $role
  if owner.len > 0: n.attrs[benchOfKey] = owner
  if note.len > 0: n.attrs[benchNoteKey] = note

type Snapshot* = tuple[parts: Table[string, Component], nets: HashSet[string]]

proc snapshot*(nl: Netlist): Snapshot =
  for d, c in nl.components: result.parts[d] = c
  for n in nl.nets.keys: result.nets.incl n

proc markAdded*(nl: Netlist, before: Snapshot, role: BenchRole, owner: string,
                note = "") =
  ## Marks every part added since `before` (by identity: a replacement may
  ## reuse its original's designator) that no inner pass already marked.
  ## New nets get only `bench.of` (a model's internal node).
  for d, c in nl.components:
    if before.parts.getOrDefault(d) != c and benchRole(c).len == 0:
      mark(c, role, owner, note)
  for k, n in nl.nets:
    if k notin before.nets and n.attrs.getOrDefault(benchOfKey, "").len == 0:
      n.attrs[benchOfKey] = owner

template provenance*(nl: Netlist, part: Component, role: BenchRole,
                     body: untyped) =
  ## Runs `body` (which models or replaces `part`) and marks what it added
  ## as `role` of `part`'s design part -- resolved *before* `body`, which
  ## may remove `part`.
  block:
    let provOf = designOf(part)
    let provBefore = snapshot(nl)
    body
    markAdded(nl, provBefore, role, provOf)

type
  BenchItem* = object
    ## One fixture element a bench declared: what it is, where it sits.
    role*: BenchRole
    designator*: string
      ## In the simulated netlist; empty for a probe that is just a net.
    nets*: seq[string]
    text*: string

  BenchInfo* = object
    ## What a run's bench declared, as plain data -- what a report reads to
    ## say "driven here, read there, cut there". Carried on
    ## `ngspice.RunRecord`; never on a `Readiness`.
    name*: string
    strategy*: string
    strategyDoc*: string
    seedParts*: seq[string]
    seedNets*: seq[string]
    focus*: seq[string]
      ## Nets the measurement is about (what a picture highlights).
    items*: seq[BenchItem]
      ## Stimuli, probes and loads, in the order added.
    detached*: seq[string]
      ## Design parts removed so a stimulus could take their place.
    dropped*: seq[string]
      ## Parts the scope reached and cut away.

template provenance*(nl: Netlist, owner: string, role: BenchRole,
                     body: untyped) =
  ## As above, naming the design part directly (for a part that may be
  ## absent, so `body` can report that itself).
  block:
    let provBefore = snapshot(nl)
    body
    markAdded(nl, provBefore, role, owner)
