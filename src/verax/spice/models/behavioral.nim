## The behavioural-model registry: parts with a path through them, keyed by
## `Component.kind`, replaced by a network that keeps their function.
## Consulted before per-pin impedances, which would destroy the path.

import std/tables
import ../../netlist/types
import ../../netlist/annotations

type
  BehavioralResult* = tuple[handled: bool, notes: seq[Assumption]]
    ## `handled`: the model replaced the component. **False means leave the
    ## part as is** -- not per-pin impedances, which would give a confident
    ## wrong answer.

  BehavioralModel* = proc (nl: Netlist, c: Component, gnd: Net): BehavioralResult {.nimcall.}
    ## Replaces one component with a function-preserving network, registered
    ## by kind.

type BehavioralDef = tuple[model: BehavioralModel, passesSignal: bool]

var behavioral: OrderedTable[string, BehavioralDef]

proc registerBehavioralModel*(kind: string, m: BehavioralModel,
                              passesSignal = false) =
  ## A runtime table, so unanticipated part families can be added.
  ## `passesSignal` (declared, not inferred) says the stand-in keeps an
  ## input -> output path, so static checks like `analysis/opamp`'s feedback
  ## walk agree with simulation.
  behavioral[kind] = (model: m, passesSignal: passesSignal)

proc behavioralModelFor*(kind: string): BehavioralModel =
  if behavioral.hasKey(kind): behavioral[kind].model else: nil

proc passesSignal*(kind: string): bool =
  ## Whether a stand-in for this kind keeps a path through the part.
  behavioral.hasKey(kind) and behavioral[kind].passesSignal

proc modelledKinds*(): seq[string] =
  for k in behavioral.keys: result.add k
