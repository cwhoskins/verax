## `notes:` -- free-form `key = value` pairs stored on an entity and never
## interpreted, the permissive opposite of `spec:`.

import std/[tables, unittest]

import verax/netlist
import verax/netlist/dsl
import verax/netlist/annotations
import verax/bom

proc board(): Netlist =
  netlist("b"):
    net a:
      notes:
        routing = "keep short"
    net gnd, kind = ntGround, name = "0"
    component J1, kind = "connector", description = "2-pin header":
      notes:
        supplier_sku = "S-1234"
        "assembly note" = "hand-solder last"
        reel = 4000
      pin "1", a
      pin "2", gnd

test "notes are stored under the notes namespace and read back without it":
  let nl = board()
  let j1 = nl.components["J1"]
  check j1.attrs["notes.supplier_sku"] == "S-1234"
  check noteOf(j1, "assembly note") == "hand-solder last"
  check noteOf(j1, "reel") == "4000"            # any value, stored as text
  check noteOf(j1, "absent") == ""
  var keys: seq[string]
  for k, _ in notesOf(j1): keys.add k
  check keys == @["supplier_sku", "assembly note", "reel"]
  check noteOf(nl.nets["a"], "routing") == "keep short"

test "notes are never validated and never reach the BOM as vocabulary":
  let nl = board()
  check validateAnnotations(nl).len == 0
  let item = collect(nl)[0]
  check item.mpn == "" and item.partNumber == ""
  check item.description == "2-pin header"

test "a notes key that is not an identifier or string is a compile error":
  check(not compiles(block:
    discard netlist("b"):
      net a
      component J1, kind = "connector":
        notes:
          a.b = "x"
        pin "1", a))
