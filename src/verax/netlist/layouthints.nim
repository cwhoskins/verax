## Authored hints for where the schematic layout heuristic should put a
## component -- not electrical facts, so they do not belong beside
## `esr`/`package`/`t_ambient_max` in `annotations.builtinAnnotations`.
##
## **Storage is a namespaced `attrs` key**, the same trade `environment.nim`,
## `packages.nim` and `pinmux.nim` make: `graph.clone` copies `attrs` at every
## level, so a hint survives `clone`/`instantiate`/`flatten`/`extractSubcircuit`/
## `isolate` for free, and a root registry of direct object references would
## need remapping written and tested across all of those. Namespaced rather
## than a bare registered key because this is a rendering hint, not a
## property of the circuit -- it does not belong in the shared electrical
## vocabulary `annotations.nim` validates, and a SPICE round trip is expected
## to lose it exactly as it loses `package.*` (see `test_netlist_spice.nim`).
##
## Compile-time strictness comes from the DSL's `layout:` block
## (`netlist/dsl.handleLayout`), not from `netlist/annotations` -- the same
## split `xspice/dsl.nim` makes for its own namespaced vocabulary: strict at
## the syntax boundary where an unknown key can only be a mistake, permissive
## in the open-ended `attrs` bag underneath, where a file reader or another
## tool may have written something this module does not yet parse.
##
## Only a `side` hint exists today (`left`/`right`, forcing a component to the
## schematic's leftmost or rightmost placement column). `layoutHintKeys` is
## deliberately a `const seq` rather than inlined into the DSL, so a future
## key (rotation, a pin-level placement, an absolute position) has one place
## to be added on both sides -- the parser here and the dispatcher there.

import std/tables

import ./types
import ./graph
import ./issue

export issue

const
  layoutSideKey* = "layout.side"
    ## The one hint key implemented so far. Namespaced under `layout.` so a
    ## future `layout.rotation`/`layout.x`/`layout.y` reads as the same family.
  layoutHintKeys* = ["side"]
    ## Bare keys the DSL's `layout:` block accepts, spelled without the
    ## `layout.` prefix the way the block's own name already supplies it.
    ## This is the extension point for a future hint.

type
  LayoutSide* = enum
    ## `sideAuto` is both the zero value and "no override stated" -- a
    ## component with no `layout.side` attr reads as `sideAuto`, so absence
    ## and the explicit default coincide, the same shape `deltaT`/`0` take in
    ## `environment.nim`. Not spelled `ls*`: `schematic.StageId` already owns
    ## that prefix and the two enums must never collide by pattern.
    sideAuto, sideLeft, sideRight

proc parseLayoutSide*(s: string): tuple[ok: bool, side: LayoutSide] =
  ## The one place that maps a stored string to `LayoutSide`. Shared by the
  ## accessor below and by `validateLayoutHints`, so a value neither of them
  ## recognizes is reported once, not divergently.
  case s
  of "left": (true, sideLeft)
  of "right": (true, sideRight)
  of "auto": (true, sideAuto)
  else: (false, sideAuto)

proc `$`*(side: LayoutSide): string =
  case side
  of sideAuto: "auto"
  of sideLeft: "left"
  of sideRight: "right"

proc setLayoutSide*(c: Component, side: LayoutSide) =
  ## States (or clears) `c`'s side override. `sideAuto` removes the key
  ## rather than writing `"auto"`, so a component nobody has annotated and
  ## one explicitly reset to automatic placement are indistinguishable in
  ## `attrs` -- there is only one way to mean "no override".
  if side == sideAuto:
    c.attrs.del(layoutSideKey)
  else:
    c.attrs[layoutSideKey] = $side

proc layoutSide*(c: Component): LayoutSide =
  ## The side to place `c` on. Pure like every other accessor in this
  ## codebase's annotation-shaped modules: absent or unparseable both read as
  ## `sideAuto` rather than raising, because a rendering hint must never be
  ## the reason a design fails to check -- `validateLayoutHints` is where an
  ## unparseable value is actually reported.
  if not c.attrs.hasKey(layoutSideKey): return sideAuto
  let (ok, side) = parseLayoutSide(c.attrs[layoutSideKey])
  if ok: side else: sideAuto

const
  KindLayoutHintUnparseable* = "layout_hint_unparseable"

proc validateLayoutHints*(nl: Netlist, recursive = true): seq[Issue] =
  ## What is wrong with a `layout.*` attr as *written*, not as read back --
  ## `layoutSide` above silently falls back to `sideAuto` for exactly this
  ## case, since a rendering hint must never fail a check on its own, so this
  ## is the only place a bad value is ever reported. Only reachable from a
  ## file reader or a raw `setRawAnnotation` call: the DSL's `layout:` block
  ## rejects an unrecognised spelling at compile time.
  for _, c in nl.components:
    if c.attrs.hasKey(layoutSideKey):
      let (ok, _) = parseLayoutSide(c.attrs[layoutSideKey])
      if not ok:
        result.add newIssue(KindLayoutHintUnparseable, sevWarning,
          c.designator & " states " & layoutSideKey & " = \"" &
          c.attrs[layoutSideKey] & "\", which is not left/right/auto and " &
          "will be read as no override at all.",
          components = @[c])
  if recursive:
    for _, child in nl.children:
      result.add validateLayoutHints(child, recursive = true)
