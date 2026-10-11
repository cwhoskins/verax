## Simulation-only voltage and current probes.
##
## Voltage probes need no mutation: ngspice's `write` dumps every node
## voltage (and source/inductor current), so `addVoltageProbe` is a label
## helper. Current at an arbitrary pin needs an inserted 0 V source, so
## `addCurrentProbe` mutates its netlist -- use a simulation clone.

import std/tables
import ../netlist/types
import ../netlist/graph
import ../netlist/formats/spice as spiceFormat
import ./provenance

type
  ProbeKind* = enum
    pkVoltage, pkCurrent

  Probe* = object
    kind*: ProbeKind
    label*: string
      ## ngspice vector expression, e.g. `"v(vout)"` or `"i(vprobe_u1_out)"`.
    net*: Net
      ## Voltage probe: the measured net. Current probe: the fresh net
      ## inserted between the pin and its original net.
    source*: Component
      ## Current probe only: the inserted 0 V source; `nil` otherwise.

proc addVoltageProbe*(net: Net): Probe =
  Probe(kind: pkVoltage, label: "v(" & net.name & ")", net: net)

proc addVoltageProbe*(netPos, netNeg: Net): Probe =
  ## Differential probe: `"v(a,b)"`.
  Probe(kind: pkVoltage, label: "v(" & netPos.name & "," & netNeg.name & ")", net: netPos)

proc addCurrentProbe*(nl: Netlist, pin: Pin, designator = ""): Probe =
  ## Splits `pin` onto a fresh net and wires a 0 V source between them (`+`
  ## on the original net), so the probe current has the sign of the current
  ## that flowed into `pin`. `designator` must start with `'V'`; empty
  ## derives `"VPROBE_<component>_<pin>"`.
  if not isConnected(pin):
    raise newException(NetlistError,
      "cannot add a current probe to an unconnected pin: " &
      pin.component.designator & "." & pin.name)
  # Refuse an XSPICE `A` device: its port text is frozen in
  # `attrs["xspice.ports"]`, so re-netting a pin moves it in the graph but
  # not the deck, and the probe would read zero on a live branch.
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
  let owner = designOf(pin.component)
  mark(src, brProbe, owner, "current into " & owner & "." & pin.name)
  probeNet.attrs[benchOfKey] = owner

  result = Probe(kind: pkCurrent, label: "i(" & desig & ")", net: probeNet, source: src)

proc addImpedanceProbe*(nl: Netlist, net, refNet: Net, designator = "",
                        amps = 1.0): Probe =
  ## Wires an AC current source `refNet` -> `net` so an `.ac` sweep reads
  ## that node's driving-point impedance. At the default 1 A, `v(<net>)`
  ## *is* Z in ohms (linear analysis, so the level doesn't matter). `DC 0`
  ## leaves the operating point alone. Measures the fragment as it stands,
  ## so the rail under test must not be terminated with an ideal source
  ## (`IsolationSpec.excludeRails`).
  var desig = designator
  if desig.len == 0:
    desig = "IPROBE_" & net.name
  elif desig[0] != spiceFormat.designatorPrefix("current_source"):
    raise newException(NetlistError, "impedance probe designator must start with 'I': " & desig)
  if nl.components.hasKey(desig):
    raise newException(NetlistError, "designator already in use: " & desig)

  let src = addComponent(nl, newComponent(desig, kind = "current_source"))
  # SPICE convention: current flows through the source from the first node
  # to the second, i.e. into the second.
  discard connect(src, "+", refNet, ptPassive)
  discard connect(src, "-", net, ptPassive)
  src.attrs["value"] = "DC 0 AC " & spiceValue(amps)
  mark(src, brStimulus, note = spiceValue(amps) & " A AC injected into '" &
       net.name & "'")
  mark(net, brProbe, note = "V = Z in ohms at 1 A")

  result = Probe(kind: pkVoltage, label: "v(" & net.name & ")", net: net, source: src)
