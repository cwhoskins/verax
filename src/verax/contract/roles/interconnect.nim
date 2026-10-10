## Built-in roles for point-to-point interconnect: `diff_pair` and
## `si_net`. A pair is an ordinary two-signal `InterfaceDef` with signals
## `p`/`n`, so parts bind by name; this module holds only the claims.

import ../../netlist/types
import ../../netlist/annotations
import ./core

proc diffPairApply*(inst: RoleInstance, nl: Netlist) =
  ## Writes nothing; validates at attach time rather than at evaluation.
  let p = inst.subject("p")
  let n = inst.subject("n")
  if p.kind == skNet and n.kind == skNet and p.name == n.name:
    raise newException(NetlistError,
      "role 'diff_pair' instance '" & inst.name & "': p and n are the same net (" &
      p.name & ")")
  if inst.hasPart("driver") != inst.hasPart("rx"):
    raise newException(NetlistError,
      "role 'diff_pair' instance '" & inst.name & "': name both driver and rx (the " &
      "P leg's pins; the N leg's come from IBIS [Diff Pin]) or neither")
  for (n, leg) in [("driver_n", "driver"), ("rx_n", "rx")]:
    if inst.hasPart(n) and not inst.hasPart(leg):
      raise newException(NetlistError,
        "role 'diff_pair' instance '" & inst.name & "': " & n & " needs " & leg)
    if inst.hasPart(n) and inst.subject(n).name == inst.subject(leg).name:
      raise newException(NetlistError,
        "role 'diff_pair' instance '" & inst.name & "': " & n & " is " & leg &
        " (" & inst.subject(n).name & ")")

proc diffPairExpand*(inst: RoleInstance): seq[Assertion] =
  let p = inst.subject("p")
  let n = inst.subject("n")
  result.add Assertion(
    id: assertionId(inst, "symmetry"),
    subjects: @[p, n],
    quantity: "diff_pair_symmetry",
    expect: nominal(1.0, absTol = 0.0),
    severity: sevWarning,
    rationale: "the two legs of a differential pair should carry the same " &
               "series parts -- a coupling cap, a termination resistor, an " &
               "ESD clamp on one leg and not the other unbalances the pair",
    origin: inst.name)
  if hasParam(inst, "skew_intra_max"):
    result.add Assertion(
      id: assertionId(inst, "intra_skew"),
      subjects: @[p, n],
      quantity: "intra_pair_skew",
      expect: atMost(paramFloat(inst, "skew_intra_max", 0.0)),
      unit: "s",
      severity: sevError,
      rationale: "P and N must arrive within the pair's skew budget or the " &
                 "differential receiver sees a degraded eye",
      origin: inst.name)
  if hasParam(inst, "z_diff"):
    let target = paramFloat(inst, "z_diff", 0.0)
    let tol = paramFloat(inst, "z_diff_tol", 0.10)
    result.add Assertion(
      id: assertionId(inst, "z_diff"),
      subjects: @[p, n],
      quantity: "z_diff",
      expect: nominal(target, fracTol = tol),
      unit: "ohm",
      severity: sevError,
      rationale: "a mismatched differential impedance reflects part of the " &
                 "signal at every discontinuity along the trace",
      origin: inst.name)

const siReceiverParts = ["rx", "rx2", "rx3", "rx4"]

const siVictimParts* = ["victim", "victim_driver", "victim_rx"]

proc siNetApply*(inst: RoleInstance, nl: Netlist) =
  ## Validates at attach time: the driver is not also a receiver, and a
  ## crosstalk victim is named whole (its net, driver and receiver) or not
  ## at all.
  let d = inst.subject("driver")
  for p in siReceiverParts:
    if inst.hasPart(p) and inst.subject(p).name == d.name:
      raise newException(NetlistError,
        "role 'si_net' instance '" & inst.name & "': " & p & " is the driver (" & d.name & ")")
  var n = 0
  for p in siVictimParts:
    if inst.hasPart(p): inc n
  if n != 0 and n != siVictimParts.len:
    raise newException(NetlistError,
      "role 'si_net' instance '" & inst.name & "': a victim needs all of victim, " &
      "victim_driver and victim_rx")
  if (hasParam(inst, "min_eye_height") or hasParam(inst, "min_eye_width")) and
     not hasParam(inst, "ui"):
    raise newException(NetlistError,
      "role 'si_net' instance '" & inst.name & "': an eye claim needs `ui` (the bit rate)")
  if n > 0 and inst.subject("victim").name == inst.subject("net").name:
    raise newException(NetlistError,
      "role 'si_net' instance '" & inst.name & "': the victim is the net itself")

proc siNetExpand*(inst: RoleInstance): seq[Assertion] =
  ## Per receiver: the threshold and ringback margins always (the
  ## receiver's own IBIS Vinh/Vinl are the limit, not an invented one);
  ## flight time, overshoot, undershoot and settling only when stated.
  for p in siReceiverParts:
    if not inst.hasPart(p): continue
    let rx = inst.subject(p)
    let tag = p & "."
    result.add Assertion(
      id: assertionId(inst, tag & "threshold_margin"),
      subjects: @[rx], quantity: "si_threshold_margin_v",
      expect: atLeast(0.0), unit: "V", severity: sevError,
      rationale: "after the edge the receiver must sit beyond its own " &
                 "Vinh/Vinl (IBIS), or it never sees the new level",
      origin: inst.name)
    result.add Assertion(
      id: assertionId(inst, tag & "ringback_margin"),
      subjects: @[rx], quantity: "si_ringback_margin_v",
      expect: atLeast(0.0), unit: "V", severity: sevError,
      rationale: "ringing back into the receiver's threshold band can " &
                 "double-clock an edge-sensitive input",
      origin: inst.name)
    if hasParam(inst, "max_flight_time"):
      result.add Assertion(
        id: assertionId(inst, tag & "flight_time"),
        subjects: @[rx], quantity: "si_flight_time",
        expect: atMost(paramFloat(inst, "max_flight_time", 0.0)), unit: "s",
        severity: sevError,
        rationale: "the interconnect's share of the timing budget: from the " &
                   "driver's Vmeas into its IBIS test load to the receiver " &
                   "settling past its threshold",
        origin: inst.name)
    if hasParam(inst, "max_overshoot"):
      result.add Assertion(
        id: assertionId(inst, tag & "overshoot"),
        subjects: @[rx], quantity: "si_overshoot_v",
        expect: atMost(paramFloat(inst, "max_overshoot", 0.0)), unit: "V",
        severity: sevError,
        rationale: "a receiver driven past its rail conducts into its clamps",
        origin: inst.name)
    if hasParam(inst, "max_undershoot"):
      result.add Assertion(
        id: assertionId(inst, tag & "undershoot"),
        subjects: @[rx], quantity: "si_undershoot_v",
        expect: atMost(paramFloat(inst, "max_undershoot", 0.0)), unit: "V",
        severity: sevError,
        rationale: "a receiver driven below ground conducts into its clamps",
        origin: inst.name)
    if hasParam(inst, "ui") or hasParam(inst, "max_settle_time"):
      let lim = if hasParam(inst, "max_settle_time"): paramFloat(inst, "max_settle_time", 0.0)
                else: paramFloat(inst, "ui", 0.0)
      result.add Assertion(
        id: assertionId(inst, tag & "settle_time"),
        subjects: @[rx], quantity: "si_settle_time",
        expect: atMost(lim), unit: "s", severity: sevError,
        rationale: "an edge must settle within the unit interval or the " &
                   "next bit starts from the previous one's ringing",
        origin: inst.name)
  for p in siReceiverParts:
    if not inst.hasPart(p): continue
    let rx = inst.subject(p)
    if hasParam(inst, "min_eye_height"):
      result.add Assertion(
        id: assertionId(inst, p & ".eye_height"),
        subjects: @[rx], quantity: "si_eye_height_v",
        expect: atLeast(paramFloat(inst, "min_eye_height", 0.0)), unit: "V",
        severity: sevError,
        rationale: "a PRBS7 stream at the UI must leave the receiver this much " &
                   "vertical opening between its worst one and worst zero",
        origin: inst.name)
    if hasParam(inst, "min_eye_width"):
      result.add Assertion(
        id: assertionId(inst, p & ".eye_width"),
        subjects: @[rx], quantity: "si_eye_width",
        expect: atLeast(paramFloat(inst, "min_eye_width", 0.0)), unit: "s",
        severity: sevError,
        rationale: "every bit of a PRBS7 stream must sit beyond the receiver's " &
                   "own Vinh/Vinl for this long: the sampling window",
        origin: inst.name)
  if inst.hasPart("victim_rx"):
    let v = inst.subject("victim_rx")
    result.add Assertion(
      id: assertionId(inst, "victim.noise_margin"),
      subjects: @[v], quantity: "si_noise_margin_v",
      expect: atLeast(0.0), unit: "V", severity: sevError,
      rationale: "crosstalk from this net must not push the quiet victim's " &
                 "receiver past its own Vinl/Vinh (IBIS): a false edge",
      origin: inst.name)
    if hasParam(inst, "max_crosstalk"):
      result.add Assertion(
        id: assertionId(inst, "victim.crosstalk"),
        subjects: @[v], quantity: "si_crosstalk_v",
        expect: atMost(paramFloat(inst, "max_crosstalk", 0.0)), unit: "V",
        severity: sevError,
        rationale: "the noise budget this net may put on its neighbour",
        origin: inst.name)

proc registerInterconnectRoles*() =
  registerRole(RoleDef(
    name: "diff_pair",
    doc: "Two nets carrying one differential signal.",
    parts: @[
      RolePart(name: "p", kind: skNet, doc: "the positive leg"),
      RolePart(name: "n", kind: skNet, doc: "the negative leg"),
      RolePart(name: "driver", kind: skPin, optional: true,
               doc: "the P leg's driving pin (IBIS; its [Diff Pin] row names the N " &
                    "pin): lets `verax constraints` derive the pair's routing rules"),
      RolePart(name: "rx", kind: skPin, optional: true,
               doc: "the P leg's receiving pin (IBIS, with a [Diff Pin] row unless " &
                    "rx_n is named)"),
      RolePart(name: "driver_n", kind: skPin, optional: true,
               doc: "the N leg's driving pin, for an IBIS file with no [Diff Pin] " &
                    "row (a pseudo-differential pair, e.g. USB full-speed): driven " &
                    "as the inverse of driver"),
      RolePart(name: "rx_n", kind: skPin, optional: true,
               doc: "the N leg's receiving pin, for an IBIS file with no [Diff Pin] row"),
    ],
    params: @[
      AnnDef(key: "z_diff", kind: akFloat, unit: "ohm", scopes: {asNet},
             doc: "target differential characteristic impedance; unclaimed " &
                  "unless stated"),
      AnnDef(key: "z_diff_tol", kind: akFloat, scopes: {asNet},
             doc: "accepted fraction around z_diff; default 10%"),
      AnnDef(key: "skew_intra_max", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "most P-to-N propagation-delay difference this pair may " &
                  "carry; unclaimed unless stated"),
      AnnDef(key: "ui", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "unit interval: with driver/rx, `verax constraints` requires " &
                  "the differential edge to settle within it"),
    ],
    apply: diffPairApply,
    expand: diffPairExpand))
  registerRole(RoleDef(
    name: "si_net",
    doc: "One single-ended net checked as a signal-integrity problem: an " &
         "IBIS driver, the routed board interconnect, IBIS receivers " &
         "(each part's `ibis_file`). Needs a board (`--board=`); without " &
         "one, `verax constraints` derives the routing rules instead.",
    parts: @[
      RolePart(name: "net", kind: skNet, doc: "the signal net"),
      RolePart(name: "driver", kind: skPin, doc: "the driving pin"),
      RolePart(name: "rx", kind: skPin, doc: "a receiving pin"),
      RolePart(name: "rx2", kind: skPin, optional: true, doc: "a second receiver"),
      RolePart(name: "rx3", kind: skPin, optional: true, doc: "a third receiver"),
      RolePart(name: "rx4", kind: skPin, optional: true, doc: "a fourth receiver"),
      RolePart(name: "victim", kind: skNet, optional: true,
               doc: "a quiet neighbour this net couples into (crosstalk); with " &
                    "victim_driver and victim_rx"),
      RolePart(name: "victim_driver", kind: skPin, optional: true,
               doc: "the victim's driver, held low"),
      RolePart(name: "victim_rx", kind: skPin, optional: true,
               doc: "the victim's receiver"),
    ],
    params: @[
      AnnDef(key: "max_flight_time", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "most driver-to-receiver flight time (IBIS definition); " &
                  "unclaimed unless stated"),
      AnnDef(key: "max_overshoot", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "most a receiver may go above the driver's high rail; " &
                  "unclaimed unless stated"),
      AnnDef(key: "max_undershoot", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "most a receiver may go below the driver's low rail; " &
                  "unclaimed unless stated"),
      AnnDef(key: "ui", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "unit interval: each edge must settle within it"),
      AnnDef(key: "max_settle_time", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "settling limit, overriding `ui` for the settle claim"),
      AnnDef(key: "max_crosstalk", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "most excursion this net may cause on the victim; unclaimed " &
                  "unless stated (the victim's noise margin is always claimed)"),
      AnnDef(key: "min_eye_height", kind: akFloat, unit: "V", scopes: {asNet},
             doc: "least eye height of a 127-bit PRBS7 at `ui` (needs `ui`); " &
                  "unclaimed unless stated"),
      AnnDef(key: "min_eye_width", kind: akFloat, unit: "s", scopes: {asNet},
             doc: "least eye width (every bit past its threshold) of a 127-bit " &
                  "PRBS7 at `ui` (needs `ui`); unclaimed unless stated"),
      AnnDef(key: "coupled_length", kind: akFloat, unit: "m", scopes: {asNet},
             doc: "the parallel run beside the victim that `verax constraints` " &
                  "derives a minimum spacing for"),
    ],
    apply: siNetApply,
    expand: siNetExpand))
