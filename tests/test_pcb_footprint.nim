## `pcb/footprint.nim`'s provider registry: registration order is
## resolution order, an unknown spec returns `nil` rather than raising, and
## a source recognising a spec by returning non-nil wins over one that
## returns `nil` for it.

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
  # "A:Part" still resolves through the first-registered source (registered
  # in the previous test, and the registry is module-level state -- the
  # same "sources in registration order" contract `findFootprint`'s own doc
  # comment states).
  check findFootprint("A:Part").name == "A:Part"
  # "B:Other" is claimed only by the second source.
  let fp = findFootprint("B:Other")
  check fp != nil
  check fp.name == "from-second:B:Other"
  check findFootprint("C:Neither") == nil
