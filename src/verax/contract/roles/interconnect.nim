## Built-in roles for point-to-point interconnect.
##
## `diff_pair` is the only one so far. A differential pair needs no new
## declaration mechanism -- it is an ordinary two-signal `InterfaceDef` (see
## `netlist/interfaces/std.diffPairInterface`/`usb2Interface`) whose signals
## are named `p`/`n`, which is what lets `contract/design.addRoleFromInterface`
## bind this role's parts by the existing same-name matching. This module is
## only the claims: what it means to *be* a pair, once two nets are bound.

import ../../netlist/types
import ../../netlist/annotations
import ./core

proc diffPairApply*(inst: RoleInstance, nl: Netlist) =
  ## Writes nothing -- there is no annotation a non-checking consumer would
  ## read off a pair. It exists to validate at attach time, the same moment
  ## `addRole` already catches an unknown part or a duplicate instance name,
  ## rather than deferring to `expand` and surfacing only when the design is
  ## evaluated.
  let p = inst.subject("p")
  let n = inst.subject("n")
  if p.kind == skNet and n.kind == skNet and p.name == n.name:
    raise newException(NetlistError,
      "role 'diff_pair' instance '" & inst.name & "': p and n are the same net (" &
      p.name & ")")

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

proc registerInterconnectRoles*() =
  registerRole(RoleDef(
    name: "diff_pair",
    doc: "Two nets carrying one differential signal.",
    parts: @[
      RolePart(name: "p", kind: skNet, doc: "the positive leg"),
      RolePart(name: "n", kind: skNet, doc: "the negative leg"),
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
    ],
    apply: diffPairApply,
    expand: diffPairExpand))
