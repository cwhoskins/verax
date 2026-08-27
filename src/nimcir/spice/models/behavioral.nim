## The behavioural-model registry: parts with a path through them, keyed by
## `Component.kind`, stood in for by a network that keeps their *function*.
## `spice/models/pin_models` consults this before falling through to per-pin
## impedances, which would destroy any path through the part.

import std/tables
import ../../netlist/types
import ../../netlist/annotations

type
  BehavioralResult* = tuple[handled: bool, notes: seq[Assumption]]
    ## `handled` says the model replaced the component itself. **False means
    ## leave the part exactly as it is** -- emphatically not "fall back to
    ## per-pin impedances". A part known to carry a path from one pin to
    ## another, stood in for by two independent resistors to ground, reports
    ## its output rail at 0 V: a confident wrong answer where refusing to
    ## simulate would have been an honest one.

  BehavioralModel* = proc (nl: Netlist, c: Component, gnd: Net): BehavioralResult {.nimcall.}
    ## Replaces one component with a network that keeps its *function*.
    ## Registered by `Component.kind`, so a part nobody has modelled falls
    ## through to the per-pin defaults, which is right for an MCU and wrong
    ## for a regulator.

type BehavioralDef = tuple[model: BehavioralModel, passesSignal: bool]

var behavioral: OrderedTable[string, BehavioralDef]

proc registerBehavioralModel*(kind: string, m: BehavioralModel,
                              passesSignal = false) =
  ## A runtime table for the same reason the role and evaluator registries
  ## are: a part family nobody here anticipated must be modellable without
  ## editing this module.
  ##
  ## `passesSignal` says the stand-in keeps a path from the part's input to
  ## its output. A regulator does not (its output is a source); a buffer
  ## does. It is declared here rather than inferred because a *static* check
  ## has to know the answer without simulating -- `analysis/opamp`'s feedback
  ## walk asks exactly this, and would otherwise call a loop open that the
  ## simulation is about to close.
  behavioral[kind] = (model: m, passesSignal: passesSignal)

proc behavioralModelFor*(kind: string): BehavioralModel =
  if behavioral.hasKey(kind): behavioral[kind].model else: nil

proc passesSignal*(kind: string): bool =
  ## Whether a stand-in for this kind keeps a path through the part.
  behavioral.hasKey(kind) and behavioral[kind].passesSignal

proc modelledKinds*(): seq[string] =
  for k in behavioral.keys: result.add k
