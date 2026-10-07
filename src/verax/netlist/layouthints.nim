## Authored hints for the schematic layout heuristic -- not electrical
## facts, so not in `annotations.builtinAnnotations`.
##
## **Stored as namespaced `layout.*` attrs**, so they survive clone,
## flatten and isolation (and are lost by a SPICE round trip). The DSL's
## `layout:` block is strict at compile time; the `attrs` underneath are
## permissive.
##
## Hints: `side` (`left`/`right`: leftmost or rightmost column), `mirror`
## (reflect a box about its vertical axis), `power` (force into or out of
## the power/decoupling band), `variant` (a `pcb/variant` name).
## `layoutHintKeys` is the one list both the parser and the DSL read.

import std/tables

import ./types
import ./graph
import ./issue

export issue

const
  layoutSideKey* = "layout.side"
    ## Namespaced so future placement hints read as one family.
  layoutMirrorKey* = "layout.mirror"
  layoutPowerKey* = "layout.power"
  layoutVariantKey* = "layout.variant"
    ## "This instance uses layout variant X". Variant names live in
    ## `pcb/variant`'s registry (unreachable from here), so this owns only
    ## storage and syntax; the value is an open string.
  layoutHintKeys* = ["side", "mirror", "power", "variant"]
    ## Bare keys the `layout:` block accepts (without the prefix); the
    ## extension point for new hints.

type
  LayoutSide* = enum
    ## `sideAuto` is the zero value and "no override". Not `ls*`: that prefix
    ## belongs to `schematic.StageId`.
    sideAuto, sideLeft, sideRight

  LayoutMirror* = enum
    ## `mirrorAuto` is the zero value and "no override"; `mirrorOn`/
    ## `mirrorOff` are hard guarantees; otherwise `schematic` picks the
    ## shorter-wire reflection.
    mirrorAuto, mirrorOn, mirrorOff

  LayoutPower* = enum
    ## `powerAuto` is the zero value and "no override"; `powerOn`/`powerOff`
    ## override `unitExternallyPurePower` inference.
    powerAuto, powerOn, powerOff

proc parseLayoutSide*(s: string): tuple[ok: bool, side: LayoutSide] =
  ## The one string -> `LayoutSide` mapping, shared with
  ## `validateLayoutHints`.
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
  ## States (or clears) `c`'s side. `sideAuto` removes the key, so there's
  ## one way to mean "no override".
  if side == sideAuto:
    c.attrs.del(layoutSideKey)
  else:
    c.attrs[layoutSideKey] = $side

proc layoutSide*(c: Component): LayoutSide =
  ## The side to place `c` on. Absent or unparseable reads `sideAuto` (a
  ## rendering hint must never fail a check); `validateLayoutHints` reports
  ## bad values.
  if not c.attrs.hasKey(layoutSideKey): return sideAuto
  let (ok, side) = parseLayoutSide(c.attrs[layoutSideKey])
  if ok: side else: sideAuto

proc parseLayoutMirror*(s: string): tuple[ok: bool, mirror: LayoutMirror] =
  ## The one string -> `LayoutMirror` mapping.
  case s
  of "true": (true, mirrorOn)
  of "false": (true, mirrorOff)
  of "auto": (true, mirrorAuto)
  else: (false, mirrorAuto)

proc `$`*(mirror: LayoutMirror): string =
  case mirror
  of mirrorAuto: "auto"
  of mirrorOn: "true"
  of mirrorOff: "false"

proc setLayoutMirror*(c: Component, mirror: LayoutMirror) =
  ## States (or clears) `c`'s mirror; `mirrorAuto` removes the key.
  if mirror == mirrorAuto:
    c.attrs.del(layoutMirrorKey)
  else:
    c.attrs[layoutMirrorKey] = $mirror

proc layoutMirror*(c: Component): LayoutMirror =
  ## Whether `c` must be mirrored; absent or unparseable reads `mirrorAuto`.
  if not c.attrs.hasKey(layoutMirrorKey): return mirrorAuto
  let (ok, mirror) = parseLayoutMirror(c.attrs[layoutMirrorKey])
  if ok: mirror else: mirrorAuto

proc parseLayoutPower*(s: string): tuple[ok: bool, power: LayoutPower] =
  ## The one string -> `LayoutPower` mapping.
  case s
  of "true": (true, powerOn)
  of "false": (true, powerOff)
  of "auto": (true, powerAuto)
  else: (false, powerAuto)

proc `$`*(power: LayoutPower): string =
  case power
  of powerAuto: "auto"
  of powerOn: "true"
  of powerOff: "false"

proc setLayoutPower*(c: Component, power: LayoutPower) =
  ## States (or clears) `c`'s power-band override; `powerAuto` removes the
  ## key.
  if power == powerAuto:
    c.attrs.del(layoutPowerKey)
  else:
    c.attrs[layoutPowerKey] = $power

proc layoutPower*(c: Component): LayoutPower =
  ## Whether `c` is forced into or out of the power band; absent or
  ## unparseable reads `powerAuto`.
  if not c.attrs.hasKey(layoutPowerKey): return powerAuto
  let (ok, power) = parseLayoutPower(c.attrs[layoutPowerKey])
  if ok: power else: powerAuto

proc parseLayoutVariant*(s: string): tuple[ok: bool, variant: string] =
  ## The one stored-string -> variant-name mapping. Names are open, so the
  ## only invalid value is an explicitly stored empty string (a foreign
  ## writer's mistake; "no override" is the absent key).
  if s.len == 0: (false, "") else: (true, s)

proc setLayoutVariant*(c: Component, name: string) =
  ## States (or clears, with `""`) the instance's layout variant.
  if name.len == 0:
    c.attrs.del(layoutVariantKey)
  else:
    c.attrs[layoutVariantKey] = name

proc layoutVariant*(c: Component): string =
  ## The variant name for `c`, or `""` for none (a stored empty value reads
  ## `""` too).
  if not c.attrs.hasKey(layoutVariantKey): return ""
  let (ok, name) = parseLayoutVariant(c.attrs[layoutVariantKey])
  if ok: name else: ""

const
  KindLayoutHintUnparseable* = "layout_hint_unparseable"

proc validateLayoutHints*(nl: Netlist, recursive = true): seq[Issue] =
  ## Problems with `layout.*` attrs as written -- the accessors silently fall
  ## back, so this is the only place bad values are reported. Only a file
  ## reader or raw write can produce one.
  for _, c in nl.components:
    if c.attrs.hasKey(layoutSideKey):
      let (ok, _) = parseLayoutSide(c.attrs[layoutSideKey])
      if not ok:
        result.add newIssue(KindLayoutHintUnparseable, sevWarning,
          c.designator & " states " & layoutSideKey & " = \"" &
          c.attrs[layoutSideKey] & "\", which is not left/right/auto and " &
          "will be read as no override at all.",
          components = @[c])
    if c.attrs.hasKey(layoutMirrorKey):
      let (ok, _) = parseLayoutMirror(c.attrs[layoutMirrorKey])
      if not ok:
        result.add newIssue(KindLayoutHintUnparseable, sevWarning,
          c.designator & " states " & layoutMirrorKey & " = \"" &
          c.attrs[layoutMirrorKey] & "\", which is not true/false/auto and " &
          "will be read as no override at all.",
          components = @[c])
    if c.attrs.hasKey(layoutPowerKey):
      let (ok, _) = parseLayoutPower(c.attrs[layoutPowerKey])
      if not ok:
        result.add newIssue(KindLayoutHintUnparseable, sevWarning,
          c.designator & " states " & layoutPowerKey & " = \"" &
          c.attrs[layoutPowerKey] & "\", which is not true/false/auto and " &
          "will be read as no override at all.",
          components = @[c])
    if c.attrs.hasKey(layoutVariantKey):
      let (ok, _) = parseLayoutVariant(c.attrs[layoutVariantKey])
      if not ok:
        result.add newIssue(KindLayoutHintUnparseable, sevWarning,
          c.designator & " states " & layoutVariantKey & " = \"\", an " &
          "explicitly empty variant name, which will be read as no " &
          "override at all.",
          components = @[c])
  if recursive:
    for _, child in nl.children:
      result.add validateLayoutHints(child, recursive = true)
