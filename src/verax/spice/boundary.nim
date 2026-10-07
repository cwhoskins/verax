## The edge of a board: where it stops, and what is on the other side.
##
## A connector's behaviour is whatever is plugged into it, which a netlist
## can't know; per-pin stand-ins make a USB inlet's VBUS 1 Mohm to ground
## with no supply at all. So connectors are treated as boundary markers:
##
## * `asSubcircuit` promotes connector nets to ports and drops the
##   connectors -- a **composition** feature (export, reuse); changes no
##   measurement.
## * `harness` attaches what's outside (a source of stated stiffness, a load,
##   or nothing) -- the **simulation** feature. It attaches drives directly;
##   instantiating the subcircuit and flattening would give the same netlist.

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
  ## A supply attaching here. `rout`/`lout` matter more than the voltage at
  ## AC: an ideal source is a dead short and passes any decoupling target.
  ## The default is deliberately non-zero.
  PortDrive(kind: dkSource, voltage: voltage, rout: rout, lout: lout)

proc driveLoad*(impedance: Ohms): PortDrive =
  PortDrive(kind: dkLoad, impedance: impedance)

proc driveSink*(current: Amps): PortDrive =
  ## A fixed-current draw (an MCU board, a regulated module). Unlike
  ## `driveLoad`, a current sink is open at AC and damps nothing; a
  ## resistive stand-in would understate the board's impedance peak.
  PortDrive(kind: dkSink, current: current)

proc driveOpen*(): PortDrive =
  PortDrive(kind: dkOpen)

proc isConnector*(c: Component): bool =
  c != nil and c.kind.toLowerAscii in connectorKinds

proc connectorPorts*(nl: Netlist): seq[tuple[port: string, net: Net]] =
  ## Every net a connector pin sits on, named by the **net** (unique, as
  ## `extractSubcircuit` does). Ground is never a port (node `"0"` is
  ## global).
  var seen: seq[string]
  for _, c in nl.components:
    if not isConnector(c): continue
    for _, p in c.pins:
      if p.net == nil or isGround(p.net): continue
      if p.net.name in seen: continue
      seen.add p.net.name
      result.add (port: p.net.name, net: p.net)

proc asSubcircuit*(nl: Netlist, name = ""): Netlist =
  ## The board as a reusable `.SUBCKT` with connector nets as ports. Clones;
  ## the connectors are **removed** (a port is what a connector was).
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
  ## Attaches what's outside each named net, in place. A port with no entry
  ## is left alone, never given an invented supply.
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
      # `I N+ N- value` drives N+ -> N-, so this pulls out of the port: a sink.
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
      # Source -> series R -> series L -> port, so the output impedance is in
      # the path.
      let mid = addNet(nl, newNet(portName & "_EXT_S"))
      let midL = addNet(nl, newNet(portName & "_EXT_L"))
      let v = addComponent(nl, newComponent(
        $spiceFormat.designatorPrefix("voltage_source") & "_EXT_" & portName,
        kind = "voltage_source"))
      discard connect(v, "+", mid, ptPassive)
      discard connect(v, "-", gnd, ptPassive)
      v.attrs["value"] = "DC " & spiceValue(float(drive.voltage))
      setRailVoltage(net, drive.voltage, annAuthored)
      # Mark the source ideal (`rout = 0`): the impedance is already explicit
      # in R and L, and `expandSourceImpedance` would otherwise add its own
      # default 10 mohm + 1 uH, which can resonate into a false
      # anti-resonance.
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
  ## The board with its outside world attached, ready to simulate: clones,
  ## drops connectors, attaches each drive at the connector's net.
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
    ## What's plugged into a connector pin, recorded **on the pin** as
    ## namespaced data: visible, survives `clone`, readable back. Required
    ## because a `{.nimcall.}` `build` proc can't capture a drive.

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
  ## A `SimReplacement.build` for a connector: replace it with what its pins
  ## say is plugged in. The design keeps the connector for BoM and layout.
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
  ## States what's plugged into a connector: records each drive on the named
  ## pin and installs the `simReplace`. Call after the `design(...)` block.
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
