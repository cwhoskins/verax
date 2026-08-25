## What the discovery commands read: the role, evaluator and annotation
## registries.
##
## These are the only way an author working outside this repository can find
## out what may be claimed, so the properties worth pinning are that every
## registered thing is *reachable* and that nothing a third party registers
## can make a listing raise.

import std/[options, os, osproc, strutils, tables, unittest]

import nimcir/verify

suite "role discovery":
  test "every registered role previews without raising":
    check registeredRoles().len > 0
    for name in registeredRoles():
      let def = roleDef(name)
      check def.expand != nil
      discard previewRole(def)          # must not raise
      check def.parts.len > 0

  test "every built-in role can claim something once its parameters are stated":
    # Deliberately weaker than "claims something with nothing stated".
    # `gain_stage` claims nothing until a specification is given, and that is
    # the same rule `power_rail`'s `targetZ` follows: a gain figure comes
    # from what the stage is *for*, and a default would manufacture a
    # requirement the designer never made. `power_rail` gets away with an
    # always-claim only because a rail's nominal voltage is itself a
    # parameter it insists on.
    #
    # What must hold is that no role is a dead end -- one that can never
    # claim anything is a name in `nimcir roles` that does nothing.
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
    # A role registered by someone else is not obliged to tolerate
    # placeholder bindings; `nimcir roles` must survive one that does not.
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
    # The whole reason `verify` exists as one entry point: without this,
    # `dc_voltage` reports as a quantity nothing produces, which is false.
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

suite "templates":
  # The highest-value test here: it proves the files we hand an author
  # actually build and pass. Offline, so it needs no simulator.
  let root = currentSourcePath().parentDir.parentDir
  let nim = findExe("nim")

  test "every template compiles and checks clean":
    if nim.len == 0:
      skip()
    else:
      for path in walkFiles(root / "templates" / "*.nim"):
        let cache = getTempDir() / "nimcir-tmpl" / path.splitFile.name
        let bin = cache / "t".addFileExt(ExeExt)
        createDir(cache)
        let (outp, rc) = execCmdEx(quoteShellCommand([nim, "c", "--hints:off",
          "--path:" & root / "src", "--nimcache:" & cache / "nc",
          "--out:" & bin, path]))
        checkpoint path & "\n" & outp
        check rc == 0
        let (report, code) = execCmdEx(quoteShellCommand([bin, "--offline"]))
        checkpoint path & "\n" & report
        check code == exitClean

# --- reachability, which is what the quantities listing is for ----------

test "every quantity is labelled with how it can actually be claimed":
  let text = describeQuantities()
  # A bare `require` reaches these: their evaluators need only the subjects.
  for q in ["z_min", "cap_count", "f_antiresonance", "dc_voltage"]:
    check (q & " ") in text
  check "`require`" in text
  # And these need a role, because the evaluator reads bindings back off it.
  check "needs a role binding" in text

test "the claiming-role map is computed from the expanders, not written down":
  let byRole = claimingRoles()
  check "power_rail" in byRole["dc_voltage"]
  check "regulator" in byRole["overshoot_pct"]
  check "opamp_stage" in byRole["phase_margin_deg"]
  check "i2c" in byRole["pullup_count"]

test "a parameter that redirects a claim is still discovered":
  # gain_stage's `atF` moves the gain claim from gain_max_db onto gain_at_f,
  # so one expansion with every parameter stated hides the branch the other
  # shows. Both have to be reported or the listing lies about one of them.
  let byRole = claimingRoles()
  check "gain_stage" in byRole["gain_max_db"]
  check "gain_stage" in byRole["gain_at_f"]

test "the startup and opamp evaluators declare what they bind":
  # Declared rather than inferred: something has to answer "can a bare
  # `require` reach this?" without running anything.
  check evaluatorFor("overshoot_pct").get.binds == @["regulator", "output"]
  check evaluatorFor("phase_margin_deg").get.binds == @["opamp", "input"]
  check evaluatorFor("controller_count").get.binds == @["controller"]
  # A PDN sweep needs only the net it is about.
  check evaluatorFor("z_min").get.binds.len == 0
  check evaluatorFor("dc_voltage").get.binds.len == 0

test "the built-in roles now claim the start-up quantities":
  # They were advertised and unclaimable by any built-in path.
  let byRole = claimingRoles()
  for q in ["inrush_peak", "rise_time_10_90", "settle_time"]:
    check "regulator" in byRole[q]
  check "opamp_stage" in byRole["gain_margin_db"]

test "the large-signal quantities are reachable through the role":
  let byRole = claimingRoles()
  check "large_signal" in byRole["thd_pct"]
  check "large_signal" in byRole["output_swing"]
  # clip_high/clip_low are diagnostics rather than specifications, so no
  # role claims them -- and the listing says exactly that.
  check byRole.getOrDefault("clip_high", @[]).len == 0
  check evaluatorFor("clip_high").get.binds.len > 0
