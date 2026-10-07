## `pcb/variant.nim`: the layout-variant data model and registry.
## `selectVariant`/`instantiateVariant` are named refusals.

import std/[strutils, unittest]

import verax/pcb/units
import verax/pcb/geometry
import verax/pcb/types
import verax/pcb/variant

proc smallVariant(subcircuit, name: string): LayoutVariant =
  LayoutVariant(name: name, subcircuit: subcircuit, copperLayers: 2,
                extent: Box(lo: pt(nm(0), nm(0)), hi: pt(mm(10.0), mm(8.0))))

test "register, then look up by subcircuit":
  check layoutVariants("test_sub_a").len == 0
  registerLayoutVariant(smallVariant("test_sub_a", "compact"))
  let found = layoutVariants("test_sub_a")
  check found.len == 1
  check found[0].name == "compact"
  check layoutVariants("test_sub_a_unrelated").len == 0

test "duplicate (subcircuit, name) raises":
  registerLayoutVariant(smallVariant("test_sub_b", "v1"))
  expect(PcbError):
    registerLayoutVariant(smallVariant("test_sub_b", "v1"))
  # A different name on the same subcircuit is fine.
  registerLayoutVariant(smallVariant("test_sub_b", "v2"))
  check layoutVariants("test_sub_b").len == 2

test "selectVariant raises, naming the constraints asked for and what exists":
  registerLayoutVariant(smallVariant("test_sub_c", "only"))
  try:
    discard selectVariant("test_sub_c", VariantConstraints(maxCopperLayers: 1))
    check false   # must not reach here
  except PcbError as e:
    check "test_sub_c" in e.msg
    check "only" in e.msg

test "selectVariant on an unregistered subcircuit still names what was asked for":
  try:
    discard selectVariant("test_sub_never_registered", VariantConstraints())
    check false
  except PcbError as e:
    check "test_sub_never_registered" in e.msg
    check "0 registered" in e.msg

test "instantiateVariant raises, naming the variant and what it would have stamped":
  let v = smallVariant("test_sub_d", "only")
  v.placements.add VariantPlacement(designator: "R1")
  try:
    instantiateVariant(nil, v, "X1", pt(nm(0), nm(0)), deg(0.0), bsTop)
    check false
  except PcbError as e:
    check "only" in e.msg
    check "X1" in e.msg
