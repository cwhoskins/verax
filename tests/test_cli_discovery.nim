## The discovery commands' registries. Pinned: everything registered is
## reachable, and nothing a third party registers makes a listing raise.

import std/[options, strutils, tables, unittest]

import verax/verify

suite "role discovery":
  test "every registered role previews without raising":
    check registeredRoles().len > 0
    for name in registeredRoles():
      let def = roleDef(name)
      check def.expand != nil
      discard previewRole(def)          # must not raise
      check def.parts.len > 0

  test "every built-in role can claim something once its parameters are stated":
    # Not "claims something with nothing stated": `gain_stage` claims nothing
    # until given a spec. What must hold is that no role is a dead end.
    for name in registeredRoles():
      let def = roleDef(name)
      var params: seq[(string, string)]
      for p in def.params: params.add (p.key, "1")
      check previewRole(def, params).len > 0

  test "an optional parameter's claims are discoverable by diffing":
    let extra = previewRoleDelta(roleDef("power_rail"), "targetZ")
    check extra.len == 1
    check extra[0].quantity == "z_max_in_band"

  test "a parameter that adds nothing reports nothing":
    check previewRoleDelta(roleDef("power_rail"), "band").len == 0

  test "an expander that raises is contained, not propagated":
    # A third-party role may reject placeholder bindings; the listing must
    # survive it.
    registerRole(RoleDef(
      name: "test_hostile",
      doc: "raises when expanded",
      parts: @[RolePart(name: "n", kind: skNet, doc: "a net")],
      expand: proc (inst: RoleInstance): seq[Assertion] {.nimcall.} =
        raise newException(ValueError, "no")))
    check previewRole(roleDef("test_hostile")).len == 0

suite "quantity and annotation discovery":
  test "every evaluable quantity resolves to an evaluator":
    check evaluableQuantities().len > 0
    for q in evaluableQuantities():
      check evaluatorFor(q).isSome
      check isEvaluable(q)

  test "the simulated evaluators are registered by importing verify":
    # Otherwise `dc_voltage` would report as produced by nothing.
    for q in ["dc_voltage", "z_max_in_band", "phase_margin_deg", "final_v"]:
      check isEvaluable(q)

  test "every registered annotation key has a definition":
    check registeredKeys().len > 0
    for key in registeredKeys():
      check annDef(key).key == key
      check annDef(key).doc.len > 0

  test "near-match suggestions find a real quantity":
    check "z_min" in didYouMean("z_mim")
    check "dc_voltage" in didYouMean("dc_voltag")

  test "a name nothing resembles suggests nothing":
    check didYouMean("xyzzy_quantity_that_is_nothing").len == 0

# Template health is `nimble verify`'s job, not this file's.

# --- reachability, which is what the quantities listing is for ----------

test "every quantity is labelled with how it can actually be claimed":
  let text = describeQuantities()
  # A bare `require` reaches these.
  for q in ["z_min", "cap_count", "f_antiresonance", "dc_voltage"]:
    check (q & " ") in text
  check "`require`" in text
  # These need a role: the evaluator reads bindings back.
  check "needs a role binding" in text

test "the claiming-role map is computed from the expanders, not written down":
  let byRole = claimingRoles()
  check "power_rail" in byRole["dc_voltage"]
  check "regulator" in byRole["overshoot_pct"]
  check "opamp_stage" in byRole["phase_margin_deg"]
  check "i2c" in byRole["pullup_count"]

test "a parameter that redirects a claim is still discovered":
  # gain_stage's `atF` switches gain_max_db to gain_at_f, so both branches
  # must be reported.
  let byRole = claimingRoles()
  check "gain_stage" in byRole["gain_max_db"]
  check "gain_stage" in byRole["gain_at_f"]

test "the startup and opamp evaluators declare what they bind":
  # Declared, so reachability is known without running anything.
  check evaluatorFor("overshoot_pct").get.binds == @["regulator", "output"]
  check evaluatorFor("phase_margin_deg").get.binds == @["opamp", "input"]
  check evaluatorFor("controller_count").get.binds == @["controller"]
  # A PDN sweep needs only its net.
  check evaluatorFor("z_min").get.binds.len == 0
  check evaluatorFor("dc_voltage").get.binds.len == 0

test "the built-in roles now claim the start-up quantities":
  # Each is claimable through a built-in path.
  let byRole = claimingRoles()
  for q in ["inrush_peak", "rise_time_10_90", "settle_time"]:
    check "regulator" in byRole[q]
  check "opamp_stage" in byRole["gain_margin_db"]

test "the large-signal quantities are reachable through the role":
  let byRole = claimingRoles()
  check "large_signal" in byRole["thd_pct"]
  check "large_signal" in byRole["output_swing"]
  # clip_high/clip_low are diagnostics; no role claims them.
  check byRole.getOrDefault("clip_high", @[]).len == 0
  check evaluatorFor("clip_high").get.binds.len > 0
