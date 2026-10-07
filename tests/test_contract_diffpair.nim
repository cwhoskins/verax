## Differential pairs via the ordinary interface mechanism, and the
## `diff_pair` role.
##
## `diffPairInterface()` is a two-signal `InterfaceDef` that implies
## `"diff_pair"`. Pinned: the implied instance is created once per member,
## an explicit `role ... from =` pre-empts it, the same-net mistake is
## caught at attach time, `diff_pair_symmetry` walks the graph, and the
## board-dependent claims decline with a reason.

import std/[math, strutils, tables, unittest]

import verax/contract/dsl
import verax/contract/evaluate
import verax/contract/evaluators/diff
import verax/netlist/interfaces/std

proc resultFor(rs: seq[AssertionResult], id: string): AssertionResult =
  for r in rs:
    if r.assertion.id == id: return r
  raise newException(KeyError, "no result for " & id)

proc pairBoard(rValue = "22"): Design =
  ## A pair with matched series resistors on both legs, `rValue` each.
  design("board"):
    net gnd, kind = ntGround, name = "0"
    net p_in, kind = ntSignal
    net n_in, kind = ntSignal
    iface pair, diffPairInterface()
    component R1, kind = "resistor", value = rValue:
      pin "1", p_in, kind = ptPassive
      pin "2", pair["p"], kind = ptPassive
    component R2, kind = "resistor", value = "22":
      pin "1", n_in, kind = ptPassive
      pin "2", pair["n"], kind = ptPassive
    component U1, kind = "mcu":
      pin "P", pair["p"], kind = ptInOut
      pin "N", pair["n"], kind = ptInOut

suite "differential pairs":
  test "instantiating a paired interface implies one diff_pair role instance":
    let d = pairBoard()
    check d.roles.hasKey("pair")
    check d.roles["pair"].role == "diff_pair"
    check d.roles["pair"].bindings["p"].name == "pair_p"
    check d.roles["pair"].bindings["n"].name == "pair_n"

  test "an interface array implies one instance per member":
    let d = design("board"):
      iface lane, diffPairInterface(), count = 2
      component U1, kind = "mcu":
        pin "P0", lane[0]["p"], kind = ptInOut
        pin "N0", lane[0]["n"], kind = ptInOut
        pin "P1", lane[1]["p"], kind = ptInOut
        pin "N1", lane[1]["n"], kind = ptInOut
    check d.roles.hasKey("lane_0")
    check d.roles.hasKey("lane_1")
    check d.roles["lane_0"].bindings["p"].name == "lane_0_p"
    check d.roles["lane_1"].bindings["p"].name == "lane_1_p"

  test "an explicit role instance pre-empts the implied one":
    let d = design("board"):
      net gnd, kind = ntGround, name = "0"
      net p_in, kind = ntSignal
      net n_in, kind = ntSignal
      iface pair, diffPairInterface()
      component U1, kind = "mcu":
        pin "P", pair["p"], kind = ptInOut
        pin "N", pair["n"], kind = ptInOut
      role "diff_pair", pair, p = pair["p"], n = pair["n"],
           skew_intra_max = 5.ps
    # `addImpliedRoles` skips a taken name: one `pair` instance, with the
    # explicit parameter.
    check d.roles.len == 1
    let claims = expandInstance(d.roles["pair"])
    var found = false
    for a in claims:
      if a.quantity == "intra_pair_skew":
        found = true
        check almostEqual(a.expect.hi, 5.0e-12)
    check found

  test "binding p and n to the same net raises at attach time":
    expect NetlistError:
      discard design("board"):
        net a, kind = ntSignal
        role "diff_pair", bad, p = a, n = a

  test "usb2Interface states 90 ohm +/- 15% and no skew budget":
    let d = design("board"):
      iface usb0, usb2Interface()
      component U1, kind = "mcu":
        pin "P", usb0["p"], kind = ptInOut
        pin "N", usb0["n"], kind = ptInOut
    let claims = expandInstance(d.roles["usb0"])
    var sawZDiff = false
    var sawSkew = false
    for a in claims:
      if a.quantity == "z_diff":
        sawZDiff = true
        check almostEqual(a.expect.nominal, 90.0)
        check almostEqual(a.expect.fracTol, 0.15)
      if a.quantity == "intra_pair_skew": sawSkew = true
    check sawZDiff
    check not sawSkew

  test "diff_pair_symmetry passes when both legs carry matching parts":
    let d = pairBoard()
    let r = resultFor(evaluate(d), "pair.symmetry")
    check r.status == esPass
    check r.value == 1.0

  test "diff_pair_symmetry fails and names the mismatched part":
    let d = pairBoard(rValue = "0")
    let r = resultFor(evaluate(d), "pair.symmetry")
    check r.status == esFail
    check r.value == 0.0
    check r.issues.len == 1
    check r.issues[0].kind == "diff_pair_leg_mismatch"
    check "R1" in r.issues[0].message

  test "intra_pair_skew declines with a reason naming the board":
    let d = design("board"):
      net gnd, kind = ntGround, name = "0"
      net p_in, kind = ntSignal
      net n_in, kind = ntSignal
      iface pair, diffPairInterface()
      component U1, kind = "mcu":
        pin "P", pair["p"], kind = ptInOut
        pin "N", pair["n"], kind = ptInOut
      role "diff_pair", pair, p = pair["p"], n = pair["n"],
           skew_intra_max = 5.ps
    let r = resultFor(evaluate(d), "pair.intra_skew")
    check r.status == esNotEvaluable
    check "board" in r.reason

  test "z_diff declines with a reason naming the board":
    let d = design("board"):
      iface usb0, usb2Interface()
      component U1, kind = "mcu":
        pin "P", usb0["p"], kind = ptInOut
        pin "N", usb0["n"], kind = ptInOut
    let r = resultFor(evaluate(d), "usb0.z_diff")
    check r.status == esNotEvaluable
    check "board" in r.reason

  test "inter_pair_skew accepts N subjects and declines with a reason":
    let d = design("board"):
      net gnd, kind = ntGround, name = "0"
      net a_in, kind = ntSignal
      net b_in, kind = ntSignal
      net c_in, kind = ntSignal
      iface a, diffPairInterface()
      iface b, diffPairInterface()
      iface c, diffPairInterface()
      component U1, kind = "mcu":
        pin "AP", a["p"], kind = ptInOut
        pin "AN", a["n"], kind = ptInOut
        pin "BP", b["p"], kind = ptInOut
        pin "BN", b["n"], kind = ptInOut
        pin "CP", c["p"], kind = ptInOut
        pin "CN", c["n"], kind = ptInOut
      require inter_pair_skew(a["p"], b["p"], c["p"]) <= 200.ps,
              id = "REQ-SKEW"
    let r = resultFor(evaluate(d), "REQ-SKEW")
    check r.status == esNotEvaluable
    check "board" in r.reason
