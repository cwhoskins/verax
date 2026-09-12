import std/[tables, unittest]
import verax/netlist
import verax/netlist/interfaces

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

  test "wiringOf on a bus member-suffixes wide, bares width-1":
    let nl = newNetlist("b")
    let dq = addBus(nl, "dq", 4)
    let w = wiringOf("host", dq)
    check w.len == 4
    check w[0] == ("host_0", dq[0])
    check w[3] == ("host_3", dq[3])
    let one = addBus(nl, "irq", 1)
    check wiringOf("host", one) == @[("host", one[0])]

suite "multi-dimensional bus views":
  test "names members row-major and keeps the flat index/width unchanged":
    let nl = newNetlist("b")
    let a = addBus(nl, "a", [8, 2])
    check a.len == 16
    check a.dims == @[8, 2]
    check a.nets[0].name == "a_0_0"
    check a.nets[1].name == "a_0_1"
    check a.nets[2].name == "a_1_0"
    check a.nets[15].name == "a_7_1"
    check a.nets[6].attrs["bus.index"] == "6"     # flat row-major, unchanged shape
    check a.nets[6].attrs["bus.width"] == "16"
    check a.nets[6].attrs["bus.name"] == "a"

  test "records and recovers the shape":
    let nl = newNetlist("b")
    discard addBus(nl, "a", [8, 2])
    check nl.findNet("a_3_1").attrs["bus.dims"] == "8,2"
    check nl.findNet("a_3_1").attrs["bus.coord"] == "3,1"
    let recovered = findBus(nl, "a")
    check recovered.dims == @[8, 2]
    check recovered.len == 16
    check recovered.nets[6].name == "a_3_0"

  test "a 1-D bus stamps no shape attrs":
    let nl = newNetlist("b")
    let dq = addBus(nl, "dq", 4)
    check "bus.dims" notin dq.nets[0].attrs
    check "bus.coord" notin dq.nets[0].attrs
    check findBus(nl, "dq").dims.len == 0

  test "rejects an empty or non-positive dimension":
    let nl = newNetlist("b")
    expect NetlistError: discard addBus(nl, "a", newSeq[int](0))
    expect NetlistError: discard addBus(nl, "a", [8, 0])
    expect NetlistError: discard addBus(nl, "a", [-1, 2])

  test "element access matches the bus's own shape":
    let nl = newNetlist("b")
    let a = addBus(nl, "a", [8, 2])
    check a[3, 1] == a.nets[7]
    expect NetlistError: discard a[3]              # 1-D index on a 2-D bus
    expect NetlistError: discard a[0 .. 1]
    let dq = addBus(nl, "dq", 4)
    expect NetlistError: discard dq[0, 1]           # 2-D index on a 1-D bus

  test "sub drops the outer dimension and writes nothing to the netlist":
    let nl = newNetlist("b")
    let a = addBus(nl, "a", [8, 2])
    let s3 = a.sub(3)
    check s3.name == "a_3"
    check s3.len == 2
    check s3.dims == @[2]
    check s3[0] == a[3, 0]
    check s3[1] == a[3, 1]
    # Pure value space: the member nets' own `bus.index`/`bus.coord` still
    # name their place in the parent `a`, unrewritten by the slice.
    check nl.findNet("a_3_0").attrs["bus.index"] == "6"
    check nl.findNet("a_3_0").attrs["bus.coord"] == "3,0"
    check nl.findNet("a_3_0").attrs["bus.name"] == "a"

  test "sub raises on a 1-D bus":
    let nl = newNetlist("b")
    let dq = addBus(nl, "dq", 4)
    expect NetlistError: discard dq.sub(0)

  test "addPorts and wiringOf agree on multi-dim member names":
    let nl = newNetlist("b")
    let a = addBus(nl, "a", [8, 2])
    addPorts(nl, "p", a)
    check nl.ports.hasKey("p_3_1")
    check nl.ports["p_3_1"] == a[3, 1]
    let w = wiringOf("q", a)
    check w.len == 16
    check w[7] == ("q_3_1", a[3, 1])

  test "busOf stays 1-D and clears any shape it inherits":
    let nl = newNetlist("b")
    let a = addBus(nl, "a", [2, 2])
    let re = busOf(nl, "flat", a.nets)
    check re.dims.len == 0
    check "bus.dims" notin a.nets[0].attrs
    check "bus.coord" notin a.nets[0].attrs
