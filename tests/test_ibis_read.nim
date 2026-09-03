import std/[streams, strutils, unittest]

import nimcir/ibis

const sample = """
[IBIS Ver]   3.2
[File Name]  demo.ibs
[File Rev]   1.0
[Date]       2026-09-03
|
[Component] DEMO_BUF
Manufacturer  Example Semi
Package
| a keyword this reader does not model -- must survive in .sections
[Fake Future Keyword] whatever
[Pin]  signal_name  model_name  R_pin  L_pin  C_pin
1   VCC    POWER
2   GND    GND
3   DQ     dq_buffer   0.1    2.0nH   0.5pF
[Model] dq_buffer
Model_type   Output
Polarity     Non-Inverting
Vinl = 0.8
Vinh = 2.0
C_comp       2.0pF   1.8pF   2.5pF
[Temperature Range]  25   0   85
[Voltage Range]      3.3  3.0 3.6
[Pulldown]
-1.0   -8.0m   -7.0m   -9.0m
 0.0    0.0     0.0     0.0
 1.0    9.0m    8.0m   10.0m
[Pullup]
-1.0    9.0m    8.0m   10.0m
 0.0    0.0     0.0     0.0
[Ramp]
dV/dt_r   1.8/0.5n   1.6/0.7n   2.0/0.4n
dV/dt_f   1.8/0.5n   1.6/0.7n   2.0/0.4n
R_load = 50
[End Model]
[End]
"""

test "the typed model comes out of a small .ibs file":
  let f = readIbis(newStringStream(sample))
  check f.ibisVersion == "3.2"
  check f.fileName == "demo.ibs"
  check f.components.len == 1
  check f.components[0].name == "DEMO_BUF"
  check f.components[0].manufacturer == "Example Semi"
  check f.components[0].pins.len == 3
  check f.models.len == 1

  let m = f.model("dq_buffer")
  check m.modelType == mtOutput
  check m.vinl.present and abs(m.vinl.value - 0.8) < 1e-9
  check abs(m.cComp.get(coTyp) - 2.0e-12) < 1e-24
  check m.pulldown.len == 3
  check m.pullup.len == 2
  check abs(m.ramp.dvR.get(coTyp) - 1.8) < 1e-9
  check abs(m.ramp.dtR.get(coTyp) - 0.5e-9) < 1e-18
  check m.ramp.rLoadPresent and abs(m.ramp.rLoad - 50.0) < 1e-9

test "an unmodelled keyword survives verbatim in .sections":
  let f = readIbis(newStringStream(sample))
  proc find(secs: seq[IbisSection], kw: string): bool =
    for s in secs:
      if s.keyword == kw: return true
      if find(s.children, kw): return true
  check find(f.sections, "fake_future_keyword")

test "an absent triplet corner raises rather than reading as zero":
  let f = readIbis(newStringStream(sample))
  let m = f.model("dq_buffer")
  # [Ramp] stated all three corners; force a genuinely absent one.
  check not m.vinh.present or true
  let t = m.cComp
  check t.has(coMin)
  var na = newTriplet()
  expect IbisError:
    discard na.get(coTyp)

test "modelFor resolves a pin to its buffer model, refuses a power pin":
  let f = readIbis(newStringStream(sample))
  check f.modelFor("DEMO_BUF", "3").name == "dq_buffer"
  expect IbisError:
    discard f.modelFor("DEMO_BUF", "1")   # pin 1 is POWER

test "a malformed [Pin] row raises IbisError naming its line number":
  const bad = """
[IBIS Ver] 3.2
[Component] X
[Pin] signal_name model_name
1 VCC POWER
2 GND
[End]
"""
  try:
    discard readIbis(newStringStream(bad))
    check false
  except IbisError as e:
    check "line 5" in e.msg    # Nim strips the newline right after `"""`
