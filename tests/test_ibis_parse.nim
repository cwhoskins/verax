import std/[streams, unittest]

import verax/ibis/parse

test "canonicalKeyword unifies case and space/underscore":
  check canonicalKeyword("GND Clamp") == "gnd_clamp"
  check canonicalKeyword("GND_Clamp") == "gnd_clamp"
  check canonicalKeyword("  gnd   clamp  ") == "gnd_clamp"
  check canonicalKeyword("Pulldown") == "pulldown"
  check canonicalKeyword("IBIS Ver") == "ibis_ver"

test "parseIbisNumber scales metric prefixes and keeps a trailing unit":
  var v: float
  check parseIbisNumber("1.5n", v) and abs(v - 1.5e-9) < 1e-21
  check parseIbisNumber("10pF", v) and abs(v - 10e-12) < 1e-24
  check parseIbisNumber("50.0ohm", v) and abs(v - 50.0) < 1e-12
  check parseIbisNumber("-3.3mA", v) and abs(v - -3.3e-3) < 1e-15

test "parseIbisNumber: m is milli and M is mega, a million apart":
  var lo, hi: float
  check parseIbisNumber("1m", lo)
  check parseIbisNumber("1M", hi)
  check abs(hi / lo - 1e9) < 1.0   # 1e6 / 1e-3

test "parseIbisNumber refuses RKM notation and non-numbers":
  var v: float
  check not parseIbisNumber("2k2", v)     # EDA means 2200; IBIS has no RKM
  check not parseIbisNumber("NA", v)
  check not parseIbisNumber("output", v)
  check not parseIbisNumber("", v)

test "the comment character can be redefined and takes effect":
  let src = """
[IBIS Ver] 3.2
[Comment Char] #_char
[File Name] part.ibs # this is now a comment
| this bar is now data, not a comment
[End]
"""
  let secs = splitSections(newStringStream(src))
  check secs[0].keyword == "ibis_ver"
  check secs[2].keyword == "file_name"
  check secs[2].args == "part.ibs"          # trailing #-comment stripped
  check secs[2].body[0].text == "| this bar is now data, not a comment"

test "[End] terminates the file and text after it is ignored":
  let src = """
[IBIS Ver] 3.2
[End]
[Component] should_not_appear
garbage garbage garbage
"""
  let secs = splitSections(newStringStream(src))
  check secs[^1].keyword == "end"
  for s in secs:
    check s.keyword != "component"

test "sub-keywords nest under the open [Model] / [Component]":
  let src = """
[IBIS Ver] 3.2
[Component] buf
[Pin] signal_name model_name
1 A m1
[Model] m1
Model_type Output
[Pulldown]
-1.0 -1m -0.9m -1.1m
[End Model]
[End]
"""
  let secs = splitSections(newStringStream(src))
  let comp = secs[1]
  check comp.keyword == "component"
  check comp.children.len == 1
  check comp.children[0].keyword == "pin"
  let model = secs[2]
  check model.keyword == "model"
  check model.children.len == 1
  check model.children[0].keyword == "pulldown"
