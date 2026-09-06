import std/unittest
import nimcir/netlist
import nimcir/netlist/interfaces

suite "bus views":
  test "creates ordered scalar members and survives rename":
    let nl = newNetlist("b")
    let dq = addBus(nl, "dq", 8)
    check dq.len == 8
    check dq[3].name == "dq_3"
    renameNet(nl, dq[3].name, "renamed")
    check findBus(nl, "dq")[3].name == "renamed"
  test "groups existing nets in requested order":
    let nl = newNetlist("b")
    let a = addNet(nl, newNet("a")); let b = addNet(nl, newNet("b"))
    let x = busOf(nl, "x", [b, a])
    check x[0] == b
  test "rejects invalid width and collisions":
    let nl = newNetlist("b")
    expect NetlistError: discard addBus(nl, "x", 0)
    discard addNet(nl, newNet("x_0"))
    expect NetlistError: discard addBus(nl, "x", 2)
