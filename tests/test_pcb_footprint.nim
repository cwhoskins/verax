## `pcb/footprint.nim`'s provider registry: registration order is resolution
## order, an unknown spec returns `nil`, and the first non-nil source wins.

import std/unittest

import verax/pcb/types
import verax/pcb/footprint

proc fakeFootprint(name: string): Footprint =
  Footprint(name: name, mount: mkSmt)

test "an unknown spec resolves to nil when no source is registered":
  check findFootprint("Nothing:Registered") == nil

test "a registered source resolves a spec it claims, in registration order":
  registerFootprintSource(FootprintSource(name: "only-a",
    resolve: proc (spec: string): Footprint =
      if spec == "A:Part": fakeFootprint(spec) else: nil))
  check "only-a" in footprintSources()
  let fp = findFootprint("A:Part")
  check fp != nil
  check fp.name == "A:Part"
  check findFootprint("B:Other") == nil

test "a second source is tried when the first returns nil, and the first wins on a tie":
  registerFootprintSource(FootprintSource(name: "second",
    resolve: proc (spec: string): Footprint =
      if spec == "B:Other": fakeFootprint("from-second:" & spec)
      elif spec == "A:Part": fakeFootprint("from-second:" & spec)
      else: nil))
  # "A:Part" still resolves through the first-registered source (the
  # registry is module-level, so it persists from the previous test).
  check findFootprint("A:Part").name == "A:Part"
  # "B:Other" is claimed only by the second source.
  let fp = findFootprint("B:Other")
  check fp != nil
  check fp.name == "from-second:B:Other"
  check findFootprint("C:Neither") == nil
