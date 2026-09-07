## The edge of a board: where it stops, and what is on the other side.
##
## A connector is not a component in the sense the rest of this library uses
## the word. Each of its pins touches exactly one net, so there is nothing to
## pass *through* to -- its electrical behaviour is entirely whatever is
## plugged into it, and a netlist cannot know that. That is why standing one
## in with per-pin impedances is wrong in a specific way rather than merely
## approximate: `models.expandPinModels` gives each pin an impedance to
## ground, which for a USB inlet means **VBUS as 1 Mohm to ground and no
## supply on the board at all**.
##
## So a connector is treated here as a *boundary marker*, and two separate
## things follow from that. They are separable and only one of them fixes a
## wrong answer:
##
## * `asSubcircuit` promotes every connector pin's net to a port and drops the
##   connectors, giving the board as a reusable `.SUBCKT`. This is a
##   **composition** feature -- exporting the board into somebody else's deck,
##   or instantiating it twice -- and it changes no measurement.
## * `harness` attaches what is outside: a source of stated stiffness, a load,
##   or nothing. This is the **simulation** feature, and it is what turns the
##   1 Mohm above into the supply the board actually has.
##
## Worth stating plainly because it is not obvious: for simulation the
## subcircuit round-trip buys nothing. Instantiating the board and then
## flattening it produces the same netlist as attaching the drives directly,
## which is why `harness` does the latter. The subcircuit is for export and
## for saying where the boundary *is*, not for making the sums come out.

import std/[strutils, tables]

import ../netlist/types
import ../netlist/graph
import ../netlist/kinds
import ../netlist/annotations
import ../netlist/formats/spice as spiceFormat
import ./models
import ../units
import ../eng

const connectorKinds* = ["connector", "header", "receptacle", "socket",
                         "terminal_block", "test_point"]
  ## Kinds treated as a board edge rather than as a part.

type
  DriveKind* = enum
    dkSource   ## something out there drives this pin
    dkLoad     ## something out there loads it, resistively
    dkSink     ## something out there draws a fixed current
    dkOpen     ## nothing is plugged in

  PortDrive* = object
    ## What is on the other side of one port.
    case kind*: DriveKind
    of dkSource:
      voltage*: Volts
      rout*: Ohms
      lout*: Henries
    of dkLoad:
      impedance*: Ohms
    of dkSink:
      current*: Amps
    of dkOpen:
      discard

proc driveSource*(voltage: Volts, rout = 10.mohm, lout = 0.H): PortDrive =
  ## A supply attaching here. `rout`/`lout` are its output impedance, and
  ## they matter more than the voltage does for anything measured in the
  ## frequency domain: **an ideal source is a dead short at AC**, so a port
  ## driven by one reports the rail behind it as 0 ohm at every frequency and
  ## passes any decoupling target. The default is deliberately non-zero.
  PortDrive(kind: dkSource, voltage: voltage, rout: rout, lout: lout)

proc driveLoad*(impedance: Ohms): PortDrive =
  PortDrive(kind: dkLoad, impedance: impedance)

proc driveSink*(current: Amps): PortDrive =
  ## Something out there drawing a fixed current -- an MCU board, a sensor
  ## module, anything regulating its own supply.
  ##
  ## **Not the same as `driveLoad` and the difference is not only accuracy.**
  ## A resistor and a current source can be made to agree at one operating
  ## point, and they behave oppositely away from it: a resistor's current
  ## follows the rail, so it *damps* the decoupling network, while a constant
  ## current sink is an **open circuit at AC** and damps nothing. A PDN sweep
  ## against a resistive stand-in for a regulated load therefore reports an
  ## impedance peak lower than the board will have. Most real sinks -- an MCU,
  ## a module with its own regulator -- are much closer to constant current.
  PortDrive(kind: dkSink, current: current)

proc driveOpen*(): PortDrive =
  PortDrive(kind: dkOpen)

proc isConnector*(c: Component): bool =
  c != nil and c.kind.toLowerAscii in connectorKinds

proc connectorPorts*(nl: Netlist): seq[tuple[port: string, net: Net]] =
  ## Every net a connector pin sits on, named by the **net**, not by the
  ## connector.
  ##
  ## Named by the net because that is what `extract.extractSubcircuit`
  ## already does for a computed boundary, and because it cannot collide:
  ## net names are unique within a netlist where `J1.VBUS`-style names would
  ## have to be invented and checked. Ground is never a port -- SPICE node
  ## `"0"` is global, so promoting it would create a second reference.
  var seen: seq[string]
  for _, c in nl.components:
    if not isConnector(c): continue
    for _, p in c.pins:
      if p.net == nil or isGround(p.net): continue
      if p.net.name in seen: continue
      seen.add p.net.name
      result.add (port: p.net.name, net: p.net)

proc asSubcircuit*(nl: Netlist, name = ""): Netlist =
  ## The board as a reusable `.SUBCKT`, with its connector nets as ports.
  ##
  ## Clones; `nl` is untouched. The connector components themselves are
  ## **removed**, because a port is what a connector *was* -- leaving both
  ## would put a part with no SPICE device on the boundary it defines.
  var globals: OrderedTable[string, Net]
  result = clone(nl, globals)
  if name.len > 0: result.name = name

  let ports = connectorPorts(result)
  var drop: seq[string]
  for designator, c in result.components:
    if isConnector(c): drop.add designator
  for designator in drop: removeComponent(result, designator)

  for (port, net) in ports:
    addPort(result, port, net)

proc attachDrives*(nl: Netlist, drives: openArray[(string, PortDrive)]):
    seq[Assumption] =
  ## Attaches what is outside each named net, in place.
  ##
  ## A port with no entry is left alone rather than defaulted: inventing a
  ## supply for a pin nobody described is exactly the kind of guess that makes
  ## a rail measure its own assumption back.
  let gnd = groundOf(nl)
  if gnd == nil:
    result.add note("no ground reference, so nothing could be attached to " &
                    "the board's ports")
    return

  for (portName, drive) in drives:
    let net = findNet(nl, portName)
    if net == nil:
      raise newException(NetlistError,
        "cannot drive port '" & portName & "': no such net. The ports are " &
        "named after the nets the connector pins sit on.")

    case drive.kind
    of dkOpen:
      result.add note("port '" & portName & "' is driven by nothing; it " &
        "keeps whatever DC reference the rest of the board gives it")
    of dkSink:
      # `I<name> N+ N- value` drives current from N+ through the source to
      # N-, so this one pulls out of the port and into the reference: a sink.
      let i = addComponent(nl, newComponent(
        $spiceFormat.designatorPrefix("current_source") & "_EXT_" & portName,
        kind = "current_source"))
      discard connect(i, "+", net, ptPassive)
      discard connect(i, "-", gnd, ptPassive)
      i.attrs["value"] = "DC " & spiceValue(float(drive.current))
      result.add note("port '" & portName & "' sinks " &
        eng(float(drive.current), "A") & " at constant current, which is an " &
        "open circuit at AC and so damps the decoupling network not at all")
    of dkLoad:
      let r = addComponent(nl, newComponent(
        $spiceFormat.designatorPrefix("resistor") & "_EXT_" & portName,
        kind = "resistor"))
      discard connect(r, "1", net, ptPassive)
      discard connect(r, "2", gnd, ptPassive)
      r.attrs["value"] = spiceValue(float(drive.impedance))
      result.add note("port '" & portName & "' loaded with " &
        eng(float(drive.impedance), "ohm") & " to represent what is plugged in")
    of dkSource:
      # Source -> series R -> series L -> the port, so the stated output
      # impedance is actually in the path. Attaching an ideal source straight
      # to the net would be a dead short at AC.
      let mid = addNet(nl, newNet(portName & "_EXT_S"))
      let midL = addNet(nl, newNet(portName & "_EXT_L"))
      let v = addComponent(nl, newComponent(
        $spiceFormat.designatorPrefix("voltage_source") & "_EXT_" & portName,
        kind = "voltage_source"))
      discard connect(v, "+", mid, ptPassive)
      discard connect(v, "-", gnd, ptPassive)
      v.attrs["value"] = "DC " & spiceValue(float(drive.voltage))
      setRailVoltage(net, drive.voltage, annAuthored)
      # The source itself is ideal **and must be said to be**, because the
      # output impedance is already explicit in the R and L below. Left
      # unannotated, `models.expandSourceImpedance` sees a bare
      # `voltage_source` and adds its own default 10 mohm and **1 uH** on top
      # -- and that microhenry is not a rounding error. Measured: a bench
      # supply stated as 10 mohm rang against a board's 865 nF at 178 kHz and
      # reported the rail at 10.5 ohm, an anti-resonance built entirely out
      # of impedance nobody asked for. `rout = 0` plus `lout = 0` is
      # documented as the way to opt back into an ideal source.
      setAnnotation(v, "rout", 0.0.ohm, annAuthored)
      setAnnotation(v, "lout", 0.0.H, annAuthored)

      let r = addComponent(nl, newComponent(
        $spiceFormat.designatorPrefix("resistor") & "_EXT_" & portName,
        kind = "resistor"))
      discard connect(r, "1", mid, ptPassive)
      discard connect(r, "2", midL, ptPassive)
      r.attrs["value"] = spiceValue(max(float(drive.rout), 1.0e-9))

      let l = addComponent(nl, newComponent(
        $spiceFormat.designatorPrefix("inductor") & "_EXT_" & portName,
        kind = "inductor"))
      discard connect(l, "1", midL, ptPassive)
      discard connect(l, "2", net, ptPassive)
      l.attrs["value"] = spiceValue(max(float(drive.lout), 1.0e-15))

      result.add note("port '" & portName & "' driven from " &
        eng(float(drive.voltage), "V") & " through " &
        eng(float(drive.rout), "ohm") & " and " &
        eng(float(drive.lout), "H") & " of source impedance")

proc harness*(nl: Netlist, drives: openArray[(string, PortDrive)]):
    tuple[netlist: Netlist, assumptions: seq[Assumption]] =
  ## The board with its outside world attached, ready to simulate.
  ##
  ## Clones, drops the connector components, and attaches each drive at the
  ## net that connector pin sat on. **Not** built by instantiating
  ## `asSubcircuit`'s template: flattening would immediately undo that, and
  ## the result would be identical for more work. The subcircuit is for
  ## export; this is for simulating.
  var globals: OrderedTable[string, Net]
  let work = clone(nl, globals)
  var drop: seq[string]
  for designator, c in work.components:
    if isConnector(c): drop.add designator
  for designator in drop: removeComponent(work, designator)
  (netlist: work, assumptions: attachDrives(work, drives))

# --- stating a drive on the design itself -------------------------------

const
  driveVoltageAttr* = "boundary.voltage"
  driveRoutAttr* = "boundary.rout"
  driveLoutAttr* = "boundary.lout"
  driveLoadAttr* = "boundary.load"
  driveSinkAttr* = "boundary.sink"
    ## What is plugged into a connector pin, recorded **on the pin**.
    ##
    ## Namespaced, so the annotation registry never validates them and no new
    ## bare keys are spent -- and, more usefully, this makes a drive ordinary
    ## netlist *data* rather than a captured closure. It is visible in the
    ## netlist, it survives `clone`, and anything can read it back. A
    ## `SimReplacement.build` proc is `{.nimcall.}` and therefore has no
    ## environment to capture a drive in, so this is not merely tidier: it is
    ## what makes the mechanism work at all.

proc driveOf*(p: Pin): PortDrive =
  ## The drive recorded on a pin, or `dkOpen` when it says nothing.
  if p == nil: return driveOpen()
  if p.attrs.hasKey(driveVoltageAttr):
    let v = parseAnnFloat(driveVoltageAttr, p.attrs[driveVoltageAttr])
    let r = if p.attrs.hasKey(driveRoutAttr):
              parseAnnFloat(driveRoutAttr, p.attrs[driveRoutAttr])
            else: 0.01
    let l = if p.attrs.hasKey(driveLoutAttr):
              parseAnnFloat(driveLoutAttr, p.attrs[driveLoutAttr])
            else: 0.0
    return driveSource(Volts(v), Ohms(r), Henries(l))
  if p.attrs.hasKey(driveSinkAttr):
    return driveSink(Amps(parseAnnFloat(driveSinkAttr, p.attrs[driveSinkAttr])))
  if p.attrs.hasKey(driveLoadAttr):
    return driveLoad(Ohms(parseAnnFloat(driveLoadAttr, p.attrs[driveLoadAttr])))
  driveOpen()

proc setDrive*(p: Pin, drive: PortDrive) =
  ## Records what is plugged into this pin.
  if p == nil: return
  case drive.kind
  of dkSource:
    p.attrs[driveVoltageAttr] = $float(drive.voltage)
    p.attrs[driveRoutAttr] = $float(drive.rout)
    p.attrs[driveLoutAttr] = $float(drive.lout)
  of dkLoad:
    p.attrs[driveLoadAttr] = $float(drive.impedance)
  of dkSink:
    p.attrs[driveSinkAttr] = $float(drive.current)
  of dkOpen:
    discard

proc buildConnectorBoundary*(nl: Netlist, old: Component): Component
    {.nimcall.} =
  ## A `SimReplacement.build` for a connector: replace it with whatever its
  ## pins say is plugged into them.
  ##
  ## This is what `simReplace` is for -- "for simulation purposes, replace
  ## this component with ..." -- and a connector replaced by its external
  ## world is exactly that. The design netlist keeps the connector, so a BoM
  ## and a layout still see the part that gets soldered; only the simulation
  ## copy sees the supply behind it.
  var drives: seq[(string, PortDrive)]
  for _, p in old.pins:
    if p.net == nil or isGround(p.net): continue
    let d = driveOf(p)
    if d.kind == dkOpen: continue
    drives.add (p.net.name, d)
  removeComponent(nl, old.designator)
  discard attachDrives(nl, drives)
  nil

proc driveConnector*(c: Component, pinDrives: openArray[(string, PortDrive)]) =
  ## States what is plugged into a connector, and arranges for simulation to
  ## see it.
  ##
  ## Call it after the `design(...)` block. It records each drive on the named
  ## pin and installs the `simReplace` that acts on it, touching nothing else
  ## -- the connector stays in the design netlist as the part it is.
  if c == nil: raise newException(NetlistError, "driveConnector on nil")
  if not isConnector(c):
    raise newException(NetlistError,
      c.designator & " is kind '" & c.kind & "', not a connector; only a " &
      "board edge has an outside to describe")
  for (pinName, drive) in pinDrives:
    if not c.pins.hasKey(pinName):
      var names: seq[string]
      for k in c.pins.keys: names.add k
      raise newException(NetlistError,
        "no pin '" & pinName & "' on " & c.designator & "; it has: " &
        names.join(", "))
    setDrive(c.pins[pinName], drive)
  c.simReplace = newSimReplacement(buildConnectorBoundary)
