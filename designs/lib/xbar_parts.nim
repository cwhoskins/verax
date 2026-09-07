## Parts and one role shared across the crossbar-switch chunks.
##
## `designs/xbar_switch.nim` is a five-board system -- an Ethernet-controlled
## 4x4 RF crossbar, powered from PoE or USB-C. The chunks
## (`designs/xbar_poe.nim` and friends) each import this module for:
##
## * the `.MODEL` cards the PoE front end and the power OR-ing lean on, spelled
##   once here for the reason `designs/lib/parts.nim` gives -- a card is
##   verbatim and unparsed, so a retyped one is a different part with nothing
##   reported;
## * `controlPulldowns`, the bank of pulldown resistors that makes the RF
##   switches' power-on state a property of the board rather than of firmware;
## * `safe_default`, a role that claims a control line sits near ground with
##   nothing driving it.
##
## Nothing here needs a simulator: the role's one claim is `dc_voltage`, which
## a bare `require` already reaches. The role earns its place by bundling eight
## identical claims behind one rationale and one threshold.

import std/tables

import verax/contract/dsl
import verax/contract/roles/core
import verax/netlist/graph
import verax/netlist/types

# --- model cards -----------------------------------------------------------

const
  dBridge* = "SS1M"
  dBridgeCard* =
    "D(IS=5e-9 RS=0.03 N=1.8 CJO=45p M=0.45 VJ=0.5 BV=1000 IBV=5u " &
    "TT=2u EG=1.11 XTI=3)"
    ## 1 A / 1000 V glass-passivated rectifier, the diode a PoE bridge is
    ## built from. Forward drop about 0.9 V at 500 mA, which is why a bridge
    ## costs the PD roughly 1.8 V of the 37 V floor. `BV=1000` because a PD
    ## bridge sees the full line plus ringing and 600 V parts are marginal.

  dOring* = "IDEAL_OR"
  dOringCard* =
    "D(N=1 IS=0.05 RS=0.01 CJO=0 BV=100 IBV=1u)"
    ## Not a real part. This is the ideal-diode approximation the OR-ing mux
    ## (`designs/lib/oring.nim`) stands in with: a large `IS` with `N=1`
    ## collapses the forward drop to about 100 mV at an amp while staying a
    ## smooth exponential a `.tran` can integrate through -- a stiffer knee
    ## (small `N`) is a near-vertical wall that stalls the switching model's
    ## transient with "timestep too small". `RS=0.01` is the mux FET's
    ## Rds(on). It exists so a `.op` and a `.tran` can be solved with either
    ## or both inlets live and the reverse-blocking claim has a real device
    ## to measure, not so that anyone believes the TPS2116 behaves exactly
    ## like this -- see the cannot-check list in `designs/xbar_switch.nim`.

  tvsSmaj58a* = "SMAJ58A"
  tvsSmaj58aCard* =
    "D(IS=1e-12 N=1.0 RS=1.2 BV=64.4 IBV=1m CJO=180p)"
    ## 58 V working / 64.4 V breakdown / 93 V clamp unidirectional TVS, on the
    ## rectified PoE rail. Modelled as a zener card -- the reverse knee is
    ## what matters and `BV` sets it. The clamp voltage under a real surge is
    ## not claimed; nothing here injects a surge. See the cannot-check list.

# --- the pulldown bank ----------------------------------------------------

proc controlPulldowns*(nl: Netlist, netNames: openArray[string],
                       value = "100k", gndName = "0") =
  ## Adds one resistor to ground on each named net.
  ##
  ## A loop rather than N copied lines because that is exactly the shape a
  ## value gets corrected in one place and not the others, and there are
  ## twenty-four of these. Call it after the `design(...)` block, addressing
  ## the control nets by name -- the DSL's `let` bindings do not leave the
  ## block they were made in.
  ##
  ## These are load-bearing, not housekeeping. Every ADG904's EN and select
  ## pins power up undriven -- the I2C expanders behind them come out of reset
  ## as high-impedance inputs -- so what holds EN low until firmware runs is
  ## this resistor and nothing else. `safe_default` below is the claim that
  ## checks it.
  let gnd = findNet(nl, gndName)
  if gnd == nil:
    raise newException(NetlistError,
      "controlPulldowns: no ground net '" & gndName & "'")
  for name in netNames:
    let n = findNet(nl, name)
    if n == nil:
      raise newException(NetlistError,
        "controlPulldowns: no such net '" & name & "'")
    let r = addComponent(nl, Component(designator: "RPD_" & name,
                                       kind: "resistor"))
    r.attrs["value"] = value
    discard connect(r, "1", n, ptPassive)
    discard connect(r, "2", gnd, ptPassive)

# --- the safe-default role ----------------------------------------------

proc safeDefaultExpand(inst: RoleInstance): seq[Assertion] =
  ## One claim: with nothing driving it, this net sits within `maxFraction` of
  ## the rail above ground -- i.e. low.
  ##
  ## `dc_voltage` and an absolute `<=` bound rather than anything cleverer,
  ## because the quantity registry is entirely electrical and "this pin reads
  ## as a logic low" has no quantity of its own. The threshold is a fraction
  ## of the rail so one number covers a 3.3 V and a 5 V board; it defaults to
  ## 10%, which is well inside any logic family's V_IL and well above the
  ## millivolts a 100 k pulldown actually leaves.
  let rail = paramFloat(inst, "rail", 3.3)
  let maxFraction = paramFloat(inst, "maxFraction", 0.1)
  var claim = Assertion(
    id: assertionId(inst, "low"),
    subjects: @[inst.subject("control")],
    quantity: "dc_voltage",
    expect: atMost(rail * maxFraction),
    unit: "V",
    severity: sevError,
    rationale:
      "an RF switch that powers up enabled would route a live input to an " &
      "output before firmware has decided anything; the pulldown on this " &
      "line is what makes the terminated state the default, and this checks " &
      "the pulldown is actually there and actually wins against the leakage " &
      "on the net",
    origin: inst.name)
  result.add claim

registerRole(RoleDef(
  name: "safe_default",
  doc: "A control line that must sit low when nothing is driving it.",
  parts: @[
    RolePart(name: "control", kind: skNet,
             doc: "the line that must default low (an RF switch enable)"),
  ],
  params: @[
    AnnDef(key: "rail", kind: akFloat, unit: "V", scopes: {asNet},
           doc: "the logic rail this line swings to; default 3.3 V"),
    AnnDef(key: "maxFraction", kind: akFloat, unit: "", scopes: {asNet},
           doc: "highest fraction of the rail that still reads low; " &
                "default 0.1"),
  ],
  apply: nil,
  expand: safeDefaultExpand))
