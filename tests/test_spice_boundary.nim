import std/[math, os, streams, strutils, tables, unittest]

import nimcir/netlist/dsl
import nimcir/netlist/graph
import nimcir/netlist/annotations
import nimcir/netlist/formats/spice
import nimcir/units
import nimcir/spice/models
import nimcir/spice/transform
import nimcir/spice/boundary
import nimcir/spice/ngspice
import nimcir/analysis/analyses/pdn
import nimcir/spice/flatten
import std/sequtils

let haveNgspice = findExe("ngspice").len > 0

proc board(): Netlist =
  netlist("board"):
    net gnd, kind = ntGround, name = "0"
    net vbus, kind = ntPower
    net dp, kind = ntSignal
    component J1, kind = "connector", partNumber = "USB-C":
      pin "VBUS", vbus, kind = ptPower
      pin "GND", gnd, kind = ptGround
      pin "D+", dp, kind = ptInOut
    component R1, kind = "resistor", value = "100":
      pin "1", vbus, kind = ptPassive
      pin "2", gnd, kind = ptPassive
    component C1, kind = "capacitor", value = "10u":
      pin "1", vbus, kind = ptPassive
      pin "2", gnd, kind = ptPassive

suite "a connector is a boundary, not a part":
  # Each of its pins touches exactly one net, so there is nothing to pass
  # through *to*: a connector's electrical behaviour is entirely whatever is
  # plugged into it, which a netlist cannot know.

  test "its nets become ports, named after the nets":
    # Named by net rather than by `J1.VBUS`, because a net name is already
    # unique where a composite one would have to be invented and checked.
    var ports: seq[string]
    for (p, _) in connectorPorts(board()): ports.add p
    check ports == @["vbus", "dp"]

  test "ground is never a port":
    # SPICE node "0" is global; promoting it would create a second reference.
    for (p, _) in connectorPorts(board()):
      check p != "0"

  test "asSubcircuit removes the connector it replaced":
    # Leaving both would put a part with no SPICE device on the very boundary
    # it defines.
    let sub = asSubcircuit(board(), "USB_BOARD")
    check not sub.components.hasKey("J1")
    check sub.ports.len == 2
    check sub.components.hasKey("R1")

  test "the original is untouched":
    let orig = board()
    discard asSubcircuit(orig)
    check orig.components.hasKey("J1")
    check orig.ports.len == 0

  test "and it writes as a .SUBCKT, ports and all":
    # `writeNetlist` drops `Netlist.ports` -- correct for a board, since a
    # top-level deck has no port concept, and silently wrong for a template
    # built to be reused.
    let s = newStringStream()
    writeSubcktDefinition(asSubcircuit(board(), "USB_BOARD"), s)
    check ".SUBCKT USB_BOARD vbus dp" in s.data
    check ".ENDS USB_BOARD" in s.data
    check "R1 vbus 0 100" in s.data

suite "driving a board's ports":

  test "a port nobody described is left alone, not defaulted":
    # Inventing a supply for a pin nobody described is how a rail comes to
    # measure its own assumption back.
    let h = harness(board(), {"dp": driveOpen()})
    check not h.netlist.components.hasKey("V_EXT_vbus")

  test "an unknown port name raises rather than being ignored":
    expect NetlistError:
      discard harness(board(), {"nosuchnet": driveLoad(50.ohm)})

  test "a source is attached through its own output impedance":
    # An ideal source is a dead short at AC, so a port driven by one reports
    # the rail behind it as 0 ohm at every frequency and passes any
    # decoupling target. The R and L must be in the path.
    let h = harness(board(), {"vbus": driveSource(5.0.V, rout = 100.mohm,
                                                  lout = 2.uH)})
    check h.netlist.components.hasKey("V_EXT_vbus")
    check h.netlist.components.hasKey("R_EXT_vbus")
    check h.netlist.components.hasKey("L_EXT_vbus")
    var r: float
    check parseSpiceMagnitude(h.netlist.components["R_EXT_vbus"].attrs["value"], r)
    check abs(r - 0.1) < 1e-9

  test "the connector is gone from the harness":
    let h = harness(board(), {"vbus": driveSource(5.0.V)})
    check not h.netlist.components.hasKey("J1")

  test "every attachment is declared":
    let h = harness(board(), {"vbus": driveSource(5.0.V), "dp": driveLoad(45.ohm)})
    var sawSource, sawLoad = false
    for a in h.assumptions:
      if "driven from" in $a: sawSource = true
      if "loaded with" in $a: sawLoad = true
    check sawSource
    check sawLoad

  if not haveNgspice:
    echo "SKIP: ngspice not found on PATH"
  else:
    test "an undriven connector leaves the board with no supply at all":
      # The wrong answer this exists to fix. `expandPinModels` stands each
      # pin in with an impedance to ground, so a USB inlet becomes 1 Mohm to
      # ground and VBUS sits at zero.
      let naive = board()
      discard expandPinModels(naive)
      let r = run(naive, @[".op"])
      check abs(r["v(vbus)"][0]) < 1e-9

    test "and a driven port gives the supply the board actually has":
      let h = harness(board(), {"vbus": driveSource(5.0.V, rout = 100.mohm)})
      discard expandPinModels(h.netlist)
      let r = run(h.netlist, @[".op"])
      # 5 V through 100 mohm into the board's 100 ohm load.
      check abs(r["v(vbus)"][0] - 5.0 * 100.0 / 100.1) < 1e-6

suite "stating a drive on the design itself":
  # A `SimReplacement.build` proc is `{.nimcall.}` and so has no environment
  # to capture a drive in. Recording it on the pin is therefore not merely
  # tidier -- it is what makes the mechanism work -- and it has the better
  # property anyway: the drive is ordinary netlist data, visible and
  # survivable, rather than a closure nothing can read back.

  test "a drive round-trips through the pin it is recorded on":
    let nl = board()
    let p = nl.components["J1"].pins["VBUS"]
    setDrive(p, driveSource(5.0.V, rout = 100.mohm, lout = 2.uH))
    let back = driveOf(p)
    check back.kind == dkSource
    check abs(float(back.voltage) - 5.0) < 1e-9
    check abs(float(back.rout) - 0.1) < 1e-9

  test "a pin that says nothing is open, not defaulted":
    check driveOf(board().components["J1"].pins["D+"]).kind == dkOpen

  test "driveConnector refuses a part that is not a connector":
    let nl = board()
    expect NetlistError:
      driveConnector(nl.components["R1"], {"1": driveLoad(50.ohm)})

  test "and refuses a pin the connector does not have":
    let nl = board()
    expect NetlistError:
      driveConnector(nl.components["J1"], {"NOSUCH": driveLoad(50.ohm)})

  test "the design netlist keeps the connector; only the sim copy loses it":
    # This is the whole reason it goes through `simReplace` rather than
    # mutating the board: a BoM and a layout still see the part that gets
    # soldered.
    let nl = board()
    driveConnector(nl.components["J1"], {"VBUS": driveSource(5.0.V)})
    check nl.components.hasKey("J1")
    var globals: OrderedTable[string, Net]
    let sim = materializeSimNetlist(nl, globals)
    check not sim.components.hasKey("J1")
    check sim.components.hasKey("V_EXT_vbus")

  if not haveNgspice:
    echo "SKIP: ngspice not found on PATH"
  else:
    test "and the supply reaches an analysis that used to ignore simReplace":
      # `analysis/pdn`, `startup` and `opamp` plain-cloned, so a component's
      # own statement of how it wants to be simulated was silently dropped.
      let nl = board()
      driveConnector(nl.components["J1"],
                     {"VBUS": driveSource(5.0.V, rout = 100.mohm)})
      var globals: OrderedTable[string, Net]
      let sim = materializeSimNetlist(nl, globals)
      discard expandPinModels(sim)
      let r = run(sim, @[".op"])
      check abs(r["v(vbus)"][0] - 5.0 * 100.0 / 100.1) < 1e-6

suite "a port the board drives, rather than one that drives it":
  # `driveConnector` is symmetric: `driveSource` is a supply coming in,
  # `driveLoad`/`driveSink` are what the board powers going out.

  proc supplying(): Netlist =
    netlist("supply"):
      net gnd, kind = ntGround, name = "0"
      net vout, kind = ntPower:
        spec:
          voltage = 3.3.V
      component V1, kind = "voltage_source", value = "DC 3.3":
        pin "+", vout, kind = ptPower
        pin "-", gnd, kind = ptGround
      component J2, kind = "connector", partNumber = "JST-PH":
        pin "OUT", vout, kind = ptPower
        pin "GND", gnd, kind = ptGround

  test "a resistive load attaches a resistor":
    let h = harness(supplying(), {"vout": driveLoad(33.ohm)})
    check h.netlist.components.hasKey("R_EXT_vout")

  test "a constant-current sink attaches a current source, pulling the right way":
    # `I<name> N+ N- value` drives current from N+ through the source to N-,
    # so N+ on the port and N- on the reference is a sink.
    let h = harness(supplying(), {"vout": driveSink(100.mA)})
    let i = h.netlist.components["I_EXT_vout"]
    check i.kind == "current_source"
    check i.pins["+"].net.name == "vout"
    check i.pins["-"].net.name == "0"
    check "0.1" in i.attrs["value"] or "1.0" in i.attrs["value"]

  test "a source attached at a port is ideal, and says so":
    # The output impedance is already explicit in the R and L beside it.
    # Left unannotated, `expandSourceImpedance` sees a bare voltage_source
    # and adds its own default 10 mohm and 1 uH on top -- and that microhenry
    # rang against a board's 865 nF at 178 kHz and reported the rail at
    # 10.5 ohm where it is 10 mohm. A factor of a thousand, built entirely
    # out of impedance nobody asked for.
    let h = harness(supplying(), {"vout": driveLoad(33.ohm)})
    discard h
    let h2 = harness(board(), {"vbus": driveSource(5.0.V, rout = 100.mohm)})
    let v = h2.netlist.components["V_EXT_vbus"]
    check annotationFloat(v, "rout").has
    check annotationFloat(v, "rout").value == 0.0
    check annotationFloat(v, "lout").has
    check annotationFloat(v, "lout").value == 0.0

  test "a sink round-trips through the pin like any other drive":
    let nl = supplying()
    driveConnector(nl.components["J2"], {"OUT": driveSink(250.mA)})
    let back = driveOf(nl.components["J2"].pins["OUT"])
    check back.kind == dkSink
    check abs(float(back.current) - 0.25) < 1e-9

  if not haveNgspice:
    echo "SKIP: ngspice not found on PATH"
  else:
    test "both draw the current they say at the operating point":
      for (drive, expect) in [(driveLoad(33.ohm), 0.1), (driveSink(100.mA), 0.1)]:
        let h = harness(supplying(), {"vout": drive})
        discard expandPinModels(h.netlist)
        let r = run(h.netlist, @[".op"])
        check abs(r["v(vout)"][0] - 3.3) < 1e-6

    test "but they are not interchangeable, and the difference is at AC":
      # A resistor's current follows the rail, so it *damps* the decoupling
      # network; a constant-current sink is an open circuit at AC and damps
      # nothing. Modelling a regulated load as a resistor understates the
      # anti-resonant peak -- which is the thing a PDN sweep is run to find.
      proc peakWith(drive: PortDrive): float =
        let b = supplying()
        let c1 = addComponent(b, newComponent("C1", kind = "capacitor"))
        discard connect(c1, "1", b.nets["vout"], ptPassive)
        discard connect(c1, "2", b.nets["0"], ptPassive)
        c1.attrs["value"] = "10u"
        c1.attrs["package"] = "0805"
        c1.attrs["dielectric"] = "C0G"
        let c2 = addComponent(b, newComponent("C2", kind = "capacitor"))
        discard connect(c2, "1", b.nets["vout"], ptPassive)
        discard connect(c2, "2", b.nets["0"], ptPassive)
        c2.attrs["value"] = "100n"
        c2.attrs["package"] = "0402"
        c2.attrs["dielectric"] = "C0G"
        let h = harness(b, {"vout": drive})
        analyzePdn(h.netlist, "vout", "0")["z_antiresonance"]

      let damped = peakWith(driveLoad(33.ohm))
      let undamped = peakWith(driveSink(100.mA))
      check undamped > damped
      check (undamped - damped) / damped > 0.05

suite "boards as a system, and boards on their own":
  # The same board has to answer two questions: what does it do on the bench,
  # and what does it do plugged into the rest of the product. `asSubcircuit`
  # is what lets one description serve both.

  proc supplyBoard(): Netlist =
    netlist("supply"):
      net gnd, kind = ntGround, name = "0"
      net vin, kind = ntPower
      net vout, kind = ntPower
      component J1, kind = "connector":
        pin "VBUS", vin, kind = ptPower
        pin "GND", gnd, kind = ptGround
      component RREG, kind = "resistor", value = "1":
        pin "1", vin, kind = ptPassive
        pin "2", vout, kind = ptPassive
      component J2, kind = "connector":
        pin "OUT", vout, kind = ptPower
        pin "GND", gnd, kind = ptGround

  proc sensorBoard(): Netlist =
    netlist("sensor"):
      net gnd, kind = ntGround, name = "0"
      net vin, kind = ntPower
      component J3, kind = "connector":
        pin "IN", vin, kind = ptPower
        pin "GND", gnd, kind = ptGround
      component RLOAD, kind = "resistor", value = "24":
        pin "1", vin, kind = ptPassive
        pin "2", gnd, kind = ptPassive

  proc system(): Netlist =
    netlist("system"):
      net gnd, kind = ntGround, name = "0", global = true
      net usb, kind = ntPower
      net rail, kind = ntPower
      instance XA, asSubcircuit(supplyBoard(), "SUPPLY"),
               {"vin": usb, "vout": rail}
      instance XB, asSubcircuit(sensorBoard(), "SENSOR"), {"vin": rail}

  test "each board's connectors become its ports":
    check toSeq(asSubcircuit(supplyBoard()).ports.keys) == @["vin", "vout"]
    check toSeq(asSubcircuit(sensorBoard()).ports.keys) == @["vin"]

  test "a system wires them by name, because both call a port 'vin'":
    # Position would be a trap here: swapping two same-shaped nets raises
    # nothing and simulates happily.
    let sys = system()
    check sys.children.len == 2
    var globals: OrderedTable[string, Net]
    let flat = clone(sys, globals)
    discard flatten(flat)
    check flat.components.hasKey("XA.RREG")
    check flat.components.hasKey("XB.RLOAD")

  test "an unwired port raises, listing what the board exposes":
    var globals: OrderedTable[string, Net]
    let parent = newNetlist("p")
    let n = addNet(parent, newNet("n"))
    var msg = ""
    try:
      discard instantiateByPort(parent, "XA", asSubcircuit(supplyBoard()),
                                {"vin": n}, globals)
    except NetlistError as e:
      msg = e.msg
    check "vout" in msg
    check "not wired" in msg

  test "and so does a port the board does not have":
    var globals: OrderedTable[string, Net]
    let parent = newNetlist("p")
    let n = addNet(parent, newNet("n"))
    expect NetlistError:
      discard instantiateByPort(parent, "XA", asSubcircuit(sensorBoard()),
                                {"vin": n, "nosuch": n}, globals)

  test "the boards keep their own connectors; only the copies lose them":
    let a = supplyBoard()
    discard asSubcircuit(a)
    check a.components.hasKey("J1")
    check a.components.hasKey("J2")

  if not haveNgspice:
    echo "SKIP: ngspice not found on PATH"
  else:
    test "a board on its own answers only as well as its assumed load":
      # Which is the reason to assemble a system at all.
      proc alone(sink: Amps): float =
        let h = harness(supplyBoard(),
                        {"vin": driveSource(5.0.V, rout = 100.mohm),
                         "vout": driveSink(sink)})
        discard expandPinModels(h.netlist)
        run(h.netlist, @[".op"])["v(vout)"][0]
      check abs(alone(100.mA) - 4.89) < 0.01
      check abs(alone(400.mA) - 4.56) < 0.01

    test "and the system answers with the real board attached":
      # 5 V through 100 mohm + 1 ohm into the sensor's 24 ohm.
      let h = harness(system(), {"usb": driveSource(5.0.V, rout = 100.mohm)})
      discard flatten(h.netlist)
      discard expandPinModels(h.netlist)
      let v = run(h.netlist, @[".op"])["v(rail)"][0]
      check abs(v - 5.0 * 24.0 / 25.1) < 1e-3
