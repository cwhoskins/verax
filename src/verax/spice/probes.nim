## Simulation-only voltage and current probes.
##
## Voltage probing needs no graph mutation at all: an ngspice `.control`/
## `write` with no explicit vector list already dumps every node voltage
## (and every voltage-source/inductor current) with zero netlist changes, so
## `addVoltageProbe` is a pure label/lookup helper.
##
## Current probing at an arbitrary device pin does need mutation, because
## ngspice only exposes branch current for voltage sources (and inductors) --
## there's no way to ask for "current into pin P of an arbitrary
## resistor/subckt" without inserting something that measures it.
##
## Like `verax/spice/transform`, `addCurrentProbe` mutates whatever
## `Netlist` it's given -- call it on a simulation netlist (e.g. the result
## of `materializeSimNetlist`), never on the real design netlist.

import std/tables
import ../netlist/types
import ../netlist/graph
import ../netlist/formats/spice as spiceFormat

type
  ProbeKind* = enum
    pkVoltage, pkCurrent

  Probe* = object
    kind*: ProbeKind
    label*: string
      ## ngspice vector expression, e.g. `"v(vout)"` or `"i(vprobe_u1_out)"`.
    net*: Net
      ## Voltage probe: the net being measured. Current probe: the fresh
      ## probe-local net inserted between the pin and its original net.
    source*: Component
      ## Current probe only: the inserted 0V voltage source. `nil` for a
      ## voltage probe.

proc addVoltageProbe*(net: Net): Probe =
  Probe(kind: pkVoltage, label: "v(" & net.name & ")", net: net)

proc addVoltageProbe*(netPos, netNeg: Net): Probe =
  ## Differential probe: `"v(a,b)"`.
  Probe(kind: pkVoltage, label: "v(" & netPos.name & "," & netNeg.name & ")", net: netPos)

proc addCurrentProbe*(nl: Netlist, pin: Pin, designator = ""): Probe =
  ## Splits `pin` off its net onto a fresh probe-local net and wires a 0V
  ## voltage source between them (via `graph.nim`'s existing addNet/
  ## disconnect/connect/addComponent only -- no new graph.nim primitive
  ## needed). `+` is wired to `pin`'s original net, `-` to the new
  ## probe-local net, so the probe's current sign matches the branch
  ## current that used to flow into `pin`.
  ##
  ## `designator`, like `transform.replaceComponent`, must start with `'V'`
  ## if supplied (SPICE infers device type from the designator's leading
  ## letter), and is auto-derived as `"VPROBE_<component>_<pin>"` if empty.
  if not isConnected(pin):
    raise newException(NetlistError,
      "cannot add a current probe to an unconnected pin: " &
      pin.component.designator & "." & pin.name)
  # An XSPICE `A` line is not written from the component's pins: the port
  # text was rendered from the model's own `ModelSpec` at
  # `xspice/instance.addCodeModelInstance` time and lives verbatim in
  # `attrs["xspice.ports"]`. Re-netting a pin therefore moves it in the
  # graph and **not** in the deck, so the probe source would end up in
  # series with nothing while the code model went on driving the original
  # net -- a probe reading zero on a branch that is carrying current, which
  # is the one failure a measurement must never have.
  if pin.component != nil and pin.component.attrs.hasKey("xspice.ports"):
    raise newException(NetlistError,
      "cannot add a current probe to " & pin.component.designator & "." &
      pin.name & ": it is an XSPICE code model, whose port text is rendered " &
      "from the model spec rather than from its pins, so moving a pin would " &
      "not move it in the deck. Probe a passive part in series with it instead.")

  var desig = designator
  if desig.len == 0:
    desig = "VPROBE_" & pin.component.designator & "_" & pin.name
  elif desig[0] != spiceFormat.designatorPrefix("voltage_source"):
    raise newException(NetlistError, "current probe designator must start with 'V': " & desig)

  var netName = desig & "_NET"
  var suffix = 0
  while nl.nets.hasKey(netName):
    inc suffix
    netName = desig & "_NET" & $suffix

  let originalNet = pin.net
  let probeNet = addNet(nl, newNet(netName))
  disconnect(pin)
  connect(pin, probeNet)

  let src = addComponent(nl, newComponent(desig, kind = "voltage_source"))
  discard connect(src, "+", originalNet)
  discard connect(src, "-", probeNet)

  result = Probe(kind: pkCurrent, label: "i(" & desig & ")", net: probeNet, source: src)

proc addImpedanceProbe*(nl: Netlist, net, refNet: Net, designator = "",
                        amps = 1.0): Probe =
  ## Wires a constant-amplitude AC current source across `refNet` -> `net` so
  ## an `.ac` sweep reads that node's driving-point impedance directly.
  ##
  ## With the default 1 A drive, `v(<net>)` **is** Z in ohms -- no division,
  ## no second probe, no scaling on the way out. That is the whole reason the
  ## amplitude defaults to 1 rather than something physically plausible: an
  ## `.ac` analysis is linear, so the drive level cannot affect the answer,
  ## and 1 A makes the answer readable without arithmetic.
  ##
  ## The source is `DC 0` so it contributes nothing to the operating point.
  ## Note this measures impedance *as the fragment stands*: whatever else is
  ## connected to `net` is part of the answer, which is why the rail under
  ## test must not also be terminated with an ideal voltage source (see
  ## `verax/spice/isolate.IsolationSpec.excludeRails` -- an ideal source is a
  ## short at AC and would report Z = 0 everywhere).
  var desig = designator
  if desig.len == 0:
    desig = "IPROBE_" & net.name
  elif desig[0] != spiceFormat.designatorPrefix("current_source"):
    raise newException(NetlistError, "impedance probe designator must start with 'I': " & desig)
  if nl.components.hasKey(desig):
    raise newException(NetlistError, "designator already in use: " & desig)

  let src = addComponent(nl, newComponent(desig, kind = "current_source"))
  # SPICE current-source convention: current flows through the source from
  # the first node to the second, i.e. it is *injected into* the second one.
  discard connect(src, "+", refNet, ptPassive)
  discard connect(src, "-", net, ptPassive)
  src.attrs["value"] = "DC 0 AC " & spiceValue(amps)

  result = Probe(kind: pkVoltage, label: "v(" & net.name & ")", net: net, source: src)
